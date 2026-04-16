local modName = g_currentModName


PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, function(self)

    local _, eventId = g_inputBinding:registerActionEvent(InputAction.HerdingLite, AnimalManager, AnimalManager.onToggleHerding, false, true, false, true, nil, false)

    g_animalManager.herdingEventId = eventId
    g_animalManager.herdingStartText = g_i18n:getText("ahl_startHerding")
    g_animalManager.herdingStopText = g_i18n:getText("ahl_stopHerding")
    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_HIGH)
	g_inputBinding:setActionEventText(eventId, g_animalManager.herdingEnabled and g_animalManager.herdingStopText or g_animalManager.herdingStartText)
    g_inputBinding:setActionEventActive(eventId, true)

    if g_animalManager.unloadTrailerEventId == nil then
        local _, unloadEventId = g_inputBinding:registerActionEvent(InputAction.HerdingLiteUnload, AnimalManager, AnimalManager.onUnloadTrailer, false, true, false, true, nil, false)
        g_animalManager.unloadTrailerEventId = unloadEventId
        g_inputBinding:setActionEventTextPriority(unloadEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(unloadEventId, g_i18n:getText("ahl_unloadTrailer"))
    end
    g_inputBinding:setActionEventActive(g_animalManager.unloadTrailerEventId, false)

end)


PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, function(self)

    self.animalPickup = nil

    -- Only process on the owning player, in normal on-foot mode, not already carrying, server-only (SP or MP host without active clients)
    if not self.player.isOwner
        or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME
        or self.player:getIsCarryingAnimal()
        or not g_currentMission:getIsServer()
        or g_server.netIsRunning
    then return end

    -- Don't intercept interact when an accessible vehicle is in range
    local vehicleInRange = g_currentMission.interactiveVehicleInRange
    local accessHandler = g_currentMission.accessHandler
    if vehicleInRange ~= nil and accessHandler:canPlayerAccess(vehicleInRange, self.player) then return end

    local farmId = self.player.farmId
    local px, _, pz = getWorldTranslation(self.player.rootNode)

    -- ── Herded animals: proximity walk (custom proxy nodes are not auto-registered with the GIANTS targeter) ──
    local farm = g_animalManager.farms[farmId]
    if farm ~= nil then

        local PICKUP_RANGE = 3.5
        local bestAnimal, bestDist = nil, PICKUP_RANGE

        for _, animal in ipairs(farm.animals) do

            if animal.cluster.getCanBePickedUp == nil or not animal.cluster:getCanBePickedUp() then continue end

            local dx = animal.position.x - px
            local dz = animal.position.z - pz
            local dist = math.sqrt(dx * dx + dz * dz)

            if dist < bestDist then
                bestAnimal = animal
                bestDist = dist
            end

        end

        if bestAnimal ~= nil then

            self.animalPickup = {
                ["herding"] = true,
                ["node"] = bestAnimal.collisionController.proxy
            }

            g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("ahl_pickupAnimal"))
            g_inputBinding:setActionEventActive(self.enterActionId, true)
            return

        end

    end

    -- ── Engine / husbandry animals: GIANTS auto-registers their collision nodes so the targeter works ──
    if self.player.targeter == nil then return end

    local closestNode = self.player.targeter:getClosestTargetedNodeFromType(PlayerInputComponent)
    self.player.hudUpdater:setCurrentRaycastTarget(closestNode)

    if closestNode == nil then return end

    local husbandryId, animalId = getAnimalFromCollisionNode(closestNode)

    if husbandryId == nil or husbandryId == 0 then return end

    local clusterHusbandry = g_currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)

    if clusterHusbandry == nil then return end

    local placeable = clusterHusbandry:getPlaceable()
    local animal = clusterHusbandry:getClusterByAnimalId(animalId, husbandryId)

    if animal ~= nil and accessHandler:canFarmAccess(self.player.farmId, placeable) and animal.getCanBePickedUp ~= nil and animal:getCanBePickedUp() then

        self.animalPickup = {
            ["herding"] = false,
            ["husbandryId"] = husbandryId,
            ["animalId"] = animalId
        }

        g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("ahl_pickupAnimal"))
        g_inputBinding:setActionEventActive(self.enterActionId, true)

    end

end)


-- ── Trailer unload detection ─────────────────────────────────────────────────
-- Find any livestock trailer (with animals) within TRAILER_RANGE of the player,
-- then check whether that trailer is parked inside one of the player's husbandries
-- (via the husbandry's delivery area polygon). This way the player only needs to
-- stand next to the trailer — they don't need to be in the delivery zone themselves.
--
-- showUnload is always explicitly applied at the end so the event state is
-- consistent whether the player is on foot, in a vehicle, or mid-transition.

PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, function(self)

    g_animalManager.localTrailerUnload = nil
    local showUnload = false

    -- Only detect when owner, on foot, server only (no active clients).
    -- Intentionally does NOT gate on self.animalPickup: the pickup prompt (E key) and
    -- unload prompt (LSHIFT+U) are on different buttons and can both be visible at once.
    if self.player.isOwner
        and g_inputBinding:getContextName() == PlayerInputComponent.INPUT_CONTEXT_NAME
        and not self.player:getIsCarryingAnimal()
        and g_currentMission:getIsServer()
        and not g_server.netIsRunning
    then

        local farmId = self.player.farmId
        local px, _, pz = getWorldTranslation(self.player.rootNode)

        -- Find the nearest livestock trailer with animals within TRAILER_RANGE of the player
        local TRAILER_RANGE = 15
        local nearestTrailer, nearestDist = nil, TRAILER_RANGE

        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
            if vehicle.spec_livestockTrailer == nil then continue end
            if vehicle:getOwnerFarmId() ~= farmId then continue end
            if #vehicle:getClusters() == 0 then continue end

            local tx, _, tz = getWorldTranslation(vehicle.rootNode)
            local dist = MathUtil.vector2Length(px - tx, pz - tz)
            if dist < nearestDist then
                nearestTrailer = vehicle
                nearestDist = dist
            end
        end

        if nearestTrailer ~= nil then

            -- Check which husbandry (if any) the trailer is parked inside
            local tx, _, tz = getWorldTranslation(nearestTrailer.rootNode)
            local trailerHusbandry = nil

            for _, husbandry in pairs(g_currentMission.husbandrySystem.placeables) do
                if husbandry:getOwnerFarmId() ~= farmId then continue end
                if husbandry:getIsInAnimalDeliveryArea(tx, tz) then
                    trailerHusbandry = husbandry
                    break
                end
            end

            if trailerHusbandry ~= nil then

                -- Check whether the trailer's animal type matches the husbandry
                local husbandryTypeIndex = trailerHusbandry:getAnimalTypeIndex()
                local trailerType = nearestTrailer:getCurrentAnimalType()
                local compatible = trailerType ~= nil and trailerType.typeIndex == husbandryTypeIndex

                if compatible then
                    g_animalManager.localTrailerUnload = { trailer = nearestTrailer, husbandry = trailerHusbandry }
                    showUnload = true
                else
                    -- Rate-limited mismatch warning: show once every 5 s so it doesn't spam
                    local now = g_time or 0
                    if self.trailerMismatchWarningTime == nil or now - self.trailerMismatchWarningTime > 5000 then
                        self.trailerMismatchWarningTime = now
                        g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_trailerTypeMismatch", modName), 3000)
                    end
                end

            end

        end

    end

    -- Always explicitly set the event state so vehicle entry/exit can never leave it stuck
    if g_animalManager.unloadTrailerEventId ~= nil then
        g_inputBinding:setActionEventActive(g_animalManager.unloadTrailerEventId, showUnload)
    end

end)


PlayerInputComponent.onInputEnter = Utils.appendedFunction(PlayerInputComponent.onInputEnter, function(self)

    if g_time <= g_currentMission.lastInteractionTime + 200 or g_currentMission.interactiveVehicleInRange ~= nil or self.rideablePlaceable ~= nil or self.animalPickup == nil then return end

    local handToolType = g_handToolTypeManager:getTypeByName(modName .. ".animal")
    local handTool = _G[handToolType.className].new(g_currentMission:getIsServer(), g_currentMission:getIsClient())

    handTool:setType(handToolType)
    handTool:setLoadCallback(self.onFinishedLoadAnimalPickup, self, { ["animal"] = self.animalPickup })
    handTool:loadNonStoreItemAHL({ ["ownerFarmId"] = g_localPlayer.farmId, ["isRegistered"] = false, ["holder"] = g_localPlayer }, AHLHandTools.xmlPaths.animal)

end)


function PlayerInputComponent:onFinishedLoadAnimalPickup(handTool, loadingState, args)

    if loadingState == HandToolLoadingState.OK then

        local success = false

        if args.animal.herding then
            success = handTool:setHerdingAnimal(args.animal.node, self.player.farmId)
        else
            success = handTool:setEngineAnimal(args.animal.husbandryId, args.animal.animalId)
        end

        if success then
            self.player:setCurrentHandTool(handTool)
        elseif g_currentMission:getIsServer() then
            g_currentMission.handToolSystem:markHandToolForDeletion(handTool)
        end

    end

end
