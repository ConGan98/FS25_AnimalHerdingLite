local modName = g_currentModName

local MAX_PICKUP_AGE = 3


-- Returns a rejection reason key if the animal cannot be picked up, or nil if it can.
local function getPickupRejectionReason(cluster)
    if cluster == nil then return nil end
    if cluster.getCanBePickedUp ~= nil and cluster:getCanBePickedUp() then return nil end

    local animalTypeIndex
    if cluster.getAnimalTypeIndex ~= nil then
        animalTypeIndex = cluster:getAnimalTypeIndex()
    elseif cluster.subTypeIndex ~= nil then
        animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(cluster.subTypeIndex)
    end

    if animalTypeIndex == AnimalType.HORSE then return nil end

    if cluster.weight ~= nil and cluster.weight > 100 then return "ahl_tooHeavyToPickup" end
    if cluster.age ~= nil and cluster.age >= MAX_PICKUP_AGE then return "ahl_tooOldToPickup" end

    return nil
end


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

    -- Only process on the owning player, in normal on-foot mode, server-only (SP or MP host without active clients)
    if not self.player.isOwner
        or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME
        or not g_currentMission:getIsServer()
        or g_server.netIsRunning
    then return end

    -- When carrying an animal, show the return prompt instead of pickup detection
    if self.player:getIsCarryingAnimal() then
        self.animalPickup = { ["return"] = true }
        g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("ahl_returnAnimal"))
        g_inputBinding:setActionEventActive(self.enterActionId, true)
        return
    end

    -- Don't allow pickup while herding is active
    local farmId = self.player.farmId
    if g_animalManager.farms[farmId] ~= nil then return end

    -- Don't intercept interact when an accessible vehicle is in range
    local vehicleInRange = g_currentMission.interactiveVehicleInRange
    local accessHandler = g_currentMission.accessHandler
    if vehicleInRange ~= nil and accessHandler:canPlayerAccess(vehicleInRange, self.player) then return end
    local px, _, pz = getWorldTranslation(self.player.rootNode)

    -- ── Herded animals: proximity walk (custom proxy nodes are not auto-registered with the GIANTS targeter) ──
    local farm = g_animalManager.farms[farmId]
    if farm ~= nil then

        local PICKUP_RANGE = 3.5
        local bestAnimal, bestDist = nil, PICKUP_RANGE
        local closestRejected, closestRejectedDist, rejectionReason = nil, PICKUP_RANGE, nil

        for _, animal in ipairs(farm.animals) do

            local dx = animal.position.x - px
            local dz = animal.position.z - pz
            local dist = math.sqrt(dx * dx + dz * dz)

            if dist < PICKUP_RANGE then
                if animal.cluster.getCanBePickedUp ~= nil and animal.cluster:getCanBePickedUp() then
                    if dist < bestDist then
                        bestAnimal = animal
                        bestDist = dist
                    end
                elseif dist < closestRejectedDist then
                    closestRejected = animal
                    closestRejectedDist = dist
                    rejectionReason = getPickupRejectionReason(animal.cluster)
                end
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

        elseif closestRejected ~= nil and rejectionReason ~= nil then
            local now = g_time or 0
            if self.pickupRejectionWarningTime == nil or now - self.pickupRejectionWarningTime > 5000 then
                self.pickupRejectionWarningTime = now
                g_currentMission:showBlinkingWarning(g_i18n:getText(rejectionReason, modName), 3000)
            end
            return
        end

    end

    -- ── Engine / husbandry animals: GIANTS auto-registers their collision nodes so the targeter works ──
    local foundEngineAnimal = false

    if self.player.targeter ~= nil then

        local closestNode = self.player.targeter:getClosestTargetedNodeFromType(PlayerInputComponent)
        self.player.hudUpdater:setCurrentRaycastTarget(closestNode)

        if closestNode ~= nil then

            local husbandryId, animalId = getAnimalFromCollisionNode(closestNode)

            if husbandryId ~= nil and husbandryId ~= 0 then

                local clusterHusbandry = g_currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)

                if clusterHusbandry ~= nil then

                    local placeable = clusterHusbandry:getPlaceable()
                    local animal = clusterHusbandry:getClusterByAnimalId(animalId, husbandryId)

                    if animal ~= nil and accessHandler:canFarmAccess(self.player.farmId, placeable) then

                        foundEngineAnimal = true

                        if animal.getCanBePickedUp ~= nil and animal:getCanBePickedUp() then

                            self.animalPickup = {
                                ["herding"] = false,
                                ["husbandryId"] = husbandryId,
                                ["animalId"] = animalId
                            }

                            g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("ahl_pickupAnimal"))
                            g_inputBinding:setActionEventActive(self.enterActionId, true)
                            return

                        else
                            local reason = getPickupRejectionReason(animal)
                            if reason ~= nil then
                                local now = g_time or 0
                                if self.pickupRejectionWarningTime == nil or now - self.pickupRejectionWarningTime > 5000 then
                                    self.pickupRejectionWarningTime = now
                                    g_currentMission:showBlinkingWarning(g_i18n:getText(reason, modName), 3000)
                                end
                            end
                        end

                    end

                end

            end

        end

    end

    -- ── Pen chickens: no collision proxy so the targeter can't find them — use position proximity instead ──
    if not foundEngineAnimal then

        local CHICKEN_PICKUP_RANGE = 3.0
        local bestHusbandryId, bestAnimalId, bestDist = nil, nil, CHICKEN_PICKUP_RANGE

        for _, husbandry in pairs(g_currentMission.husbandrySystem.placeables) do
            if husbandry:getOwnerFarmId() ~= farmId then continue end
            if husbandry:getAnimalTypeIndex() ~= AnimalType.CHICKEN then continue end

            local clusterHusbandry = husbandry.spec_husbandryAnimals ~= nil and husbandry.spec_husbandryAnimals.clusterHusbandry or nil
            if clusterHusbandry == nil then continue end

            if g_animalManager:getHasHusbandryConflict() then
                -- RL: animalIdToCluster is [index] → { [animalId] → cluster }
                for i, animalIds in pairs(clusterHusbandry.animalIdToCluster) do
                    local hId = clusterHusbandry.husbandryIds[i]
                    if hId == nil then continue end
                    for animalId, cluster in pairs(animalIds) do
                        local ax, _, az = getAnimalPosition(hId, animalId)
                        local dist = MathUtil.vector2Length(px - ax, pz - az)
                        if dist < bestDist and cluster.getCanBePickedUp ~= nil and cluster:getCanBePickedUp() then
                            bestHusbandryId = hId
                            bestAnimalId = animalId
                            bestDist = dist
                        end
                    end
                end
            else
                -- Vanilla: animalIdToCluster is [animalId] → cluster
                local hId = clusterHusbandry.husbandryId
                if hId ~= nil then
                    for animalId, cluster in pairs(clusterHusbandry.animalIdToCluster) do
                        local ax, _, az = getAnimalPosition(hId, animalId)
                        local dist = MathUtil.vector2Length(px - ax, pz - az)
                        if dist < bestDist and cluster.getCanBePickedUp ~= nil and cluster:getCanBePickedUp() then
                            bestHusbandryId = hId
                            bestAnimalId = animalId
                            bestDist = dist
                        end
                    end
                end
            end
        end

        if bestHusbandryId ~= nil then
            self.animalPickup = {
                ["herding"] = false,
                ["husbandryId"] = bestHusbandryId,
                ["animalId"] = bestAnimalId
            }
            g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("ahl_pickupAnimal"))
            g_inputBinding:setActionEventActive(self.enterActionId, true)
        end

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

    -- Return carried animal to its original husbandry
    if self.animalPickup["return"] then
        local currentHandTool = self.player:getHeldHandTool()
        if currentHandTool ~= nil then
            g_animalManager:returnCarriedAnimalToHusbandry(currentHandTool)
        end
        return
    end

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
