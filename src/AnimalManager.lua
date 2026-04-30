AnimalManager = {}


AnimalManager.CONFLICTS = {}
AnimalManager.ANIMAL_TYPE_INDEX_TO_AGE_OFFSET = {}


local AnimalManager_mt = Class(AnimalManager)
local modDirectory = g_currentModDirectory
local modName = g_currentModName


function AnimalManager.new()

	local self = setmetatable({}, AnimalManager_mt)

	self.debugEnabled = false
	self.collisionDebugEnabled = false
	self.animDebugEnabled = false
	self.animDebugTimer = 0
	self.lastGuiName = nil
	self.cache = {}
    self.farms = {}
    self.husbandries = {}
    self.ticksSinceLastHusbandryCheck = 0
    self.ticksSinceLastPlayerCheck = 0
    self.ticksSinceLastAnimalHusbandryCheck = 0
    self.ticksSinceLastInputForce = 0
    self.ticksSinceLastSync = 0
    self.collisionControllers = {}
    self.proxies = {}
    self.isInitialised = false
    self.herdingEnabled = false
    self.connections = {}
    self.syncQueue = {}
    self.feedBuckets = {}
    self.collisionNodes = {}
    self.carriedAnimals = {}
    self.handToolsPostLoad = {}

	self:overwriteEngineFunctions()

	--g_isDevelopmentVersion = true
	--g_addCheatCommands = true

	addConsoleCommand("toggleAnimalDebug", "Toggle animal debug mode", "consoleCommandToggleDebug", AnimalManager)
	addConsoleCommand("toggleAnimalCollisionDebug", "Toggle animal collision type debug overlay", "consoleCommandToggleCollisionDebug", AnimalManager)
	addConsoleCommand("toggleAnimalAnimDebug", "Toggle logging of each herded animal's current animation clip and speed", "consoleCommandToggleAnimDebug", AnimalManager)
	addConsoleCommand("toggleAnimalMovementDebug", "Toggle 3D overlay showing per-animal state/speed/flip-rate for diagnosing animation flicker + movement mismatch", "consoleCommandToggleMovementDebug", AnimalManager)
	addConsoleCommand("dumpAnimalAnimCache", "Dump all animation IDs/clips available per herded animal", "consoleCommandDumpAnimCache", AnimalManager)
	addConsoleCommand("dumpHerdingInputState", "Dump herding input event state and husbandry range result", "consoleCommandDumpInputState", AnimalManager)
	addConsoleCommand("refreshHerdingPrompt", "Force-refresh the herding action-event state now", "consoleCommandRefreshPrompt", AnimalManager)

    _G[modName].ClassUtil = ClassUtil

	return self

end


function AnimalManager:update(dT)

    if self.animDebugEnabled then
        self.animDebugTimer = self.animDebugTimer + dT
        if self.animDebugTimer >= 1000 then
            self.animDebugTimer = 0
            self:logAnimDebug()
        end
    end

    self:checkAnimalDialogStop()
    self:checkInputContextChange()

    if g_localPlayer ~= nil then

        local controlledVehicle = g_currentMission.controlledVehicle
        if controlledVehicle ~= self.lastControlledVehicle then
            if self.lastControlledVehicle ~= nil and controlledVehicle == nil then
                -- player just exited a vehicle — refresh existing foot event state
                self.herdingVehicleEventId = nil
                local herdingActive = self.farms[g_localPlayer.farmId] ~= nil
                local text = g_i18n:getText(herdingActive and "ahl_stopHerding" or "ahl_startHerding", modName)
                g_inputBinding:setActionEventText(self.herdingEventId, text)
                g_inputBinding:setActionEventActive(self.herdingEventId, true)
                g_inputBinding:setActionEventTextVisibility(self.herdingEventId, true)
                -- reset unload event so the update loop re-evaluates it next tick
                if self.unloadTrailerEventId ~= nil then
                    g_inputBinding:setActionEventActive(self.unloadTrailerEventId, false)
                end
            end
            -- Force husbandry re-check on any vehicle-context change (enter, exit,
            -- or tab between vehicles) so the prompt state tracks the new position.
            self.ticksSinceLastHusbandryCheck = 75
            self.lastControlledVehicle = controlledVehicle
        end

        if self.farms[g_localPlayer.farmId] == nil then

            self.ticksSinceLastHusbandryCheck = self.ticksSinceLastHusbandryCheck + 1

            if self.ticksSinceLastHusbandryCheck >= 75 then

                self.ticksSinceLastHusbandryCheck = 0

                local husbandry = self:getHusbandryInRange()
                local inRange = husbandry ~= nil

                -- Mutual exclusion: hide the regular herding prompt while dog
                -- herding is active so the player can only stop via LSHIFT+B.
                if g_dogHerding ~= nil and g_dogHerding:isLocalActive() then
                    inRange = false
                end

                g_inputBinding:setActionEventActive(self.herdingEventId, inRange)
                g_inputBinding:setActionEventTextVisibility(self.herdingEventId, inRange)
                if self.herdingVehicleEventId ~= nil then
                    g_inputBinding:setActionEventActive(self.herdingVehicleEventId, inRange)
                    g_inputBinding:setActionEventTextVisibility(self.herdingVehicleEventId, inRange)
                end

                if inRange then
                    g_inputBinding:setActionEventText(self.herdingEventId, g_i18n:getText("ahl_startHerding", modName))
                    if self.herdingVehicleEventId ~= nil then
                        g_inputBinding:setActionEventText(self.herdingVehicleEventId, g_i18n:getText("ahl_startHerding", modName))
                    end
                end

                if self.animDebugEnabled then
                    print(string.format("[AHL prompt] 75-tick check: inRange=%s footId=%s vehId=%s", tostring(inRange), tostring(self.herdingEventId), tostring(self.herdingVehicleEventId)))
                end


            end

        else

            self.ticksSinceLastInputForce = self.ticksSinceLastInputForce + 1

            if self.ticksSinceLastInputForce == 100 then

                self.ticksSinceLastInputForce = 0
                self:setHerdingInputData()

            end

        end

    end

    self.ticksSinceLastAnimalHusbandryCheck = self.ticksSinceLastAnimalHusbandryCheck + 1

    local updateRelativeToPlaceables = false
    local updateRelativeToPlayers = self.ticksSinceLastAnimalHusbandryCheck % 10 == 0
    local placeables
    local trailers
    local farms = self.farms

    if self.ticksSinceLastAnimalHusbandryCheck >= 35 then

        self.ticksSinceLastAnimalHusbandryCheck = 0

        placeables = {}

        local husbandries = g_currentMission.husbandrySystem.placeables

        for _, husbandry in pairs(husbandries) do

            local farmId = husbandry:getOwnerFarmId()
            if farms[farmId] == nil then continue end

            local farm = farms[farmId]
            local matchesType = husbandry:getAnimalTypeIndex() == farm.animalTypeIndex

            if not matchesType then continue end
            if husbandry:getNumOfFreeAnimalSlots() <= 0 then continue end

            if placeables[farmId] == nil then placeables[farmId] = {} end

            table.insert(placeables[farmId], {
                ["id"] = husbandry:getUniqueId(),
                ["placeable"] = husbandry
            })

        end

        trailers = {}

        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do

            if vehicle.spec_livestockTrailer == nil then continue end

            local farmId = vehicle:getOwnerFarmId()
            if farms[farmId] == nil then continue end

            local farm = farms[farmId]
            local animalTypeIndex = farm.animalTypeIndex
            if not vehicle:getSupportsAnimalType(animalTypeIndex) then continue end

            local currentType = vehicle:getCurrentAnimalType()
            if currentType ~= nil and currentType.typeIndex ~= animalTypeIndex then continue end

            local animalType = g_currentMission.animalSystem:getTypeByIndex(animalTypeIndex)
            if vehicle:getNumOfAnimals() >= vehicle:getMaxNumOfAnimals(animalType) then continue end

            if trailers[farmId] == nil then trailers[farmId] = {} end

            local tx, _, tz = getWorldTranslation(vehicle.rootNode)
            table.insert(trailers[farmId], { ["vehicle"] = vehicle, ["x"] = tx, ["z"] = tz })

        end

        updateRelativeToPlaceables = true

    end

    local NEIGHBOR_CELL = 8
    local dtSec = dT * 0.001

    for farmId, farm in pairs(farms) do

        local animalsToRemove = {}
        local farmPlaceables
        local farmTrailers
        local players = farm.players

        -- Flag per-animal when dog herding is active on its farm. Disables
        -- grazing (which would otherwise pull calm animals back to the feed
        -- area when the dog is out of range).
        local dogHerdingActive = g_dogHerding ~= nil and g_dogHerding:isActive(farmId)

        -- While dog herding, compute the herd centroid once so each animal
        -- can receive a per-animal synthetic "guide threat" positioned on
        -- the animal's far-side from centroid. Animals flee away from that
        -- synthetic threat, which is mathematically equivalent to walking
        -- toward the centroid — and because the synthetic sits inside every
        -- species' turnDistance (5 m), the normal turn gate in HerdableAnimal
        -- engages and the animal actually rotates to face the centroid
        -- instead of just fleeing in whatever direction it was already
        -- facing (which is what happens when only the real dog is
        -- influencing the animal from well outside turnDistance).
        local GUIDE_SYNTHETIC_DIST = 5
        -- Skip the guide entirely during HOLD so animals calm down rather
        -- than continuing to creep toward the centroid with the dog paused.
        local dogGuideActive = dogHerdingActive and not g_dogHerding:isHolding(farmId)
        -- Guide target depends on FSM mode:
        --   GATHER  → centroid of the herd (consolidate scattered animals)
        --   DRIVE   → player position (rotate the tight herd to face the
        --             handler and walk toward them)
        --   other   → centroid (safe default)
        local guideTargetX, guideTargetZ
        if dogGuideActive then
            local mode = g_dogHerding:getMode(farmId)
            if mode == "DRIVE" then
                for _, pl in pairs(g_currentMission.playerSystem.players) do
                    if pl.farmId == farmId and pl.rootNode ~= nil and pl.rootNode ~= 0 then
                        local px, _, pz = getWorldTranslation(pl.rootNode)
                        guideTargetX, guideTargetZ = px, pz
                        break
                    end
                end
            end
            if guideTargetX == nil and #farm.animals > 0 then
                local cxs, czs = 0, 0
                for _, a in ipairs(farm.animals) do
                    cxs = cxs + a.position.x
                    czs = czs + a.position.z
                end
                guideTargetX = cxs / #farm.animals
                guideTargetZ = czs / #farm.animals
            end
        end

        -- Per-farm spatial hash for flocking neighbor queries
        local animalGrid = {}
        for _, a in ipairs(farm.animals) do
            local cxg = math.floor(a.position.x / NEIGHBOR_CELL)
            local czg = math.floor(a.position.z / NEIGHBOR_CELL)
            local k = cxg * 65536 + czg
            local cell = animalGrid[k]
            if cell == nil then
                cell = {}
                animalGrid[k] = cell
            end
            cell[#cell + 1] = a
        end

        if updateRelativeToPlaceables then
            farmPlaceables = placeables[farmId]
            farmTrailers = trailers[farmId]
        end

        for i, animal in ipairs(farm.animals) do

            if updateRelativeToPlaceables and farmPlaceables ~= nil then

                local hitPlaceable = animal:processPlaceableDetection(farmPlaceables)

                if hitPlaceable ~= nil then
                    table.insert(animalsToRemove, {
                        ["animal"] = i,
                        ["placeable"] = hitPlaceable
                    })
                    continue
                end

                -- Warn if a herded animal is inside a wrong-type husbandry
                local ax, az = animal.position.x, animal.position.z
                for _, h in pairs(g_currentMission.husbandrySystem.placeables) do
                    if h:getOwnerFarmId() == farmId and h:getAnimalTypeIndex() ~= farm.animalTypeIndex and h:getIsInAnimalDeliveryArea(ax, az) then
                        local now = g_time or 0
                        if self.herdingMismatchWarningTime == nil or now - self.herdingMismatchWarningTime > 5000 then
                            self.herdingMismatchWarningTime = now
                            g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_wrongHusbandryType", modName), 3000)
                        end
                        break
                    end
                end

            end

            local loadedIntoTrailer = false

            if updateRelativeToPlaceables and farmTrailers ~= nil then

                local ax, az = animal.position.x, animal.position.z

                for _, trailerData in ipairs(farmTrailers) do
                    local dist = MathUtil.vector2Length(ax - trailerData.x, az - trailerData.z)
                    if dist < 8 then
                        table.insert(animalsToRemove, {
                            ["animal"] = i,
                            ["trailer"] = trailerData.vehicle
                        })
                        loadedIntoTrailer = true
                        break
                    end
                end

            end

            if not loadedIntoTrailer then
                -- Query same-farm neighbors from spatial hash for flocking.
                local neighbors = {}
                do
                    local cxg = math.floor(animal.position.x / NEIGHBOR_CELL)
                    local czg = math.floor(animal.position.z / NEIGHBOR_CELL)
                    for ox = -1, 1 do
                        for oz = -1, 1 do
                            local cell = animalGrid[(cxg + ox) * 65536 + (czg + oz)]
                            if cell ~= nil then
                                for _, o in ipairs(cell) do
                                    if o ~= animal then neighbors[#neighbors + 1] = o end
                                end
                            end
                        end
                    end
                end
                -- Stash for animal:update() so its front-neighbor yield can reuse
                -- the same list without a second spatial-hash query.
                animal._frameNeighbors = neighbors
                animal.dogHerdingActive = dogHerdingActive

                -- Per-animal influencer list. During dog herding we inject a
                -- synthetic "guide threat" positioned 5 m behind the animal
                -- relative to the centroid so the animal's flee direction
                -- becomes unit(centroid - animal) — i.e. toward the centroid.
                -- At 5 m it sits inside every species' turnDistance so the
                -- animal actually rotates to face the centroid. The real dog
                -- still appears in the shared `players` list (via
                -- g_dogHerding:getInfluencers) and contributes to arousal
                -- buildup; the synthetic just overrides the direction.
                local animalPlayers = players
                if dogGuideActive and guideTargetX ~= nil then
                    local ax, az = animal.position.x, animal.position.z
                    local gdx, gdz = ax - guideTargetX, az - guideTargetZ
                    local gdl = math.sqrt(gdx * gdx + gdz * gdz)
                    if gdl > 0.3 then
                        local gux, guz = gdx / gdl, gdz / gdl
                        local gtx = ax + gux * GUIDE_SYNTHETIC_DIST
                        local gtz = az + guz * GUIDE_SYNTHETIC_DIST
                        animalPlayers = {}
                        for _, p in ipairs(players) do animalPlayers[#animalPlayers + 1] = p end
                        -- { x, z, isBucket, isVehicle, isGuide } — the
                        -- isGuide flag tells HerdableAnimal's sense stage
                        -- to use this influencer for flee DIRECTION only;
                        -- it does not build arousal, so animals near the
                        -- synthetic aren't permanently panicked.
                        animalPlayers[#animalPlayers + 1] = { gtx, gtz, false, false, true }
                    end
                end

                animal:updateRelativeToPlayers(animalPlayers, updateRelativeToPlayers, dtSec, neighbors)
                animal:update(dT)
            end

        end

        local farmAnimals = farm.animals
        local numAnimals = #farmAnimals

        for i = 1, numAnimals - 1 do
            local a = farmAnimals[i]
            for j = i + 1, numAnimals do
                local b = farmAnimals[j]
                local dx = a.position.x - b.position.x
                local dz = a.position.z - b.position.z
                local distSq = dx * dx + dz * dz
                local minSep = a.collisionController.radius + b.collisionController.radius + 0.3
                if distSq < minSep * minSep and distSq > 0.0001 then
                    local dist = math.sqrt(distSq)
                    local overlap = minSep - dist
                    local nx, nz = dx / dist, dz / dist

                    -- Velocity-weighted split: the animal that actually moved this
                    -- frame absorbs most of the correction. A stationary grazer keeps
                    -- its position when a walker bumps it.
                    local mvAx = a.position.x - (a.lastPosition and a.lastPosition.x or a.position.x)
                    local mvAz = a.position.z - (a.lastPosition and a.lastPosition.z or a.position.z)
                    local mvBx = b.position.x - (b.lastPosition and b.lastPosition.x or b.position.x)
                    local mvBz = b.position.z - (b.lastPosition and b.lastPosition.z or b.position.z)
                    local mvA = math.sqrt(mvAx * mvAx + mvAz * mvAz)
                    local mvB = math.sqrt(mvBx * mvBx + mvBz * mvBz)
                    local total = mvA + mvB

                    local shareA, shareB
                    if total < 0.0001 then
                        shareA, shareB = 0.5, 0.5
                    else
                        -- Each animal absorbs push proportional to the OTHER's motion
                        -- (moved more → absorbs less of the correction from the stationary one).
                        shareA = mvA / total
                        shareB = mvB / total
                    end

                    a.position.x = a.position.x + nx * overlap * shareA
                    a.position.z = a.position.z + nz * overlap * shareA
                    b.position.x = b.position.x - nx * overlap * shareB
                    b.position.z = b.position.z - nz * overlap * shareB
                    a:updatePosition()
                    b:updatePosition()
                end
            end
        end

        if self.isServer and updateRelativeToPlaceables then

            for i = #animalsToRemove, 1, -1 do
                local entry = animalsToRemove[i]
                if entry.trailer ~= nil then
                    self:returnAnimalToTrailer(farmId, entry.animal, entry.trailer)
                else
                    self:returnAnimalToPlaceable(farmId, entry.animal, farmPlaceables[entry.placeable].placeable)
                end
            end

        end

    end

    if self.movementDebugEnabled then
        self:drawMovementDebugOverlay(dT)
    end

    if self.isServer then

        self.ticksSinceLastPlayerCheck = self.ticksSinceLastPlayerCheck + 1
        self.ticksSinceLastSync = self.ticksSinceLastSync + 1

        if self.ticksSinceLastPlayerCheck >= 6 then

            self.ticksSinceLastPlayerCheck = 0
            self:updatePlayerPositions()

            for farmId, farm in pairs(farms) do farm.players = self:getPlayerPositions(farmId) end

            g_server:broadcastEvent(HerdingPlayerSyncEvent.new())

            local carriedAnimals = self.carriedAnimals

            for i = #carriedAnimals, 1, -1 do

                local carriedAnimal = carriedAnimals[i]
                local handTool = carriedAnimal.handTool
                local farmId = handTool:getOwnerFarmId()
                local animalTypeIndex = handTool:getAnimalTypeIndex()
                -- Carried animals must physically enter the delivery area to deposit;
                -- no foot-radius fallback here (pass 0).
                local husbandry = self:getHusbandryInRange(carriedAnimal.player.rootNode, animalTypeIndex, farmId, 0)

                if husbandry == nil and carriedAnimal.placeable ~= nil then
                    carriedAnimal.leaveTimer = carriedAnimal.leaveTimer + 1
                    if carriedAnimal.leaveTimer >= 50 then carriedAnimal.placeable = nil end
                end

                -- Warn the player if they are inside a husbandry that doesn't match the carried animal type
                if husbandry == nil then
                    local px, _, pz = getWorldTranslation(carriedAnimal.player.rootNode)
                    for _, h in pairs(g_currentMission.husbandrySystem.placeables) do
                        if h:getOwnerFarmId() == farmId and h:getAnimalTypeIndex() ~= animalTypeIndex and h:getIsInAnimalDeliveryArea(px, pz) then
                            local now = g_time or 0
                            if self.carriedMismatchWarningTime == nil or now - self.carriedMismatchWarningTime > 5000 then
                                self.carriedMismatchWarningTime = now
                                g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_wrongHusbandryType", modName), 3000)
                            end
                            break
                        end
                    end
                end

                if husbandry == nil or husbandry:getUniqueId() == carriedAnimal.placeable then continue end

                if husbandry:getNumOfFreeAnimalSlots() <= 0 then
                    local now = g_time or 0
                    if self.carriedFullWarningTime == nil or now - self.carriedFullWarningTime > 5000 then
                        self.carriedFullWarningTime = now
                        g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_husbandryFull", modName), 3000)
                    end
                    continue
                end

                local animal = handTool:getAnimal()

                if self:getHasHusbandryConflict() then animal.idFull, animal.id = nil, nil end

                husbandry:addCluster(animal)
                g_currentMission.handToolSystem:markHandToolForDeletion(handTool)
                table.remove(self.carriedAnimals, i)

            end

        end

        if self.ticksSinceLastSync >= 15 then
            self.ticksSinceLastSync = 0
            self:executeSyncQueue()
        end

        local farmsToRemove = {}
        local hasFarms = false

        for farmId, farm in pairs(farms) do

            if #farm.animals == 0 then
                table.insert(farmsToRemove, farmId)
                g_server:broadcastEvent(HerdingForceStopEvent.new(farmId))
            else
                hasFarms = true
            end

        end

        for _, farmId in pairs(farmsToRemove) do
            for i, j in pairs(self.syncQueue) do
                if j == farmId then table.remove(self.syncQueue, i) end
            end
            farms[farmId] = nil
        end

        if not hasFarms then self.herdingEnabled = false end

    end

    if self.handToolsPostLoad ~= nil then

        for i = #self.handToolsPostLoad, 1, -1 do
            local remove = self.handToolsPostLoad[i]:loadFromPostLoad()
            if remove then table.remove(self.handToolsPostLoad, i) end
        end

        if #self.handToolsPostLoad == 0 then self.handToolsPostLoad = nil end

    end

end


function AnimalManager:draw()

	if self.debugEnabled then

        for _, farm in pairs(self.farms) do
            for _, animal in pairs(farm.animals) do animal:visualise() end
        end

        self.debugProfiler:visualise()

	end

	if self.collisionDebugEnabled then

		for _, farm in pairs(self.farms) do
			for _, animal in pairs(farm.animals) do animal:visualiseCollisionInfo() end
		end

	end

end


-- Apply RL visual data (ear tags, bum ID, marker, monitor) to a herded animal's i3d nodes.
function AnimalManager:applyRLVisuals(animal)

    if not AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK then return end

    local rlMod = FS25_RealisticLivestock or FS25_RealisticLivestockRM
    if rlMod == nil then return end

    local createVisualAnimal = rlMod.AHL_createVisualAnimal
    if createVisualAnimal == nil then return end

    local cluster = animal.cluster
    if cluster == nil or cluster.subTypeIndex == nil then return end

    -- Fix breed: Animal.new() sets breed from subType at construction time using the default
    -- subTypeIndex, but after stream deserialization subTypeIndex is updated while breed is not.
    -- Derive the correct breed from the subType so va:load() and setMarker() use the right value.
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByIndex(cluster.subTypeIndex)
    if subType ~= nil and subType.breed ~= nil then
        cluster.breed = subType.breed
    end

    -- RL's safeIndexToObject paths (e.g. "0|0|...|1|0|0") are designed for a root node
    -- where the skeleton is at child[0]. Adults have skeletonIndex="0" so this holds
    -- naturally. Calves have skeletonIndex="1" (skeleton at child[1], mesh at child[0]),
    -- so the first "0" step hits the mesh and all paths return nil.
    --
    -- Fix: for non-zero skeletonIndex, temporarily move the mesh node to a throwaway
    -- parent so skeleton shifts to child[0], call load(), then restore the mesh.
    local cache = nil
    if subType ~= nil and animal.visualAnimalIndex ~= nil then
        cache = self:getVisualAnimalFromCache(subType.typeIndex, animal.visualAnimalIndex)
    end

    local tmpNode = nil
    if cache ~= nil and cache.skeleton ~= "0" and animal.nodes.mesh ~= nil and animal.nodes.mesh ~= 0 then
        tmpNode = createTransformGroup("_ahl_va_tmp")
        link(getRootNode(), tmpNode)
        link(tmpNode, animal.nodes.mesh)  -- detaches mesh from root; skeleton shifts to child[0]
    end

    local va = createVisualAnimal(cluster, animal.nodes.root)

    local ok, err = pcall(function() va:load() end)

    -- Always restore the mesh before early-returning, even on failure
    if tmpNode ~= nil then
        link(animal.nodes.root, animal.nodes.mesh)  -- re-attach mesh (now last child, but stored by ref)
        delete(tmpNode)
        tmpNode = nil
    end

    if not ok then
        Logging.warning("[AHL] applyRLVisuals: va:load() failed for subTypeIndex=%s age=%s breed=%s — %s",
            tostring(cluster.subTypeIndex), tostring(cluster.age), tostring(cluster.breed), tostring(err))
        return
    end

    -- setEarTagColours must run after load() so the ear tag nodes and 3D text objects exist.
    -- Colours are stored per animal TYPE (e.g. COW), not per breed.
    -- subType.typeIndex is the index into animalSystem.types[].
    if animalSystem ~= nil and subType ~= nil then
        local animalType = animalSystem.types[subType.typeIndex]
        local colours = (animalType ~= nil and animalType.colours) or animalSystem.baseColours
        if colours ~= nil then
            va:setEarTagColours(
                colours.earTagLeft,      colours.earTagLeft_text,
                colours.earTagRight,     colours.earTagRight_text
            )
        end
    end

    animal.rlVisualAnimal = va

end


function AnimalManager:returnAllCarriedAnimals()

    if not self.isServer then return end

    for i = #self.carriedAnimals, 1, -1 do
        local entry = self.carriedAnimals[i]
        self:returnCarriedAnimalToHusbandry(entry.handTool)
    end

end


function AnimalManager:returnAllHerdedAnimals()

    if not self.isServer then return end

    local farmIds = {}
    for farmId, _ in pairs(self.farms) do table.insert(farmIds, farmId) end

    for _, farmId in ipairs(farmIds) do self:stopHerding(farmId) end

end


function AnimalManager:save(filename)

    if not self.isServer then return end

    local xmlFile = XMLFile.create("animalHerding", filename, "animalHerding")
    local i = 0

    for farmId, farm in pairs(self.farms) do

        local key = string.format("animalHerding.farms.farm(%s)", i)

        xmlFile:setInt(key .. "#farmId", farmId)
        xmlFile:setInt(key .. "#animalTypeIndex", farm.animalTypeIndex)

        for j, animal in ipairs(farm.animals) do
            animal:saveToXMLFile(xmlFile, string.format("%s.animals.animal(%s)", key, j - 1))
        end

        i = i + 1

    end

    xmlFile:save(false, true)
    xmlFile:delete()

end


function AnimalManager:load()

    self.isInitialised = true
    self.isServer = g_currentMission:getIsServer()

    if not self.isServer or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end

    local xmlFile = XMLFile.loadIfExists("animalHerding", g_currentMission.missionInfo.savegameDirectory .. "/animalHerding.xml")

    if xmlFile == nil then return end

    self.farms, self.syncQueue = {}, {}

    xmlFile:iterate("animalHerding.farms.farm", function(_, key)
    
        local farmId = xmlFile:getInt(key .. "#farmId")
        local animalTypeIndex = xmlFile:getInt(key .. "#animalTypeIndex")
        local farm = {
            ["animals"] = {},
            ["players"] = {},
            ["animalTypeIndex"] = animalTypeIndex
        }

        xmlFile:iterate(key .. ".animals.animal", function(_, animalKey)
        
            local visualAnimalIndex = xmlFile:getInt(animalKey .. "#visualAnimalIndex")
            local tiles = xmlFile:getVector(animalKey .. "#tiles", { 1, 1, 1, 1 })

            local animal, navMeshAgent = self:createHerdableAnimalFromData(animalTypeIndex, visualAnimalIndex, tiles)
            animal:setHotspotFarmId(farmId)
            animal:loadFromXMLFile(xmlFile, animalKey, AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK)
            animal:applyAnimationNames()
            animal:createCollisionController(navMeshAgent.height, navMeshAgent.radius, animalTypeIndex)
		    animal:updatePosition()
		    animal:updateRotation()

		    table.insert(farm.animals, animal)
        
        end)

        if #farm.animals > 0 then
            self.farms[farmId] = farm
            self.herdingEnabled = true
            table.insert(self.syncQueue, farmId)
        end
    
    end)
    
    xmlFile:delete()
    self:updatePlayerPositions()

    for farmId, farm in pairs(self.farms) do farm.players = self:getPlayerPositions(farmId) end

end


function AnimalManager:postLoad()

    if not self.isServer then return end

end


function AnimalManager:executeSyncQueue()

    local queue = self.syncQueue

    if #queue == 0 then return end

    local farmId = queue[1]

    table.remove(queue, 1)
    if self.farms[farmId] == nil then return end
    table.insert(queue, farmId)

    g_server:broadcastEvent(HerdingSyncEvent.new(self.farms[farmId].animals, farmId))

end


function AnimalManager:updatePlayerPositions()

    local players = g_currentMission.playerSystem.players
    local positions = {}

    -- Dog herding owns the influence channel when active on a farm: the
    -- DogHerding module synthesises its own influencer list (dog body + eye
    -- tip, mode-dependent) and the player / vehicle loops are skipped for
    -- those farms entirely. This is the single integration point between
    -- dog herding and the general-herding pipeline.
    local function isFarmDogHerding(farmId)
        return g_dogHerding ~= nil and g_dogHerding:isActive(farmId)
    end

    for _, player in pairs(players) do

        local farmId = player.farmId

        if self.farms[farmId] == nil then continue end
        if isFarmDogHerding(farmId) and not self:getIsPlayerCarryingBucket(player) then continue end

        if positions[farmId] == nil then positions[farmId] = {} end

        local x, _, z = player:getPosition()
        table.insert(positions[farmId], { x, z, self:getIsPlayerCarryingBucket(player), false })

    end

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do

        local spec = vehicle.spec_enterable
        if spec == nil then continue end

        local player = spec.player
        if player == nil then continue end

        local farmId = player.farmId
        if self.farms[farmId] == nil then continue end
        if isFarmDogHerding(farmId) then continue end

        if positions[farmId] == nil then positions[farmId] = {} end

        local x, _, z = getWorldTranslation(vehicle.rootNode)
        table.insert(positions[farmId], { x, z, false, true })

    end

    -- Dog herding: for each active farm, append the dog's influencers (dog
    -- body + optional eye tip). getInfluencers returns [] during CAST and
    -- LIE_DOWN so no pressure is applied during those modes.
    if g_dogHerding ~= nil then
        for farmId, _ in pairs(self.farms) do
            if isFarmDogHerding(farmId) then
                if positions[farmId] == nil then positions[farmId] = {} end
                for _, p in ipairs(g_dogHerding:getInfluencers(farmId)) do
                    table.insert(positions[farmId], p)
                end
            end
        end
    end

    self.playerPositions = positions

end


function AnimalManager:getPlayerPositions(farmId)

    return self.playerPositions[farmId] or {}

end


function AnimalManager:setPlayerPositions(players)

    self.playerPositions = players

end


function AnimalManager:createHerdableAnimalFromData(animalTypeIndex, visualAnimalIndex, tiles)

    local cache = self:getVisualAnimalFromCache(animalTypeIndex, visualAnimalIndex)

	if cache == nil or cache.root == 0 then return end

    local node = clone(cache.root, false, false, false)
	link(getRootNode(), node)
	setVisibility(node, true)

	local shaderNode = I3DUtil.indexToObject(node, cache.shader)
	local meshNode = I3DUtil.indexToObject(node, cache.mesh)
	local skeletonNode = I3DUtil.indexToObject(node, cache.skeleton)
	local proxyNode = cache.proxy ~= nil and I3DUtil.indexToObject(node, cache.proxy)

    -- Normalise child order so skeleton is always child[0] before getAnimCharacterSet.
    -- Young animals (calves, piglets, young hens) have skeletonIndex="1" in the i3d —
    -- mesh at child[0], skeleton at child[1]. getAnimCharacterSet expects skeleton at child[0];
    -- without normalisation it fails to find skin joints and falls back to skeleton-only animation.
    if cache.skeleton ~= "0" and meshNode ~= nil and meshNode ~= 0 then
        local normTmp = createTransformGroup("_ahl_norm_tmp")
        link(getRootNode(), normTmp)
        link(normTmp, meshNode)   -- pulls mesh out; skeleton shifts to child[0]
        link(node, meshNode)      -- push mesh back as last child
        delete(normTmp)
    end

	local skinNode = getChildAt(skeletonNode, 0)
	local animationSet = getAnimCharacterSet(cache.animationUsesSkeleton and skeletonNode or skinNode)

	I3DUtil.setShaderParameterRec(meshNode, "atlasInvSizeAndOffsetUV", tiles[1], tiles[2], tiles[3], tiles[4], false)

    local animal = HerdableAnimal.new(nil, node, meshNode, shaderNode, skinNode, animationSet, cache.animation, proxyNode)
    animal:setHotspotIcon(animalTypeIndex)
    animal:setData(visualAnimalIndex, tiles[1], tiles[2], tiles[3], tiles[4])
    animal:validateSpeed(animalTypeIndex)
    animal:applyLocomotionSpeeds(cache)

    return animal, cache.navMeshAgent

end


function AnimalManager:overwriteEngineFunctions()


	local engine = {
        ["addHusbandryAnimal"] = addHusbandryAnimal,
        ["removeHusbandryAnimal"] = removeHusbandryAnimal,
        ["createAnimalHusbandry"] = createAnimalHusbandry,
        ["getAnimalRootNode"] = getAnimalRootNode,
        ["setAnimalTextureTile"] = setAnimalTextureTile
    }


	--getAnimalRootNode = function(husbandryId, animalId)

		--return engine.getAnimalRootNode(husbandryId, animalId)

	--end


    createAnimalHusbandry = function(animalTypeName, navigationNode, xmlPath, raycastDistance, collisionFilter, collisionMask, audioGroup)

        local husbandryId = engine.createAnimalHusbandry(animalTypeName, navigationNode, xmlPath, raycastDistance, collisionFilter, collisionMask, audioGroup)

        if husbandryId == 0 then return 0 end

        self.husbandries[husbandryId] = {
            ["animalTypeIndex"] = AnimalType[animalTypeName],
            ["animals"] = {}
        }

        return husbandryId

    end


    addHusbandryAnimal = function(husbandryId, visualAnimalIndex)

        local animalId = engine.addHusbandryAnimal(husbandryId, visualAnimalIndex)

        if animalId == 0 then return 0 end

        self.husbandries[husbandryId].animals[animalId] = {
            ["tiles"] = { ["u"] = 1, ["v"] = 1 },
            ["visualAnimalIndex"] = visualAnimalIndex + 1
        }

        -- ########### TODO
        -- add collisions to basegame animals (chickens) without collisions
        -- this will allow them to be picked up
        -- ###########

        --local animalTypeIndex = self.husbandries[husbandryId].animalTypeIndex
        --local cache = self:getVisualAnimalFromCache(animalTypeIndex, visualAnimalIndex)

        --if cache.proxy == nil then

            --local proxyI3D = self:getCollisionProxy(animalTypeIndex)
            --local rootNode = getAnimalRootNode(husbandryId, animalId)
            --link(rootNode, proxyI3D)
		    --setScale(proxyI3D, self.radius, self.height, self.radius)
		    --setTranslation(proxyI3D, 0, 0, -self.radius * 0.5)
		    --addToPhysics(getChildAt(proxyI3D, 0))

        --end

        return animalId

    end


    removeHusbandryAnimal = function(husbandryId, animalId)

        engine.removeHusbandryAnimal(husbandryId, animalId)

        table.removeElement(self.husbandries[husbandryId].animals, animalId)

    end


	setAnimalTextureTile = function(husbandryId, animalId, tileU, tileV)

        self.husbandries[husbandryId].animals[animalId].tiles = { ["u"] = tileU, ["v"] = tileV }

		engine.setAnimalTextureTile(husbandryId, animalId, tileU, tileV)

	end

end


function AnimalManager:validateConflicts()

    AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK = g_modIsLoaded["FS25_RealisticLivestock"] or g_modIsLoaded["FS25_RealisticLivestockRM"]
    AnimalManager.CONFLICTS.MORE_VISUAL_ANIMALS = g_modIsLoaded["FS25_MoreVisualAnimals"]

    -- Detect when an "override" animal pack (e.g. FS25_AnimalPackage_vanillaEdition)
    -- has been wired into RLRM via the in-game RL settings ("Use Custom Animals" +
    -- "Set Animals XML Path"). The pack isn't a normal Lua-loaded mod — its
    -- AnimalsLoader.lua patches AnimalSystem directly when RLRM points at it,
    -- so g_modIsLoaded never sees it. The runtime toggle lives in
    -- RLSettings.SETTINGS.useCustomAnimals.state (1=off, 2=on); when on,
    -- RLSettings.animalsXMLPath holds the pack's animals XML path.
    --
    -- Pack i3ds use custom skeletons / node hierarchies that RL's VisualAnimal
    -- va:load() can't walk — running it against a pack i3d corrupts the cloned
    -- mesh state and the engine native-crashes one frame later when rendering
    -- the carried animal (no Lua-level log). When the toggle is on we route
    -- pickup spawns through the vanilla `buildVisualNode(cache.posed)` path
    -- which uses the pack's static posed i3d — no animation set walk, no
    -- safeIndexToObject paths to break.
    -- RLSettings lives in RLRM's mod environment (not the global root scope), so
    -- we have to reach it through the mod table FS25_RealisticLivestockRM /
    -- FS25_RealisticLivestock — same access pattern AHL uses elsewhere for
    -- rlMod.source(...) cross-mod calls.
    AnimalManager.CONFLICTS.ANIMAL_PACK_VANILLA = false
    local rlMod = FS25_RealisticLivestock or FS25_RealisticLivestockRM
    local rlSettings = rlMod and rlMod.RLSettings or nil
    if rlSettings ~= nil and type(rlSettings.SETTINGS) == "table"
            and type(rlSettings.SETTINGS.useCustomAnimals) == "table"
            and rlSettings.SETTINGS.useCustomAnimals.state == 2
            and rlSettings.animalsXMLPath ~= nil
    then
        AnimalManager.CONFLICTS.ANIMAL_PACK_VANILLA = true
        Logging.info("[AHL] Custom animal pack detected via RLSettings (path=%s) — pickup uses pack-aware visual path",
            tostring(rlSettings.animalsXMLPath))
    end

    if AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK then
        local rlMod = FS25_RealisticLivestock or FS25_RealisticLivestockRM
        rlMod.source(modDirectory .. "src/animals/husbandry/cluster/Animal.lua")
        rlMod.source(modDirectory .. "src/RL_VisualAnimalBridge.lua")
    end

end


function AnimalManager:configureCollisionControllerOffsets()

    AnimalManager.ANIMAL_TYPE_INDEX_TO_AGE_OFFSET = {
        [AnimalType.COW] = 12,
	    [AnimalType.PIG] = 6,
	    [AnimalType.SHEEP] = 8,
	    [AnimalType.HORSE] = 0,
	    [AnimalType.CHICKEN] = 6
    }

end


function AnimalManager:getHasHusbandryConflict()

    return AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK or AnimalManager.CONFLICTS.MORE_VISUAL_ANIMALS

end


function AnimalManager:getVisualAnimalFromCache(animalTypeIndex, visualAnimalIndex)

	if self.cache[animalTypeIndex] == nil then self.cache[animalTypeIndex] = {} end

	local cache = self.cache[animalTypeIndex]

	--if cache[visualAnimalIndex] == nil then self:addVisualAnimalToCache(animalTypeIndex, visualAnimalIndex) end

	return cache[visualAnimalIndex]

end


function AnimalManager:addAnimalTypeToCache(animalType, baseDirectory)

	local animalTypeIndex = animalType.typeIndex
    self.cache[animalTypeIndex] = {}

	local splitPath = string.split(animalType.configFilename, "/")
    local directory = table.concat(splitPath, "/", 1, #splitPath - 1) .. "/"
	local animationI3Ds, locomotionXMLs, animationXMLs = {}, {}, {}
	local configXml = XMLFile.load("animalHusbandryConfigXML_" .. animalType.groupTitle, animalType.configFilename)

    configXml:iterate("animalHusbandry.animals.animal", function(visualAnimalIndex, key)

	    local animationI3DFilename = Utils.getFilename(configXml:getString(key .. ".assets#animation"), directory)
        local animationI3D = animationI3Ds[animationI3DFilename]

        if animationI3D == nil then
		    animationI3D = loadI3DFile(animationI3DFilename, false, false, false)
            animationI3Ds[animationI3DFilename] = animationI3D
        end

        local skeletonIndex = string.gsub(configXml:getString(key .. ".assets#skeletonIndex"), ">", "|")
	    local skeletonNode = I3DUtil.indexToObject(animationI3D, skeletonIndex)

        local shaderIndex = string.gsub(configXml:getString(key .. ".assets#shaderIndex"), ">", "|")
        local meshIndex = string.gsub(configXml:getString(key .. ".assets#meshIndex"), ">", "|")
        
        local proxyIndexLiteral = configXml:getString(key .. ".assets#proxyIndex")
        local proxyIndex
        if proxyIndexLiteral ~= nil then proxyIndex = string.gsub(proxyIndexLiteral, ">", "|") end

	    if skeletonNode == nil then

		    Logging.xmlError(configXml, "Invalid skeleton index %q given at %q. Unable to find node", skeletonIndex, key .. ".assets#skeletonIndex")

	    else

		    local skinNode = getChildAt(skeletonNode, 0)
		    local animationSet = getAnimCharacterSet(skinNode)

            if animationSet ~= 0 then

                local modelFilename = configXml:getString(key .. ".assets#filename")
                local posedFilename = configXml:getString(key .. ".assets#filenamePosed")
                local modelI3D, posedI3D

                if fileExists(Utils.getFilename(modelFilename, directory)) then
                    modelI3D = loadI3DFile(Utils.getFilename(modelFilename, directory), false, false, false)
                elseif fileExists(Utils.getFilename(modelFilename, baseDirectory)) then
                    modelI3D = loadI3DFile(Utils.getFilename(modelFilename, baseDirectory), false, false, false)
                end

                if fileExists(Utils.getFilename(posedFilename, directory)) then
                    posedI3D = loadI3DFile(Utils.getFilename(posedFilename, directory), false, false, false)
                elseif fileExists(Utils.getFilename(posedFilename, baseDirectory)) then
                    posedI3D = loadI3DFile(Utils.getFilename(posedFilename, baseDirectory), false, false, false)
                end

                if modelI3D ~= nil and posedI3D ~= nil and modelI3D ~= 0 and posedI3D ~= 0 then

                    link(getRootNode(), modelI3D)
                    link(getRootNode(), posedI3D)

                    local modelSkeletonNode = I3DUtil.indexToObject(modelI3D, skeletonIndex)
                    local modelSkinNode = getChildAt(modelSkeletonNode, 0)
                    setVisibility(modelI3D, false)

                    local numTilesU = configXml:getInt(key .. ".assets.texture(0)#numTilesU", 1)
                    local numTilesV = configXml:getInt(key .. ".assets.texture(0)#numTilesV", 1)

                    local animationUsesSkeleton = false
                    local animCloneSuccess = cloneAnimCharacterSet(skinNode, modelSkinNode)

                    if not animCloneSuccess then
                        animCloneSuccess = cloneAnimCharacterSet(skeletonNode, modelSkeletonNode)
                        animationUsesSkeleton = true
                    end

                    if animCloneSuccess and animationUsesSkeleton then Logging.warning(string.format("Animation at \'%s\' has no skin animation, using skeleton node instead", animationI3DFilename)) end

                    local modelAnimationSet = getAnimCharacterSet(animationUsesSkeleton and modelSkeletonNode or modelSkinNode)

                    if modelAnimationSet ~= 0 then

                        local height, radius = animalType.navMeshAgentAttributes.height, animalType.navMeshAgentAttributes.radius
                   
                        if proxyIndex ~= nil then
                            local proxyNode = I3DUtil.indexToObject(modelI3D, proxyIndex)
                            setScale(proxyNode, 1, 1, 0.9)
                            removeFromPhysics(proxyNode)
                        end
                        self:loadProxy(animalTypeIndex, height, radius)

                        self:loadCollisionController(animalTypeIndex, height, radius)

                        local posedMeshIndex = meshIndex

                        if tonumber(string.sub(posedMeshIndex, 1, 1)) > tonumber(string.sub(skeletonIndex, 1, 1)) then

                            posedMeshIndex = (tonumber(string.sub(posedMeshIndex, 1, 1)) - 1) .. string.sub(posedMeshIndex, 2)

                        end

                        local cache = {
                            ["root"] = modelI3D,
                            ["posed"] = posedI3D,
                            ["shader"] = shaderIndex,
                            ["mesh"] = meshIndex,
                            ["posedMesh"] = posedMeshIndex,
                            ["skeleton"] = skeletonIndex,
                            ["proxy"] = proxyIndex,
                            ["tiles"] = {
                                ["x"] = 1 / numTilesU,
                                ["y"] = 1 / numTilesV
                            },
                            ["animation"] = {},
                            ["navMeshAgent"] = {
                                ["height"] = height,
                                ["radius"] = radius
                            }
                        }

                        local locomotionFilename = Utils.getFilename(configXml:getString(key .. ".locomotion#filename"), directory)
                        local locomotionXML = locomotionXMLs[locomotionFilename]
                    
                        if locomotionXML == nil then
                            locomotionXML = XMLFile.load(string.format("locomotionXML_%s_%s", animalType.groupTitle, visualAnimalIndex), locomotionFilename)
                            locomotionXMLs[locomotionFilename] = locomotionXML
                        end

				        local animationFilename = locomotionXML:getString("locomotion.animation#filename")

                        if fileExists(Utils.getFilename(animationFilename, directory)) then
                            animationFilename = Utils.getFilename(animationFilename, directory)
                        elseif fileExists(Utils.getFilename(animationFilename, baseDirectory)) then
                            animationFilename = Utils.getFilename(animationFilename, baseDirectory)
                        else
                            local splitPathLocomotion = string.split(locomotionFilename, "/")
                            local animationDirectory = table.concat(splitPathLocomotion, "/", 1, #splitPathLocomotion - 1) .. "/"
                            if fileExists(Utils.getFilename(animationFilename, animationDirectory)) then animationFilename = Utils.getFilename(animationFilename, animationDirectory) end
                        end

                        local animation

                        for _, existingCache in pairs(self.cache[animalTypeIndex]) do

                            if existingCache.animation.filename == animationFilename then
                                animation = existingCache.animation
                                break
                            end

                        end
                    
                        if animation == nil then

                            animation = self:loadAnimations(animationFilename, modelAnimationSet, animationUsesSkeleton)

                            animation.wanderMin = configXml:getInt(key .. ".statesTimers#wanderMin", 5000)
                            animation.wanderMax = configXml:getInt(key .. ".statesTimers#wanderMax", 10000)

                            animation.idleMin = configXml:getInt(key .. ".statesTimers#idleMin", 5000)
                            animation.idleMax = configXml:getInt(key .. ".statesTimers#idleMax", 10000)

                        end

                        cache.animation = animation
                        cache.locomotionWalkSpeed = locomotionXML:getFloat("locomotion.speed#walk", nil)
                        cache.locomotionRunSpeed = locomotionXML:getFloat("locomotion.speed#run", nil)
                        cache.animationUsesSkeleton = animationUsesSkeleton

                        self.cache[animalTypeIndex][visualAnimalIndex] = cache

                    end

                else

                    if modelI3D == nil or modelI3D == 0 then Logging.warning(string.format("AnimalManager:addAnimalTypeToCache() - could not load model %s from directory (%s or %s)", modelFilename, Utils.getFilename(modelFilename, directory), Utils.getFilename(modelFilename, baseDirectory))) end
                    if posedI3D == nil or posedI3D == 0 then Logging.warning(string.format("AnimalManager:addAnimalTypeToCache() - could not load model %s from directory (%s or %s)", posedFilename, Utils.getFilename(posedFilename, directory), Utils.getFilename(posedFilename, baseDirectory))) end

                end

            end

	    end

    end)

    configXml:delete()

    for _, animationI3D in pairs(animationI3Ds) do delete(animationI3D) end
    for _, locomotionXML in pairs(locomotionXMLs) do locomotionXML:delete() end

end


function AnimalManager:cacheAnimationsFromExistingCache(cache, animationSet)

    local clipTypes = {
        "clip",
        "clipLeft",
        "clipRight"
    }

    for _, state in pairs(cache.states) do

        for _, animation in pairs(state) do

            for _, clipType in pairs(clipTypes) do

                if animation.clipType == nil then continue end

                assignAnimTrackClip(animationSet, animation[clipType].track, animation[clipType].index)

            end

        end

    end

    for _, clip in pairs(cache.clips) do

        assignAnimTrackClip(animationSet, clip.track, clip.index)

    end

    return cache

end


function AnimalManager:loadAnimations(filename, animationSet, useSkeleton)

    local xmlFile = XMLFile.load(string.format("animationXML_%s_%s", filename, animationSet), filename)

    local cache = {
        ["states"] = {},
        ["clips"] = {},
        ["filename"] = filename,
        ["useSkeleton"] = useSkeleton
    }

    if animationSet == 0 then return cache end

    local clipTypes = {
        "clip",
        "clipLeft",
        "clipRight"
    }

    xmlFile:iterate("animation.states.state", function(_, key)
    
        local stateId = xmlFile:getString(key .. "#id")
        local animations = {}

        xmlFile:iterate(key .. ".animation", function(_, animKey)
        
            local animation = {
                ["id"] = xmlFile:getString(animKey .. "#id"),
                ["transitions"] = {},
                ["speed"] = xmlFile:getFloat(animKey .. "#speed", 1.0),
                -- rotation: degrees covered per animation cycle (0 = no yaw).
                -- distance: metres translated per cycle (0 = pure in-place pose).
                -- Both are used by the turn-clip bucket picker in AnimalAnimation.
                ["rotation"] = xmlFile:getFloat(animKey .. "#rotation", 0),
                ["distance"] = xmlFile:getFloat(animKey .. "#distance", 0)
            }
            
            for _, clipType in pairs(clipTypes) do

                local clipKey = string.format("%s#%s", animKey, clipType)

                if xmlFile:hasProperty(clipKey) then

                    local clipName = xmlFile:getString(clipKey)
                    local clipIndex = getAnimClipIndex(animationSet, clipName)

                    if clipIndex ~= nil then

                        animation[clipType] = {
                            ["name"] = clipName,
                            ["index"] = clipIndex,
                            ["type"] = clipType
                        }

                    end

                end

            end

            animations[animation.id] = animation
        
        end)
        
        cache.states[stateId] = animations

    end)

    -- Build per-side turn buckets sorted ascending by rotation so the runtime
    -- can pick the smallest clip that covers the remaining angle. Every
    -- quadruped species in the engine XMLs provides turnLeft/turnRight states
    -- with 45/90/135/180° sub-clips (horse reuses one clip with speed
    -- multipliers for the larger buckets — handled at playback time via
    -- setAnimTrackSpeedScale, not here). hasTurnStates is a fast fallback
    -- flag for species that don't (baby sheep, dogs).
    cache.turnBuckets = { ["left"] = {}, ["right"] = {} }
    local function collectBuckets(stateId, side)
        local state = cache.states[stateId]
        if state == nil then return end
        for _, anim in pairs(state) do
            if (anim.clip ~= nil or anim.clipLeft ~= nil) and (anim.rotation or 0) > 0 then
                table.insert(cache.turnBuckets[side], { rotation = anim.rotation, anim = anim })
            end
        end
        table.sort(cache.turnBuckets[side], function(a, b) return a.rotation < b.rotation end)
    end
    collectBuckets("turnLeft", "left")
    collectBuckets("turnRight", "right")
    cache.hasTurnStates = #cache.turnBuckets.left > 0 and #cache.turnBuckets.right > 0

    local defaultBlendTime = xmlFile:getInt("animation.transitions#defaultBlendTime", 750)

    xmlFile:iterate("animation.transitions.transition", function(_, key)
    
        local idFrom = xmlFile:getString(key .. "#animationIdFrom")
        local idTo = xmlFile:getString(key .. "#animationIdTo")
        local blendTime = xmlFile:getInt(key .. "#blendTime", defaultBlendTime)
        local targetTime = xmlFile:getInt(key .. "#targetTime", 0)

        local clip = xmlFile:getString(key .. "#clip")
        local indexes = {}

        if clip ~= nil then

            if cache.clips[clip] == nil then

                local clipIndex = getAnimClipIndex(animationSet, clip)

                table.insert(indexes, clipIndex)

                cache.clips[clip] = {
                    ["name"] = clip,
                    ["index"] = clipIndex
                }

            end

        else

             for _, state in pairs(cache.states) do

                if state[idTo] == nil then continue end
                
                local animation = state[idTo]

                if animation.clipLeft ~= nil then table.insert(indexes, animation.clipLeft.index) end
                if animation.clipRight ~= nil then table.insert(indexes, animation.clipRight.index) end
                if animation.clip ~= nil then table.insert(indexes, animation.clip.index) end

             end

        end

        if #indexes > 0 then

            for _, state in pairs(cache.states) do

                if state[idFrom] == nil then continue end

                state[idFrom].transitions[idTo] = {
                    ["blendTime"] = blendTime,
                    ["targetTime"] = targetTime,
                    ["indexes"] = indexes
                }

            end

        end
    
    end)

    xmlFile:delete()

    return cache

end


-- footRange: optional distance (meters) fallback used when on foot if the player is
-- outside every husbandry delivery-area polygon. Defaults to 15m for the herding prompt
-- detection (forgiving near teleports). Pass 0 to require the player to physically be
-- inside a delivery area (e.g. for carried-animal auto-deposit).
function AnimalManager:getHusbandryInRange(node, animalTypeIndex, farmId, footRange)

    if farmId == nil and g_localPlayer ~= nil then farmId = g_localPlayer.farmId end

    local husbandries
    if animalTypeIndex ~= nil then
        husbandries = g_currentMission.husbandrySystem:getPlaceablesByFarm(farmId, animalTypeIndex)
    else
        -- No animal type specified — gather all owned husbandries across types.
        husbandries = {}
        for _, placeable in pairs(g_currentMission.husbandrySystem.placeables) do
            if placeable:getOwnerFarmId() == farmId then table.insert(husbandries, placeable) end
        end
    end

    local inVehicle = false
    if node == nil then
        if g_currentMission.controlledVehicle ~= nil then
            node = g_currentMission.controlledVehicle.rootNode
            inVehicle = true
        else
            node = g_localPlayer.rootNode
        end
    end
    local x, _, z = getWorldTranslation(node)

    -- Teleports typically drop the player at the husbandry's root node, which can sit
    -- a few meters outside the delivery-area polygon. Fall back to a short-radius
    -- distance check on foot so the prompt still activates after teleport.
    if footRange == nil then footRange = 15 end

    for _, husbandry in pairs(husbandries) do

        if husbandry:getIsInAnimalDeliveryArea(x, z) then return husbandry end

        local range = inVehicle and 50 or footRange
        if range > 0 then
            local hx, _, hz = getWorldTranslation(husbandry.rootNode)
            if MathUtil.vector2Length(hx - x, hz - z) < range then return husbandry end
        end

    end

    return nil

end


function AnimalManager:returnAnimalToPlaceable(farmId, animalIndex, placeable)

    local farm = self.farms[farmId]
    local animal = farm.animals[animalIndex]
    if self:getHasHusbandryConflict() then animal.cluster.idFull, animal.cluster.id = nil, nil end

    -- Hide the herded animal node before deletion so there is no visible snap
    -- from the herded position to the engine's NavMesh spawn point inside the husbandry.
    -- setAnimalPosition does not exist in FS25 so the NavMesh spawn position cannot be set.
    if animal.nodes ~= nil and animal.nodes.root ~= nil and animal.nodes.root ~= 0 then
        setVisibility(animal.nodes.root, false)
    end

    placeable:addCluster(animal.cluster)

    animal:delete()
    table.remove(farm.animals, animalIndex)

end


function AnimalManager:returnAnimalToTrailer(farmId, animalIndex, trailer)

    local farm = self.farms[farmId]
    local animal = farm.animals[animalIndex]
    if self:getHasHusbandryConflict() then animal.cluster.idFull, animal.cluster.id = nil, nil end

    trailer:addCluster(animal.cluster)

    -- RLRM 1.2.2.0 moved the cluster-system flush out of addCluster into the
    -- caller (LivestockTrailer:addAnimals batches updateNow at the tail). When
    -- we call addCluster directly we have to flush ourselves or the cluster
    -- sits in the pending-add queue and the trailer appears empty.
    if trailer.spec_livestockTrailer ~= nil and trailer.spec_livestockTrailer.clusterSystem ~= nil then
        pcall(trailer.spec_livestockTrailer.clusterSystem.updateNow, trailer.spec_livestockTrailer.clusterSystem)
    end

    animal:delete()
    table.remove(farm.animals, animalIndex)

end


function AnimalManager:removeHerdedAnimal(farmId, animal)

    if self.farms[farmId] == nil then return end

    local animals = self.farms[farmId].animals
    local id = animal.id

    for i, j in ipairs(animals) do

        if j.id == id then
            j:delete()
            table.remove(animals, i)
            return
        end

    end

end


function AnimalManager:getVisualDataForEngineAnimal(husbandryId, animalId)

    local husbandry = self.husbandries[husbandryId]

    if husbandry == nil then return nil, nil, nil end

    local animal = husbandry.animals[animalId]

    if animal == nil then return nil, nil, nil end

    return animal.visualAnimalIndex, animal.tiles.u, animal.tiles.v

end


function AnimalManager:loadCollisionController(animalTypeIndex, height, radius)

    if self.collisionControllers[animalTypeIndex] ~= nil then return end

    if self.collisionControllerTemplate == nil then
        self.collisionControllerTemplate = g_i3DManager:loadI3DFile(modDirectory .. "i3d/collisionController.i3d")
        link(getRootNode(), self.collisionControllerTemplate)
        setVisibility(self.collisionControllerTemplate, false)
    end

    local node = clone(self.collisionControllerTemplate, true, false, false)
    setScale(node, radius, height, radius)
    self.collisionControllers[animalTypeIndex] = node

end


function AnimalManager:loadProxy(animalTypeIndex, height, radius)

    if self.proxies[animalTypeIndex] ~= nil then return end

    if self.proxyTemplate == nil then
        self.proxyTemplate = g_i3DManager:loadI3DFile(modDirectory .. "i3d/proxy.i3d")
        link(getRootNode(), self.proxyTemplate)
        setVisibility(self.proxyTemplate, false)
    end

    local node = clone(self.proxyTemplate, true, false, false)
    setScale(node, radius, height, radius)
    self.proxies[animalTypeIndex] = node

end


function AnimalManager:getCollisionController(animalTypeIndex)

    return clone(self.collisionControllers[animalTypeIndex] or self.collisionControllerTemplate, true, false, false)

end


function AnimalManager:getCollisionProxy(animalTypeIndex)

    return clone(self.proxies[animalTypeIndex] or self.proxyTemplate, true, false, false)

end


function AnimalManager:getIsConnectionInitialised(connection)

    return self.connections[connection.streamId]

end


function AnimalManager:setConnectionInitialised(connection)

    self.connections[connection.streamId] = true

end


function AnimalManager:startHerding(husbandry)

    if not self.isServer then return end
 
    local farmId = husbandry:getOwnerFarmId()

    if self.farms[farmId] ~= nil then return end

    local animals = {}

    husbandry:toggleHerding(animals)

    if #animals == 0 then return end

    self.farms[farmId] = {
        ["animals"] = animals,
        ["players"] = {},
        ["animalTypeIndex"] = husbandry:getAnimalTypeIndex()
    }

    table.insert(self.syncQueue, farmId)

    self.farms[farmId].players = self:getPlayerPositions(farmId)
    self.herdingEnabled = true

    g_server:broadcastEvent(HerdingEvent.new(farmId))

end


function AnimalManager:stopHerding(farmId)

    if not self.isServer or not self.herdingEnabled or self.farms[farmId] == nil then return end

    if g_dogHerding ~= nil then g_dogHerding:deactivate(farmId) end

    local farm = self.farms[farmId]
    local placeables = g_currentMission.husbandrySystem:getPlaceablesByFarm(farmId, farm.animalTypeIndex)
    local validPlaceables = {}

    for _, placeable in pairs(placeables) do
        if placeable:getNumOfFreeAnimalSlots() > 0 then
            local x, z = getWorldTranslation(placeable.rootNode)
            table.insert(validPlaceables, {
                ["placeable"] = placeable,
                ["id"] = placeable:getUniqueId(),
                ["x"] = x,
                ["z"] = z
            })
        end
    end

    if #validPlaceables == 0 then return end

    for i = #farm.animals, 1, -1 do

        local closest
        local animal = farm.animals[i]
        local x, z = animal.position.x, animal.position.z

        -- First: check if animal is already inside a delivery area
        for j, placeable in pairs(validPlaceables) do
            if placeable.placeable:getIsInAnimalDeliveryArea(x, z) then
                closest = { ["index"] = j, ["distance"] = 0 }
                break
            end
        end

        -- Second: if not in any area, return to original husbandry
        if closest == nil then
            for j, placeable in pairs(validPlaceables) do
                if placeable.id == animal.placeable then
                    closest = { ["index"] = j, ["distance"] = math.huge }
                    break
                end
            end
        end

        -- Fallback: closest valid husbandry (original was full or removed)
        if closest == nil then
            for j, placeable in pairs(validPlaceables) do
                local distance = MathUtil.vector2Length(x - placeable.x, z - placeable.z)
                if closest == nil or distance < closest.distance then
                    closest = { ["index"] = j, ["distance"] = distance }
                end
            end
        end

        local placeable = validPlaceables[closest.index].placeable
        self:returnAnimalToPlaceable(farmId, i, placeable)

        if placeable:getNumOfFreeAnimalSlots() <= 0 then
            table.remove(validPlaceables, closest.index)
            if #validPlaceables == 0 and i ~= 1 then return end
        end

    end
        
    g_server:broadcastEvent(HerdingForceStopEvent.new(farmId))
    self.farms[farmId] = nil
    self.herdingEnabled = false

    for j, _ in pairs(self.farms) do
        self.herdingEnabled = true
        break
    end

    for i, j in pairs(self.syncQueue) do
        if j == farmId then
            table.remove(self.syncQueue, i)
            break
        end
    end

end


function AnimalManager:setHerdingInputData()

    if g_localPlayer == nil then return end

    local herdingEnabled = self.farms[g_localPlayer.farmId] ~= nil
    local text = g_i18n:getText(herdingEnabled and "ahl_stopHerding" or "ahl_startHerding", modName)

    -- Mutual exclusion: hide the regular herding prompt while dog herding is active.
    local show = herdingEnabled
    if g_dogHerding ~= nil and g_dogHerding:isLocalActive() then show = false end

    g_inputBinding:setActionEventActive(self.herdingEventId, show)
    g_inputBinding:setActionEventTextVisibility(self.herdingEventId, show)
    g_inputBinding:setActionEventText(self.herdingEventId, text)

    if self.herdingVehicleEventId ~= nil then
        g_inputBinding:setActionEventActive(self.herdingVehicleEventId, show)
        g_inputBinding:setActionEventTextVisibility(self.herdingVehicleEventId, show)
        g_inputBinding:setActionEventText(self.herdingVehicleEventId, text)
    end

    if g_dogHerding ~= nil then g_dogHerding:setDogInputData() end

end


function AnimalManager:getIsPlayerCarryingBucket(player)
    
    return self.feedBuckets[player:getUniqueId()] or false

end


function AnimalManager:setPlayerUsingBucket(player, hasBucket)

    self.feedBuckets[player:getUniqueId()] = hasBucket

end


function AnimalManager:addAnimalCollisionNode(animal, node)

    self.collisionNodes[node] = animal

end


function AnimalManager:deleteAnimalCollisionNode(node)

    table.removeElement(self.collisionNodes, node)

end


function AnimalManager:getAnimalFromCollisionNode(node, farmId)

    local animal = self.collisionNodes[node]

    if animal ~= nil and animal:getHotspotFarmId() == farmId then return animal end

    return nil

end


function AnimalManager:addCarriedAnimalToPlayer(player, handTool, placeable)

    table.insert(self.carriedAnimals, {
        ["player"] = player,
        ["handTool"] = handTool,
        ["placeable"] = placeable,
        ["leaveTimer"] = 0
    })

end


function AnimalManager:returnCarriedAnimalToHusbandry(handTool)

    local animal = handTool:getAnimal()
    local animalTypeIndex = handTool:getAnimalTypeIndex()
    local farmId = handTool:getOwnerFarmId()

    if animal == nil then
        Logging.warning("[AHL] returnCarriedAnimalToHusbandry: no animal on hand tool")
        return false
    end

    -- Find the original placeable ID from the carried animals list
    local originalPlaceableId = nil
    for _, entry in ipairs(self.carriedAnimals) do
        if entry.handTool == handTool then
            originalPlaceableId = entry.placeable
            break
        end
    end

    -- Find the original husbandry by unique ID (ignore capacity — must not lose the animal)
    local targetPlaceable = nil
    local husbandries = g_currentMission.husbandrySystem:getPlaceablesByFarm(farmId, animalTypeIndex)

    if originalPlaceableId ~= nil then
        for _, husbandry in pairs(husbandries) do
            if husbandry:getUniqueId() == originalPlaceableId then
                targetPlaceable = husbandry
                break
            end
        end
    end

    -- Fallback: closest compatible husbandry (ignore capacity to guarantee the animal is not lost)
    if targetPlaceable == nil then
        local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
        local bestDist = math.huge
        for _, husbandry in pairs(husbandries) do
            local hx, _, hz = getWorldTranslation(husbandry.rootNode)
            local dist = MathUtil.vector2Length(px - hx, pz - hz)
            if dist < bestDist then
                targetPlaceable = husbandry
                bestDist = dist
            end
        end
    end

    if targetPlaceable == nil then
        Logging.warning("[AHL] returnCarriedAnimalToHusbandry: no valid husbandry found for farmId=%s animalTypeIndex=%s", tostring(farmId), tostring(animalTypeIndex))
        return false
    end

    if self:getHasHusbandryConflict() then animal.idFull, animal.id = nil, nil end

    targetPlaceable:addCluster(animal)

    -- Flush immediately so the cluster is in the husbandry data before the save writes
    local clusterSystem = targetPlaceable:getClusterSystem()
    if clusterSystem ~= nil then clusterSystem:updateNow() end

    -- Remove from carried animals list
    for i = #self.carriedAnimals, 1, -1 do
        if self.carriedAnimals[i].handTool == handTool then
            table.remove(self.carriedAnimals, i)
            break
        end
    end

    g_currentMission.handToolSystem:markHandToolForDeletion(handTool)

    return true

end


function AnimalManager:loadCarriedAnimalIntoTrailer(handTool, trailer)

    local animal = handTool:getAnimal()

    if animal == nil then
        Logging.warning("[AHL] loadCarriedAnimalIntoTrailer: no animal on hand tool")
        return false
    end

    if trailer == nil or trailer.spec_livestockTrailer == nil then
        Logging.warning("[AHL] loadCarriedAnimalIntoTrailer: invalid trailer")
        return false
    end

    if self:getHasHusbandryConflict() then animal.idFull, animal.id = nil, nil end

    trailer:addCluster(animal)

    -- Flush the trailer's pending-add queue so the cluster is actually
    -- present this frame — see comment in returnAnimalToTrailer.
    if trailer.spec_livestockTrailer.clusterSystem ~= nil then
        pcall(trailer.spec_livestockTrailer.clusterSystem.updateNow, trailer.spec_livestockTrailer.clusterSystem)
    end

    for i = #self.carriedAnimals, 1, -1 do
        if self.carriedAnimals[i].handTool == handTool then
            table.remove(self.carriedAnimals, i)
            break
        end
    end

    g_currentMission.handToolSystem:markHandToolForDeletion(handTool)

    return true

end


function AnimalManager:addHandToolToSetOnPostLoad(handTool)

    table.insert(self.handToolsPostLoad, handTool)

end


function AnimalManager:getAnimalTypeIndexForFarm(farmId)

    if self.farms[farmId] == nil then return nil end

    return self.farms[farmId].animalTypeIndex

end


function AnimalManager:unloadTrailerIntoHusbandry(farmId, trailer, husbandry)

    if not self.isServer then return end

    local spec = trailer.spec_livestockTrailer
    if spec == nil then return end

    local clusterSystem = spec.clusterSystem
    if clusterSystem == nil then
        Logging.warning("[AHL] unloadTrailerIntoHusbandry: trailer has no clusterSystem — cannot transfer clusters")
        return
    end

    local clusters = clusterSystem:getClusters()
    if clusters == nil or #clusters == 0 then return end

    local freeSlots = husbandry:getNumOfFreeAnimalSlots()

    if freeSlots <= 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_husbandryFull", modName), 3000)
        return
    end

    -- Count total animals in the trailer
    local totalAnimalsInTrailer = 0
    for _, cluster in ipairs(clusters) do
        totalAnimalsInTrailer = totalAnimalsInTrailer + (cluster.numAnimals or 1)
    end

    if totalAnimalsInTrailer > freeSlots then
        g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_notEnoughSpace", modName), 3000)
        return
    end

    -- Copy array first: addPendingRemoveCluster modifies the underlying table during iteration
    local clustersToTransfer = {}
    for _, cluster in ipairs(clusters) do
        table.insert(clustersToTransfer, cluster)
    end

    local hasConflict = self:getHasHusbandryConflict()

    for _, cluster in ipairs(clustersToTransfer) do
        if hasConflict then
            cluster.idFull, cluster.id = nil, nil
        end
        husbandry:addCluster(cluster)
        clusterSystem:addPendingRemoveCluster(cluster)
    end

    -- Flush pending removals immediately so the trailer empties in the same frame.
    -- Mirrors LivestockTrailer:addCluster which always calls updateNow() after addPendingAddCluster.
    clusterSystem:updateNow()

end


function AnimalManager.onUnloadTrailer()

    if g_localPlayer == nil then return end

    local td = g_animalManager.localTrailerUnload
    if td == nil then return end

    g_animalManager:unloadTrailerIntoHusbandry(g_localPlayer.farmId, td.trailer, td.husbandry)

end


function AnimalManager:checkAnimalDialogStop()

    if g_gui == nil then return end

    local currentGuiName = g_gui.currentGuiName or ""

    if currentGuiName == self.lastGuiName then return end

    local previousGuiName = self.lastGuiName
    self.lastGuiName = currentGuiName

    -- When a GUI closes (transitions to empty), the player is returning to gameplay.
    -- Tab-through-vehicles + teleport-via-map can leave the HerdingLite foot event
    -- in a broken display state. Nuking and re-registering the event fixes it.
    if currentGuiName == "" and previousGuiName ~= nil and previousGuiName ~= "" then
        self:refreshHerdingFootEvent()
    end

    if currentGuiName == "" then return end
    if g_localPlayer == nil then return end

    local lower = currentGuiName:lower()

    -- Dog herding is fragile (custom physics + companion animal API). If the player
    -- opens the in-game/pause menu while dog herding is active, stop it so animals
    -- return to their husbandry before the player goes idle in menus.
    if g_dogHerding ~= nil and g_dogHerding:isLocalActive() and lower:find("ingamemenu") ~= nil then
        g_dogHerding:stopLocal()
        return
    end

    if self.farms[g_localPlayer.farmId] == nil then return end
    if g_client == nil then return end

    -- Ignore in-game menu frames — opening the pause menu to teleport / tab vehicles
    -- briefly surfaces the last active tab (e.g. InGameMenuAnimalsFrame) as currentGuiName,
    -- which should not count as entering the husbandry buy/sell dialog.
    if lower:find("ingamemenu") ~= nil or lower:find("frame") ~= nil then return end

    if lower:find("animal") == nil and lower:find("husbandry") == nil then return end

    Logging.info("[AHL] Animal GUI '%s' opened while herding — returning herded animals", currentGuiName)

    local serverConnection = g_client:getServerConnection()
    if serverConnection ~= nil then
        serverConnection:sendEvent(HerdingRequestEvent.new(false, nil, g_localPlayer.farmId))
    end

end


-- Watch for input-context transitions (e.g. tab through vehicles: PLAYER →
-- VEHICLE → PLAYER). These switches don't surface any GUI, so the GUI-close
-- hook in checkAnimalDialogStop never fires — yet the foot event's display
-- state can still get stuck. When the context returns to on-foot, refresh.
function AnimalManager:checkInputContextChange()

    if g_inputBinding == nil then return end
    if PlayerInputComponent == nil or PlayerInputComponent.INPUT_CONTEXT_NAME == nil then return end
    if g_localPlayer == nil then return end

    local currentContext = g_inputBinding:getContextName() or ""
    if currentContext == self.lastInputContext then return end

    local previousContext = self.lastInputContext
    self.lastInputContext = currentContext

    -- Refresh whenever we land back on the player input context from some
    -- other context (vehicle, menu, etc.). Don't gate on herding-active —
    -- the "start herding" prompt gets stuck too, not just "stop herding".
    if currentContext == PlayerInputComponent.INPUT_CONTEXT_NAME
        and previousContext ~= nil and previousContext ~= ""
        and previousContext ~= PlayerInputComponent.INPUT_CONTEXT_NAME then
        self:refreshHerdingFootEvent()
    end

end


-- Remove + re-register the HerdingLite foot action event. Used as a recovery step
-- whenever we detect the player has returned to gameplay from a menu/dialog, because
-- tab-through-vehicles + teleport can leave the event in a broken display state
-- (setActionEventActive no longer affects the F1 menu until the event is re-registered).
function AnimalManager:refreshHerdingFootEvent()

    if g_inputBinding == nil then return end
    if PlayerInputComponent == nil or InputAction == nil or InputAction.HerdingLite == nil then return end

    -- Precompute the correct display state so we can apply it to the freshly
    -- registered event right away. If we only register and wait for the 75-tick
    -- husbandry check, the prompt stays blank until that tick fires.
    local husbandry = self:getHusbandryInRange()
    local inRange = husbandry ~= nil
    local herdingActive = g_localPlayer ~= nil and self.farms[g_localPlayer.farmId] ~= nil
    local key = herdingActive and "ahl_stopHerding" or "ahl_startHerding"
    local text = g_i18n:getText(key, modName)
    local active = inRange or herdingActive

    local oldFootId = self.herdingEventId
    local oldPickupId = self.pickupEventId

    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    if oldFootId ~= nil and oldFootId ~= "" then
        g_inputBinding:removeActionEvent(oldFootId)
    end

    local _, newEventId = g_inputBinding:registerActionEvent(
        InputAction.HerdingLite, AnimalManager, AnimalManager.onToggleHerding,
        false, true, false, true, nil, false
    )

    -- Also refresh AHLPickup (pickup E-key event). After vehicle-teleport input
    -- context churn the prompt would otherwise stay invisible until the next
    -- registerGlobalPlayerActionEvents fires (which doesn't always happen on
    -- teleport-via-map). Same begin/end transaction.
    local newPickupId
    if InputAction.AHLPickup ~= nil and self._onAHLPickupAction ~= nil then
        if oldPickupId ~= nil and oldPickupId ~= "" then
            g_inputBinding:removeActionEvent(oldPickupId)
        end
        _, newPickupId = g_inputBinding:registerActionEvent(
            InputAction.AHLPickup, AnimalManager, self._onAHLPickupAction,
            false, true, false, true, nil, false
        )
    end

    g_inputBinding:endActionEventsModification()

    if newPickupId ~= nil and newPickupId ~= "" then
        self.pickupEventId = newPickupId
        g_inputBinding:setActionEventTextPriority(newPickupId, GS_PRIO_VERY_HIGH)
        -- Default the prompt off; the next PlayerInputComponent.update tick
        -- re-runs the proximity check and calls activatePickupPrompt if a
        -- pickup target is in range.
        g_inputBinding:setActionEventActive(newPickupId, false)
        g_inputBinding:setActionEventTextVisibility(newPickupId, false)
    end

    if newEventId == nil or newEventId == "" then return end

    self.herdingEventId = newEventId
    g_inputBinding:setActionEventTextPriority(newEventId, GS_PRIO_VERY_HIGH)
    g_inputBinding:setActionEventText(newEventId, text)
    g_inputBinding:setActionEventActive(newEventId, active)
    g_inputBinding:setActionEventTextVisibility(newEventId, active)

    -- Also re-sync the in-vehicle event so its prompt matches.
    if self.herdingVehicleEventId ~= nil then
        g_inputBinding:setActionEventActive(self.herdingVehicleEventId, active)
        g_inputBinding:setActionEventTextVisibility(self.herdingVehicleEventId, active)
        g_inputBinding:setActionEventText(self.herdingVehicleEventId, text)
    end

    -- Next husbandry check will re-validate and correct anything that changes.
    self.ticksSinceLastHusbandryCheck = 75

    if self.animDebugEnabled then
        Logging.info("[AHL] refreshHerdingFootEvent: %s → %s (active=%s)", tostring(oldFootId), tostring(newEventId), tostring(active))
    end

end


function AnimalManager.onToggleHerding()

    if g_localPlayer == nil then return end

    if g_animalManager.farms[g_localPlayer.farmId] ~= nil then

        g_client:getServerConnection():sendEvent(HerdingRequestEvent.new(false, nil, g_localPlayer.farmId))

    else

        local husbandry = g_animalManager:getHusbandryInRange()

        if husbandry ~= nil then
            g_client:getServerConnection():sendEvent(HerdingRequestEvent.new(true, husbandry))
        else
            g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_notInHusbandry", modName), 2500)
        end

    end

end


function AnimalManager.consoleCommandToggleDebug()

	g_animalManager.debugEnabled = not g_animalManager.debugEnabled
	g_animalManager.debugProfiler.debugEnabled = g_animalManager.debugEnabled

	return string.format("Animal debug mode: %s", g_animalManager.debugEnabled and "on" or "off")

end


function AnimalManager.consoleCommandToggleCollisionDebug()

	g_animalManager.collisionDebugEnabled = not g_animalManager.collisionDebugEnabled

	return string.format("Animal collision debug: %s", g_animalManager.collisionDebugEnabled and "on" or "off")

end


function AnimalManager.consoleCommandToggleAnimDebug()

	g_animalManager.animDebugEnabled = not g_animalManager.animDebugEnabled
	g_animalManager.animDebugTimer = 0

	return string.format("Animal animation debug: %s", g_animalManager.animDebugEnabled and "on" or "off")

end


-- Visual debug overlay for animation + movement diagnostics. Toggled via
-- the `toggleAnimalMovementDebug` console command. Draws 3D text above each
-- herded animal with the signals most relevant to flicker / speed-mismatch
-- issues:
--   state      I / W / R         current primary state flag
--   turn       T→XX°              state.isTurning + remaining angle to target
--   clip       <id>               current anim clip id on track 0
--   speed      cur / tgt          self.speed vs animation:getMovementSpeed()
--   scale      move × play        lastMoveSpeedScale × playback ratio
--   flips/s    #                  state transitions per second (walk↔idle etc)
--   installs/s #                  anim track (re)installs per second
--   graze      ON / off           grazing mode + distance to current graze target
function AnimalManager.consoleCommandToggleMovementDebug()

	g_animalManager.movementDebugEnabled = not g_animalManager.movementDebugEnabled
	return string.format("Animal movement debug: %s", g_animalManager.movementDebugEnabled and "on" or "off")

end


-- Called each tick from AnimalManager:update while movementDebugEnabled.
-- Iterates every herded animal on every farm and renders its state panel.
function AnimalManager:drawMovementDebugOverlay(dT)

	local g_time_now = g_time or 0

	for _, farm in pairs(self.farms) do
		for _, animal in pairs(farm.animals or {}) do
			self:drawMovementDebugForAnimal(animal, dT, g_time_now)
		end
	end

end


function AnimalManager:drawMovementDebugForAnimal(animal, dT, now)

	if animal == nil or animal.position == nil then return end
	local state = animal.state
	if state == nil then return end

	-- Track state changes for flip rate.
	local primary
	if state.isIdle then primary = "I"
	elseif state.isWalking then primary = "W"
	elseif state.isRunning then primary = "R"
	else primary = "?" end

	animal._mdbgFlips = animal._mdbgFlips or {}
	if animal._mdbgLastState ~= primary then
		table.insert(animal._mdbgFlips, now)
		animal._mdbgLastState = primary
	end
	-- Trim flips outside the 2 s window.
	while #animal._mdbgFlips > 0 and now - animal._mdbgFlips[1] > 2000 do
		table.remove(animal._mdbgFlips, 1)
	end
	local flipRate = #animal._mdbgFlips / 2

	-- Clip install rate (tracked on AnimalAnimation._mdbgInstallTimes).
	local installRate = 0
	if animal.animation ~= nil and animal.animation._mdbgInstallTimes ~= nil then
		local times = animal.animation._mdbgInstallTimes
		while #times > 0 and now - times[1] > 2000 do table.remove(times, 1) end
		installRate = #times / 2
	end

	-- Current primary clip on track 0 (or first enabled track).
	local clipName = "-"
	local trackSpeed = 0
	if animal.animation ~= nil and animal.animation.tracks ~= nil then
		for _, t in pairs(animal.animation.tracks) do
			if t.enabled then
				if t.clip ~= nil and t.clip.name ~= nil then
					clipName = t.clip.name
				end
				trackSpeed = t.speed or 0
				break
			end
		end
	end

	-- Remaining turn angle.
	local turnStr = "-"
	if state.isTurning then
		local remaining = (state.targetDirY or 0) - (animal.rotation and animal.rotation.y or 0)
		while remaining > math.pi do remaining = remaining - 2 * math.pi end
		while remaining <= -math.pi do remaining = remaining + 2 * math.pi end
		turnStr = string.format("T %+4.0f°", math.deg(remaining))
	end

	-- Speeds.
	local curSpeed = animal.speed or 0
	local tgtSpeed = 0
	if animal.animation ~= nil and animal.animation.getMovementSpeed ~= nil then
		tgtSpeed = animal.animation:getMovementSpeed() or 0
	end

	local moveScale = animal.lastMoveSpeedScale or 1
	local playScale = (animal.animation and animal.animation._lastPlaybackScale) or 1

	-- Grazing info.
	local grazeStr = "-"
	if animal.isGrazing then
		if animal.grazeTarget ~= nil then
			local gdx = animal.grazeTarget.x - animal.position.x
			local gdz = animal.grazeTarget.z - animal.position.z
			local gdist = math.sqrt(gdx * gdx + gdz * gdz)
			grazeStr = string.format("GRAZE %.1fm", gdist)
		else
			grazeStr = "GRAZE (idle)"
		end
	end

	-- Compose lines.
	local lines = {
		string.format("%s  %s", primary, turnStr),
		string.format("clip %s (s=%.2f)", clipName, trackSpeed),
		string.format("v %.2f/%.2f m/s  scale %.2fx%.2f", curSpeed, tgtSpeed, moveScale, playScale),
		string.format("flips %.1f/s  installs %.1f/s", flipRate, installRate),
		grazeStr
	}

	-- Colour by flicker severity. Thresholds reflect what a healthy animal
	-- can hit from natural behaviour (e.g. a short graze cycle is ~3
	-- installs in 2 s = 1.5/s). Green = healthy, yellow = busy but
	-- plausible (graze cycles, transitions), red = real flicker loop.
	local r, g, b = 0.6, 1.0, 0.6
	if installRate > 2.5 then r, g, b = 1.0, 0.4, 0.4
	elseif installRate > 1.5 or flipRate > 2.5 then r, g, b = 1.0, 1.0, 0.4 end

	local x, y, z = animal.position.x, animal.position.y, animal.position.z
	setTextColor(r, g, b, 1)
	setTextAlignment(RenderText.ALIGN_CENTER)
	local size = 0.17
	local yBase = y + 2.2
	for i, line in ipairs(lines) do
		renderText3D(x, yBase - (i - 1) * (size * 1.2), z, 0, 0, 0, size, line)
	end
	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextColor(1, 1, 1, 1)

end


function AnimalManager.consoleCommandRefreshPrompt()

	local self = g_animalManager
	if g_localPlayer == nil then return "no local player" end

	local husbandry = self:getHusbandryInRange()
	local inRange = husbandry ~= nil
	local herdingActive = self.farms[g_localPlayer.farmId] ~= nil
	local key = herdingActive and "ahl_stopHerding" or "ahl_startHerding"
	local text = g_i18n:getText(key, modName)
	local active = inRange or herdingActive

	-- Nuclear approach: fully unregister, then register fresh. Rules out any stale
	-- internal flags on the existing event.
	local oldFootId = self.herdingEventId
	g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

	if oldFootId ~= nil and oldFootId ~= "" then
		g_inputBinding:removeActionEvent(oldFootId)
	end

	local _, newEventId = g_inputBinding:registerActionEvent(
		InputAction.HerdingLite, AnimalManager, AnimalManager.onToggleHerding,
		false, true, false, true, nil, false
	)
	g_inputBinding:endActionEventsModification()

	if newEventId ~= nil and newEventId ~= "" then
		self.herdingEventId = newEventId
		g_inputBinding:setActionEventTextPriority(newEventId, GS_PRIO_VERY_HIGH)
		g_inputBinding:setActionEventText(newEventId, text)
		g_inputBinding:setActionEventActive(newEventId, active)
		g_inputBinding:setActionEventTextVisibility(newEventId, active)
	end

	if self.herdingVehicleEventId ~= nil then
		g_inputBinding:setActionEventActive(self.herdingVehicleEventId, active)
		g_inputBinding:setActionEventTextVisibility(self.herdingVehicleEventId, active)
		g_inputBinding:setActionEventText(self.herdingVehicleEventId, text)
	end

	return string.format("Refreshed (remove+re-register). active=%s text='%s' husbandryInRange=%s oldFootId=%s newFootId=%s vehId=%s",
		tostring(active), text, tostring(husbandry), tostring(oldFootId), tostring(self.herdingEventId), tostring(self.herdingVehicleEventId))

end


function AnimalManager.consoleCommandDumpInputState()

	local self = g_animalManager
	local controlledVehicle = g_currentMission and g_currentMission.controlledVehicle
	local player = g_localPlayer

	print("===== [AHL] Herding input state =====")
	print(string.format("  g_localPlayer = %s   farmId = %s", tostring(player), tostring(player and player.farmId)))
	print(string.format("  input context = %s", tostring(g_inputBinding and g_inputBinding:getContextName() or "?")))
	print(string.format("  controlledVehicle = %s   lastControlledVehicle = %s", tostring(controlledVehicle), tostring(self.lastControlledVehicle)))

	local dogFarm = nil
	if g_dogHerding ~= nil and player ~= nil then dogFarm = g_dogHerding.farms[player.farmId] end
	print(string.format("  regularHerding farms[local] = %s", tostring(player and self.farms[player.farmId])))
	print(string.format("  dogHerding farms[local] = %s   isLocalActive = %s   dogEventId = %s",
		tostring(dogFarm),
		tostring(g_dogHerding and g_dogHerding:isLocalActive()),
		tostring(g_dogHerding and g_dogHerding.dogEventId)))
	print(string.format("  herdingEventId = %s (foot)", tostring(self.herdingEventId)))
	print(string.format("  herdingVehicleEventId = %s", tostring(self.herdingVehicleEventId)))
	print(string.format("  unloadTrailerEventId = %s", tostring(self.unloadTrailerEventId)))
	print(string.format("  ticksSinceLastHusbandryCheck = %s", tostring(self.ticksSinceLastHusbandryCheck)))
	print(string.format("  herdingEnabled = %s   farms[localFarm] = %s", tostring(self.herdingEnabled), tostring(player and self.farms[player.farmId])))

	-- Compute husbandry check result
	if player ~= nil then
		local husb = self:getHusbandryInRange()
		print(string.format("  getHusbandryInRange() = %s", tostring(husb)))

		local px, _, pz
		if controlledVehicle ~= nil then
			px, _, pz = getWorldTranslation(controlledVehicle.rootNode)
			print(string.format("  querying from vehicle at (%.2f, %.2f)", px, pz))
		else
			px, _, pz = getWorldTranslation(player.rootNode)
			print(string.format("  querying from player at (%.2f, %.2f)", px, pz))
		end

		print("  --- owned husbandries ---")
		for _, placeable in pairs(g_currentMission.husbandrySystem.placeables) do
			if placeable:getOwnerFarmId() == player.farmId then
				local hx, _, hz = getWorldTranslation(placeable.rootNode)
				local dist = MathUtil.vector2Length(hx - px, hz - pz)
				local inArea = placeable:getIsInAnimalDeliveryArea(px, pz)
				print(string.format("    husbandry=%s type=%s dist=%.2f inDeliveryArea=%s",
					tostring(placeable:getUniqueId()), tostring(placeable:getAnimalTypeIndex()), dist, tostring(inArea)))
			end
		end
	end

	return "Dumped herding input state."

end


function AnimalManager.consoleCommandDumpAnimCache()

	local animalSystem = g_currentMission and g_currentMission.animalSystem
	local seen = {}
	local count = 0

	for _, farm in pairs(g_animalManager.farms) do

		for _, animal in pairs(farm.animals) do

			count = count + 1

			local typeName = "?"
			if animalSystem ~= nil and animal.animalTypeIndex ~= nil then
				local at = animalSystem:getTypeByIndex(animal.animalTypeIndex)
				if at ~= nil and at.name ~= nil then typeName = at.name end
			end

			local age = (animal.cluster ~= nil and animal.cluster.age) or -1
			local key = string.format("%s|%s", typeName, tostring(animal.visualAnimalIndex))
			if seen[key] then continue end
			seen[key] = true

			print(string.format("===== [AHL] Animation cache for %s (visualIdx=%s, age=%s) =====", typeName, tostring(animal.visualAnimalIndex), tostring(age)))

			if animal.animation == nil or animal.animation.cache == nil then
				print("  (no cache)")
				continue
			end

			local states = animal.animation.cache.states or {}
			for stateId, state in pairs(states) do
				print(string.format("  state '%s':", stateId))
				for animId, entry in pairs(state) do
					local cl = entry.clip and entry.clip.name or "-"
					local cL = entry.clipLeft and entry.clipLeft.name or "-"
					local cR = entry.clipRight and entry.clipRight.name or "-"
					print(string.format("    id=%-12s clip=%-22s clipLeft=%-22s clipRight=%-22s speed=%.3f",
						animId, cl, cL, cR, entry.speed or -1))
				end
			end

		end

	end

	return string.format("Dumped animation cache for %d herded animal(s).", count)

end


function AnimalManager:logAnimDebug()

	local animalSystem = g_currentMission and g_currentMission.animalSystem
	local totalAnimals = 0

	for farmId, farm in pairs(self.farms) do

		for _, animal in pairs(farm.animals) do

			totalAnimals = totalAnimals + 1

			local typeName = "?"
			if animalSystem ~= nil and animal.animalTypeIndex ~= nil then
				local animalType = animalSystem:getTypeByIndex(animal.animalTypeIndex)
				if animalType ~= nil and animalType.name ~= nil then typeName = animalType.name end
			end

			local age = (animal.cluster ~= nil and animal.cluster.age) or -1

			local clips = {}
			if animal.animation ~= nil and animal.animation.tracks ~= nil then
				for _, track in pairs(animal.animation.tracks) do
					if track.enabled and track.clip ~= nil and track.clip.name ~= nil then
						table.insert(clips, string.format("%s(%s b=%.2f)", track.id or "?", track.clip.name, track.blend or 0))
					end
				end
			end

			local clipStr = #clips > 0 and table.concat(clips, ", ") or "none"

			local transitionStr = "none"
			if animal.animation ~= nil and animal.animation.transition ~= nil then
				local t = animal.animation.transition
				local fromIds, toIds = {}, {}
				for _, tr in pairs(t.from or {}) do table.insert(fromIds, tr.id or "?") end
				for _, tr in pairs(t.to or {}) do table.insert(toIds, tr.id or "?") end
				transitionStr = string.format("%s -> %s", table.concat(fromIds, "+"), table.concat(toIds, "+"))
			end

			local movementSpeed = animal.animation ~= nil and animal.animation:getMovementSpeed() or 0
			local animSpeed = animal.speed or 0

			local names = animal.animNames or {}

			local walkMod, runMod, idleMod = 0, 0, 0
			if animal.animation ~= nil and animal.animation.speedModifiers ~= nil then
				walkMod = animal.animation.speedModifiers["walk"] or 1
				runMod  = animal.animation.speedModifiers["run"]  or 1
				idleMod = animal.animation.speedModifiers["idle"] or 1
			end

			-- Show what's actually resolved from the cache for each configured ID
			local function resolved(stateId, wantedId)
				if animal.animation == nil or animal.animation.cache == nil then return "nocache" end
				local state = animal.animation.cache.states[stateId]
				if state == nil then return "no-state" end
				local entry = state[wantedId]
				if entry == nil then return string.format("%s:MISSING", wantedId) end
				local cl = entry.clip and entry.clip.name or "-"
				local cL = entry.clipLeft and entry.clipLeft.name or "-"
				local cR = entry.clipRight and entry.clipRight.name or "-"
				return string.format("%s->(clip=%s L=%s R=%s spd=%.2f)", wantedId, cl, cL, cR, entry.speed or -1)
			end

			local liveSpeedScale0, liveSpeedScale1 = "-", "-"
			if animal.animation ~= nil and animal.animation.animationSet ~= nil then
				local ok0, s0 = pcall(getAnimTrackSpeedScale, animal.animation.animationSet, 0)
				local ok1, s1 = pcall(getAnimTrackSpeedScale, animal.animation.animationSet, 1)
				if ok0 then liveSpeedScale0 = string.format("%.3f", s0 or 0) end
				if ok1 then liveSpeedScale1 = string.format("%.3f", s1 or 0) end
			end

			print(string.format("[AHL anim] farm=%s id=%s type=%s age=%s | clips=[%s] transition=%s | speed=%.3f movSpeed=%.3f | mods walk=%.3f run=%.3f idle=%.3f | trackScale 0=%s 1=%s | cache: %s / %s / %s",
				tostring(farmId),
				tostring(animal.id),
				typeName,
				tostring(age),
				clipStr,
				transitionStr,
				animSpeed,
				movementSpeed,
				walkMod, runMod, idleMod,
				liveSpeedScale0, liveSpeedScale1,
				resolved("walk", names.walk or "walk1"),
				resolved("idle", names.idle or "idle1"),
				resolved("run", names.run or "run1")
			))

		end

	end

	if totalAnimals == 0 then print("[AHL anim] no herded animals") end

end


g_animalManager = AnimalManager.new()