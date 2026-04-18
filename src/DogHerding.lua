DogHerding = {}


local DogHerding_mt = Class(DogHerding)
local modName = g_currentModName
local modDirectory = g_currentModDirectory


local DOG_APPROACH_SPEED = 4.0
local DOG_MOVE_COMMAND_INTERVAL = 4   -- Re-issue GotoEntity every N ticks (~64ms @ 60Hz)
local DOG_HOUSE_INTERACT_RANGE = 8

-- Two-mode FSM with hysteresis. In GATHER the dog targets the furthest
-- outlier from the herd centroid and parks 1.5m past it; the outlier flees
-- away from the dog → back toward the rest of the herd. Once the herd is
-- tight (max spread ≤ DRIVE_THRESHOLD) the dog switches to DRIVE and parks
-- at the balance point (herd centroid + unit(centroid-player) × walkDist × 0.5);
-- the whole herd flees away from the dog → toward the handler.
-- GATHER_THRESHOLD > DRIVE_THRESHOLD prevents mode flapping at the boundary.
local GATHER_THRESHOLD       = 5.0    -- max spread above which DRIVE flips to GATHER
local DRIVE_THRESHOLD        = 3.0    -- max spread below which GATHER flips to DRIVE
local DRIVE_BALANCE_FRACTION = 0.35   -- balance point = walkDist × this past herd
local OUTLIER_APPROACH_DIST  = 1.0    -- how far past the outlier the dog parks





function DogHerding.new()

	local self = setmetatable({}, DogHerding_mt)

	self.farms = {}
	self.isServer = g_currentMission:getIsServer()
	self.isClient = g_currentMission:getIsClient()

	-- Lazy-loaded 2D whistle sample played locally when calling the dog.
	self.whistleSample = nil

	addConsoleCommand("dumpDogInfo", "Dump FS25 dog/companion info to log", "consoleCommandDumpDogInfo", self)
	addConsoleCommand("dumpDogNearby", "Check whether the local player is near their dog house with a dog", "consoleCommandDumpDogNearby", self)
	addConsoleCommand("dumpDogHerdState", "Dump what animals see as influencers during dog herding", "consoleCommandDumpDogHerdState", self)
	addConsoleCommand("callDog", "If near your dog house, command the dog to follow you", "consoleCommandCallDog", self)
	addConsoleCommand("sendDogHome", "Send your dog back to its doghouse", "consoleCommandSendDogHome", self)

	return self

end


-- Find a doghouse + dog owned by the given farm within maxRange of `node`.
-- Returns (dog, doghouse, distance) or nil if no match.
function DogHerding:findDogHouseNearNode(node, maxRange, farmId)

	if node == nil or node == 0 then return nil end
	if g_currentMission == nil or g_currentMission.doghouses == nil then return nil end

	local nx, _, nz = getWorldTranslation(node)
	local bestDog, bestHouse, bestDist

	for _, dh in pairs(g_currentMission.doghouses) do

		if farmId ~= nil and dh.ownerFarmId ~= farmId then continue end
		if dh.rootNode == nil or dh.rootNode == 0 then continue end

		local hx, _, hz = getWorldTranslation(dh.rootNode)
		local dist = MathUtil.vector2Length(hx - nx, hz - nz)

		if dist > maxRange then continue end

		local ok, dog = pcall(dh.getDog, dh)
		if not ok or dog == nil or dog.dogInstance == nil then continue end

		if bestDist == nil or dist < bestDist then
			bestDog = dog
			bestHouse = dh
			bestDist = dist
		end

	end

	if bestDog == nil then return nil end
	return bestDog, bestHouse, bestDist

end


-- Convenience: find the dog house near the local player (within DOG_HOUSE_INTERACT_RANGE).
function DogHerding:findDogNearLocalPlayer()

	if g_localPlayer == nil or g_localPlayer.rootNode == nil then return nil end
	return self:findDogHouseNearNode(g_localPlayer.rootNode, DOG_HOUSE_INTERACT_RANGE, g_localPlayer.farmId)

end


function DogHerding:consoleCommandDumpDogNearby()

	local dog, house, dist = self:findDogNearLocalPlayer()

	if dog == nil then
		return string.format("No dog house within %sm of local player (farmId=%s)",
			tostring(DOG_HOUSE_INTERACT_RANGE), tostring(g_localPlayer and g_localPlayer.farmId))
	end

	return string.format("Dog '%s' found at doghouse (dist=%.2fm, farmId=%s, isStaying=%s)",
		tostring(dog.name), dist, tostring(house.ownerFarmId), tostring(dog.isStaying))

end


function DogHerding:consoleCommandCallDog()

	if g_localPlayer == nil then return "no local player" end

	local dog = self:findDogNearLocalPlayer()
	if dog == nil then
		return string.format("No dog house within %sm — stand next to your doghouse first", tostring(DOG_HOUSE_INTERACT_RANGE))
	end

	if dog.followEntity == nil then
		return "Dog has no followEntity method (unexpected FS25 version)"
	end

	dog:followEntity(g_localPlayer)
	return string.format("Dog '%s' is now following you.", tostring(dog.name))

end


-- Dump what animals currently see as their influencer list, plus distances
-- and arousal. Run while dog herding is "not working" so we can tell exactly
-- what each animal thinks the threats are.
function DogHerding:consoleCommandDumpDogHerdState()

	if g_localPlayer == nil then return "no local player" end
	local farmId = g_localPlayer.farmId
	local animalFarm = g_animalManager.farms[farmId]
	if animalFarm == nil then return "no regular herding active on farm " .. tostring(farmId) end

	local dogFarm = self.farms[farmId]
	Logging.warning("[DogHerding] === State dump ===")
	Logging.warning("[DogHerding]   dogFarm active=%s mode=%s pos=%s target=%s",
		tostring(dogFarm ~= nil and dogFarm.active),
		tostring(dogFarm and dogFarm.mode),
		dogFarm and string.format("%.2f,%.2f", dogFarm.position.x, dogFarm.position.z) or "nil",
		dogFarm and string.format("%.2f,%.2f", dogFarm.targetPosition.x, dogFarm.targetPosition.z) or "nil")

	local inf = self:getInfluencers(farmId)
	Logging.warning("[DogHerding]   getInfluencers returned %d entries", #inf)
	for i, e in ipairs(inf) do
		Logging.warning("[DogHerding]     [%d] x=%.2f z=%.2f isBucket=%s isVehicle=%s",
			i, e[1], e[2], tostring(e[3]), tostring(e[4]))
	end

	local players = g_animalManager:getPlayerPositions(farmId)
	Logging.warning("[DogHerding]   farm.players has %d entries (what animals actually see)", #players)
	for i, e in ipairs(players) do
		Logging.warning("[DogHerding]     [%d] x=%.2f z=%.2f isBucket=%s isVehicle=%s",
			i, e[1], e[2], tostring(e[3]), tostring(e[4]))
	end

	local dogX = dogFarm and dogFarm.position and dogFarm.position.x
	local dogZ = dogFarm and dogFarm.position and dogFarm.position.z
	Logging.warning("[DogHerding]   %d animals on farm", #animalFarm.animals)
	for i = 1, math.min(#animalFarm.animals, 5) do
		local a = animalFarm.animals[i]
		local distToDog = "n/a"
		if dogX ~= nil then
			distToDog = string.format("%.2f", MathUtil.vector2Length(a.position.x - dogX, a.position.z - dogZ))
		end
		local cc = a.collisionController
		local hasFront = cc and cc.hasFrontCollision
		local hasLeft  = cc and cc.hasLeftCollision
		local hasRight = cc and cc.hasRightCollision
		Logging.warning("[DogHerding]     animal[%d] pos=%.2f,%.2f dist=%sm rotY=%.2f arousal=%.2f isIdle=%s isWalk=%s isRun=%s isTurning=%s front=%s left=%s right=%s stuck=%s",
			i, a.position.x, a.position.z, distToDog, (a.rotation and a.rotation.y or 0),
			a.arousal or 0,
			tostring(a.state.isIdle), tostring(a.state.isWalking), tostring(a.state.isRunning), tostring(a.state.isTurning),
			tostring(hasFront), tostring(hasLeft), tostring(hasRight),
			tostring(a.stuckTimer or 0))
	end

	Logging.warning("[DogHerding] === End state dump ===")
	return "Dog herd state dumped to log."

end


function DogHerding:consoleCommandSendDogHome()

	if g_localPlayer == nil then return "no local player" end

	-- Search all of the player's doghouses, not just nearby ones, because the dog may
	-- already be away from home when we want to recall it.
	for _, dh in pairs(g_currentMission.doghouses or {}) do
		if dh.ownerFarmId == g_localPlayer.farmId then
			local ok, dog = pcall(dh.getDog, dh)
			if ok and dog ~= nil and dog.dogInstance ~= nil and dog.goToSpawn ~= nil then
				dog:goToSpawn()
				return string.format("Dog '%s' sent back to doghouse.", tostring(dog.name))
			end
		end
	end

	return "No owned dog found."

end


function DogHerding:consoleCommandDumpDogInfo()

	local log = Logging.warning
	log("[DogHerding] === Dog Debug ===")

	for _, dh in pairs(g_currentMission.doghouses or {}) do

		log("[DogHerding]   doghouse ownerFarmId=%s", tostring(dh.ownerFarmId))

		local ok, dog = pcall(dh.getDog, dh)
		if ok and dog ~= nil then
			log("[DogHerding]   dog.name=%s dogInstance=%s animalId=%s isStaying=%s",
				tostring(dog.name), tostring(dog.dogInstance), tostring(dog.animalId), tostring(dog.isStaying))

			if dog.dogInstance ~= nil then
				local ok2, nodes = pcall(getCompanionNodes, dog.dogInstance, dog.animalId or 0)
				if ok2 and nodes ~= nil then
					log("[DogHerding]   getCompanionNodes returned: %s (%s)", tostring(nodes), type(nodes))
					if type(nodes) == "table" then
						for k, v in pairs(nodes) do
							log("[DogHerding]     node[%s] = %s", tostring(k), tostring(v))
							local ok3, x, y, z = pcall(getWorldTranslation, v)
							if ok3 then log("[DogHerding]       position: %.2f, %.2f, %.2f", x, y, z) end
						end
					elseif type(nodes) == "number" then
						local ok3, x, y, z = pcall(getWorldTranslation, nodes)
						if ok3 then log("[DogHerding]     position: %.2f, %.2f, %.2f", x, y, z) end
					end
				else
					log("[DogHerding]   getCompanionNodes failed: %s", tostring(nodes))
				end
			end
		else
			log("[DogHerding]   getDog() returned nil or error: %s", tostring(dog))
		end

	end

	-- Dog herding state
	for farmId, farm in pairs(self.farms) do
		log("[DogHerding]   farm[%d] active=%s mode=%s pos=%.2f,%.2f target=%.2f,%.2f hasDog=%s",
			farmId, tostring(farm.active), tostring(farm.mode),
			farm.position.x, farm.position.z,
			farm.targetPosition.x, farm.targetPosition.z,
			tostring(farm.dog ~= nil))
	end

	log("[DogHerding] === End Dog Debug ===")

	return "Dog info dumped to log."

end


function DogHerding:findDogForFarm(farmId)

	for _, dh in pairs(g_currentMission.doghouses or {}) do

		if dh.ownerFarmId ~= farmId then continue end

		local ok, dog = pcall(dh.getDog, dh)

		if ok and dog ~= nil and dog.dogInstance ~= nil then
			return dog
		end

	end

	return nil

end


function DogHerding:update(dT)

	self:updateDogPrompt()

	-- Refresh the dog input event whenever the local player enters or leaves
	-- a vehicle. Context churn can otherwise leave setActionEventActive
	-- silently no-oping so the "Send Dog" prompt never reappears after an
	-- exit. This is a lightweight remove + re-register.
	--
	-- Also: if the player gets into a vehicle while a dog is following,
	-- send the dog home — we don't want it trying to keep up with a
	-- tractor on foot. Only triggers on the foot → vehicle transition.
	if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
		local currentVehicle = g_localPlayer:getCurrentVehicle()
		if currentVehicle ~= self._lastControlledVehicle then
			local enteringVehicle = currentVehicle ~= nil and self._lastControlledVehicle == nil
			if enteringVehicle and not self:isActive(g_localPlayer.farmId) then
				local following = self:findDogFollowingLocalPlayer()
				if following ~= nil and following.goToSpawn ~= nil then
					following:goToSpawn()
				end
			end
			self:refreshDogFootEvent()
			self._lastControlledVehicle = currentVehicle
		end
	end

	-- Keep farm state in sync: if the player stopped herding via their own key,
	-- clear the dog-herding flag so the prompt resets properly.
	-- Only clear AFTER we've observed regular herding as active at least once —
	-- HerdingRequestEvent dispatches through a queue, so there's a one-tick gap
	-- between setting the dog flag and regular herding actually starting.
	for farmId, farm in pairs(self.farms) do
		if not farm.active then continue end

		if g_animalManager.farms[farmId] ~= nil then
			farm.sawRegular = true
		elseif farm.sawRegular then
			self.farms[farmId] = nil
			continue
		end

		-- Only run orbit-and-push for dog-started herding (not any herd that might be
		-- running from the regular LSHIFT+N flow).
		if farm.startedWithDog and self.isServer and g_animalManager.farms[farmId] ~= nil then
			self:updateModeAndTarget(farmId, dT)
			self:moveDogTowardTarget(farmId, dT)
		end
	end

end


-- Refresh the Call Dog / Send Dog Home prompt based on proximity to the doghouse
-- and whether the dog is currently following the local player.
function DogHerding:updateDogPrompt()

	if self.dogEventId == nil then return end
	if g_localPlayer == nil then
		g_inputBinding:setActionEventActive(self.dogEventId, false)
		g_inputBinding:setActionEventTextVisibility(self.dogEventId, false)
		return
	end

	self.dogPromptTicks = (self.dogPromptTicks or 0) + 1
	if self.dogPromptTicks < 15 then return end
	self.dogPromptTicks = 0

	local text, show
	local farmId = g_localPlayer.farmId
	local herdingActive = self:isActive(farmId)
	local regularHerdingActive = g_animalManager.farms[farmId] ~= nil and not herdingActive
	local following = self:findDogFollowingLocalPlayer()

	if regularHerdingActive then
		-- Mutual exclusion: player is in regular herding mode → hide all dog options.
		g_inputBinding:setActionEventActive(self.dogEventId, false)
		g_inputBinding:setActionEventTextVisibility(self.dogEventId, false)
		return
	end

	if herdingActive then
		-- Dog herding is running — offer to stop it.
		show = true
		text = g_i18n:getText("ahl_stopDogHerding", modName)
	elseif following ~= nil then
		-- Dog is following. If both dog and player stand inside a cow/sheep
		-- husbandry delivery area, offer to start dog herding instead of recall.
		local husb = self:findValidDogHerdingHusbandry(following)
		if husb ~= nil then
			show = true
			text = g_i18n:getText("ahl_startDogHerding", modName)
		else
			show = true
			text = g_i18n:getText("ahl_recallDog", modName)
		end
	else
		-- Not following. Only offer "Call Dog" if we're near our dog house with a dog.
		local nearDog = self:findDogNearLocalPlayer()
		if nearDog ~= nil then
			show = true
			text = g_i18n:getText("ahl_sendDog", modName)
		else
			show = false
		end
	end

	g_inputBinding:setActionEventActive(self.dogEventId, show)
	g_inputBinding:setActionEventTextVisibility(self.dogEventId, show)
	if show then g_inputBinding:setActionEventText(self.dogEventId, text) end

end


-- Return the dog's current world (x, z) position, or nil if unavailable.
function DogHerding:getDogPosition(dog)

	if dog == nil or dog.dogInstance == nil then return nil end

	local ok, nodes = pcall(getCompanionNodes, dog.dogInstance, dog.animalId or 0)
	if not ok or nodes == nil then return nil end

	local node
	if type(nodes) == "table" then
		for _, v in pairs(nodes) do node = v; break end
	elseif type(nodes) == "number" then
		node = nodes
	end

	if node == nil or node == 0 then return nil end

	local x, _, z = getWorldTranslation(node)
	return x, z

end


-- Return a cow/sheep husbandry owned by the local player's farm where BOTH the
-- player and the given dog are standing in the delivery-area polygon. Otherwise nil.
function DogHerding:findValidDogHerdingHusbandry(dog)

	if dog == nil then return nil end
	if g_localPlayer == nil or g_localPlayer.rootNode == nil then return nil end
	if g_currentMission == nil or g_currentMission.husbandrySystem == nil then return nil end

	local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
	local dx, dz = self:getDogPosition(dog)
	if dx == nil then return nil end

	for _, husbandry in pairs(g_currentMission.husbandrySystem.placeables) do

		if husbandry:getOwnerFarmId() ~= g_localPlayer.farmId then continue end

		local typeIdx = husbandry:getAnimalTypeIndex()
		if typeIdx ~= AnimalType.COW and typeIdx ~= AnimalType.SHEEP then continue end

		if husbandry:getIsInAnimalDeliveryArea(px, pz) and husbandry:getIsInAnimalDeliveryArea(dx, dz) then
			return husbandry
		end

	end

	return nil

end


-- Return the dog owned by the local player's farm that is currently following
-- the local player, or nil.
function DogHerding:findDogFollowingLocalPlayer()

	if g_localPlayer == nil or g_localPlayer.rootNode == nil then return nil end
	if g_currentMission == nil or g_currentMission.doghouses == nil then return nil end

	for _, dh in pairs(g_currentMission.doghouses) do

		if dh.ownerFarmId ~= g_localPlayer.farmId then continue end

		local ok, dog = pcall(dh.getDog, dh)
		if ok and dog ~= nil and dog.dogInstance ~= nil and dog.entityFollow == g_localPlayer.rootNode then
			return dog
		end

	end

	return nil

end


function DogHerding:activate(farmId)

	if self.farms[farmId] ~= nil and self.farms[farmId].active then return end

	local animalFarm = g_animalManager.farms[farmId]
	if animalFarm == nil then return end

	local animals = animalFarm.animals
	if animals == nil or #animals == 0 then return end

	-- Find the real dog for this farm
	local dog = self:findDogForFarm(farmId)

	-- Start the dog at the first animal's position as a reasonable initial spot
	local startX, startZ = animals[1].position.x, animals[1].position.z

	self.farms[farmId] = {
		active = true,
		dog = dog,
		mode = "GATHER",
		position = { x = startX, z = startZ },
		targetPosition = { x = startX, z = startZ },
		ticksSinceLastMoveCommand = 0
	}

	-- Tell the real dog to go to the starting position
	if dog ~= nil then
		local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, startX, 0, startZ)
		setCompanionBehaviorMoveTo(dog.dogInstance, dog.animalId, startX, y, startZ)
	end

	self:setDogInputData()

end


function DogHerding:deactivate(farmId)

	local farm = self.farms[farmId]
	if farm == nil then return end

	-- Restore the real dog to default behavior (follow player)
	if farm.dog ~= nil and farm.dog.dogInstance ~= nil then
		setCompanionBehaviorDefault(farm.dog.dogInstance, farm.dog.animalId)
	end

	self.farms[farmId] = nil

	self:setDogInputData()

end


function DogHerding:isActive(farmId)

	return self.farms[farmId] ~= nil and self.farms[farmId].active

end


-- True if the local player's farm is currently running in dog-herding mode.
function DogHerding:isLocalActive()

	if g_localPlayer == nil then return false end
	return self:isActive(g_localPlayer.farmId)

end


function DogHerding:hasAnyActive()

	for _, farm in pairs(self.farms) do
		if farm.active then return true end
	end

	return false

end


-- Autonomous sheepdog FSM. The dog picks its own mode each tick based on the
-- herd's position/spread relative to the handler; the player only starts
-- herding, the dog reads the situation from there.
--
-- Two-mode FSM: GATHER (target the furthest outlier, push it back to the
-- centroid) and DRIVE (balance point opposite the handler, push the whole
-- herd toward the player). Hysteresis on the spread threshold prevents
-- mode flapping. Pressure is applied through the normal vehicle-class
-- influencer pipeline — no per-animal synthetic pulls.
function DogHerding:updateModeAndTarget(farmId, dT)

	local farm = self.farms[farmId]
	local animalFarm = g_animalManager.farms[farmId]

	if animalFarm == nil or animalFarm.animals == nil or #animalFarm.animals == 0 then return end

	-- Locate the handler (same-farm player on foot).
	local px, pz
	for _, p in pairs(g_currentMission.playerSystem.players) do
		if p.farmId == farmId and p.rootNode ~= nil and p.rootNode ~= 0 then
			px, _, pz = getWorldTranslation(p.rootNode)
			break
		end
	end
	if px == nil then return end

	-- Herd centroid (raw), max spread, and furthest outlier.
	local cx, cz, n = 0, 0, 0
	for _, a in ipairs(animalFarm.animals) do
		cx = cx + a.position.x
		cz = cz + a.position.z
		n = n + 1
	end
	cx, cz = cx / n, cz / n

	local outlier, maxSpread = nil, 0
	for _, a in ipairs(animalFarm.animals) do
		local d = MathUtil.vector2Length(a.position.x - cx, a.position.z - cz)
		if d > maxSpread then
			maxSpread = d
			outlier = a
		end
	end

	-- Sample species tuning from first animal for the DRIVE balance distance.
	local cfg = animalFarm.animals[1].speciesCfg or AnimalSpeciesConfig.DEFAULT
	local walkDist = cfg.walkDistance

	-- Mode transition (hysteresis).
	local mode = farm.mode or "GATHER"
	if mode == "DRIVE" and maxSpread > GATHER_THRESHOLD then
		mode = "GATHER"
	elseif mode == "GATHER" and maxSpread <= DRIVE_THRESHOLD then
		mode = "DRIVE"
	end
	farm.mode = mode

	-- Compute target position for the dog based on the current mode.
	local tx, tz
	if mode == "GATHER" and outlier ~= nil then
		-- Park 1.5m past the outlier on its far side from the centroid so
		-- the outlier's flee direction points back toward the herd.
		local dx = outlier.position.x - cx
		local dz = outlier.position.z - cz
		local l = math.sqrt(dx * dx + dz * dz)
		if l < 0.1 then
			-- Outlier IS the centroid (degenerate single-animal herd); fall
			-- through to DRIVE so we at least try to push toward the player.
			mode = "DRIVE"
			farm.mode = mode
		else
			tx = outlier.position.x + (dx / l) * OUTLIER_APPROACH_DIST
			tz = outlier.position.z + (dz / l) * OUTLIER_APPROACH_DIST
		end
	end
	if mode == "DRIVE" then
		-- Balance point: on the far side of the herd from the handler.
		local fromDx, fromDz = cx - px, cz - pz
		local fromLen = math.sqrt(fromDx * fromDx + fromDz * fromDz)
		if fromLen < 0.1 then
			tx, tz = farm.position.x, farm.position.z   -- handler on top of herd; hold
		else
			local driveDistance = walkDist * DRIVE_BALANCE_FRACTION
			tx = cx + (fromDx / fromLen) * driveDistance
			tz = cz + (fromDz / fromLen) * driveDistance
		end
	end

	if tx == nil then return end
	farm.targetPosition.x = tx
	farm.targetPosition.z = tz

	-- Orbit node visual rotation: always face the herd centroid.
	farm.faceX, farm.faceZ = cx, cz

end


function DogHerding:moveDogTowardTarget(farmId, dT)

	local farm = self.farms[farmId]
	local pos = farm.position
	local target = farm.targetPosition

	local dx = target.x - pos.x
	local dz = target.z - pos.z
	local dist = math.sqrt(dx * dx + dz * dz)

	-- Smooth-lerp the virtual influence point position (this is what animals react to)
	if dist >= 0.1 then
		local step = math.min(DOG_APPROACH_SPEED * dT * 0.001, dist)
		local nx, nz = dx / dist, dz / dist
		pos.x = pos.x + nx * step
		pos.z = pos.z + nz * step
	end

	-- Drive the real dog by moving the orbit node it is told to walk to.
	-- FS25's companion API is node-based (no setCompanionBehaviorMoveTo exists)
	-- and FollowEntity appears to only track entities with their own movement
	-- system (player/vehicle); teleporting a plain transform group does not
	-- trigger the dog to re-check position. So we own an orbit node, teleport
	-- it to the target each tick, and re-issue GotoEntity every few ticks so
	-- the dog keeps walking to the current target instead of latching onto a
	-- stale one.
	if farm.orbitNode == nil or farm.orbitNode == 0 then return end

	local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, target.x, 0, target.z)
	setWorldTranslation(farm.orbitNode, target.x, y, target.z)

	-- Face the orbit node toward the current focus — the herd centroid.
	-- faceX/faceZ is set by updateModeAndTarget.
	if farm.faceX ~= nil then
		local dirX, dirZ = farm.faceX - target.x, farm.faceZ - target.z
		if dirX * dirX + dirZ * dirZ > 0.01 then
			setWorldRotation(farm.orbitNode, 0, math.atan2(dirX, dirZ), 0)
		end
	end

	farm.ticksSinceLastMoveCommand = (farm.ticksSinceLastMoveCommand or 0) + 1
	if farm.dog ~= nil and farm.dog.dogInstance ~= nil and farm.ticksSinceLastMoveCommand >= DOG_MOVE_COMMAND_INTERVAL then
		farm.ticksSinceLastMoveCommand = 0
		setCompanionBehaviorGotoEntity(farm.dog.dogInstance, farm.dog.animalId, farm.orbitNode)
	end

end


-- Returns the list of influencers the dog projects onto the farm for this
-- tick. Format matches AnimalManager.playerPositions entries:
--   { x, z, isBucket, isVehicle }
--
-- While the session is active the dog is always a vehicle-class influencer
-- at its current virtual position (cfg.vehicleArousalMult and
-- cfg.vehicleRadiusMult apply, so the herd notices it from far away and
-- reacts like it would to a predator). No eye-tip ghost — a previous
-- iteration tried that and the ghost kept overshooting past the herd,
-- pushing animals AWAY from the handler instead of toward them.
function DogHerding:getInfluencers(farmId)

	local farm = self.farms[farmId]
	if farm == nil or not farm.active then return {} end

	return { { farm.position.x, farm.position.z, false, true } }

end


function DogHerding:setDogInputData()

	if g_localPlayer == nil or self.dogEventId == nil then return end

	-- updateDogPrompt() is the sole authority on the dog event's active state
	-- and text — it runs every 15 ticks from DogHerding:update and covers all
	-- four situations (at doghouse / following / herding active / regular
	-- herding mutex). The previous implementation deactivated the event here
	-- whenever regular herding wasn't running, which hid the "Send Dog" prompt
	-- while the player was near the doghouse. Force a refresh instead.
	self.dogPromptTicks = 15

end


-- Remove + re-register the dog input event. Mirrors AnimalManager's
-- refreshHerdingFootEvent: same pattern works around the FS25 issue where
-- setActionEventActive silently no-ops after certain context churn (vehicle
-- enter/exit, teleport, pause menu). Call this whenever the prompt looks
-- like it's stuck.
function DogHerding:refreshDogFootEvent()

	if g_inputBinding == nil then return end
	if PlayerInputComponent == nil or InputAction == nil or InputAction.HerdingLiteDog == nil then return end

	local oldId = self.dogEventId

	g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

	if oldId ~= nil and oldId ~= "" then
		g_inputBinding:removeActionEvent(oldId)
	end

	local _, newEventId = g_inputBinding:registerActionEvent(
		InputAction.HerdingLiteDog, DogHerding, DogHerding.onToggleDogHerding,
		false, true, false, true, nil, false
	)

	g_inputBinding:endActionEventsModification()

	if newEventId == nil or newEventId == "" then return end

	self.dogEventId = newEventId
	g_inputBinding:setActionEventTextPriority(newEventId, GS_PRIO_VERY_HIGH)
	g_inputBinding:setActionEventText(newEventId, g_i18n:getText("ahl_sendDog", modName))
	-- Start hidden; updateDogPrompt on the next tick will enable it if warranted.
	g_inputBinding:setActionEventActive(newEventId, false)
	g_inputBinding:setActionEventTextVisibility(newEventId, false)

	-- Force updateDogPrompt to run on the next update tick.
	self.dogPromptTicks = 15

end


-- Stop dog herding for the local farm: clear the dog flag, send the stop event to
-- the server (which returns animals to their husbandry), and refresh input data.
-- Safe to call even if dog herding is not active.
function DogHerding:stopLocal()

	if g_localPlayer == nil then return end
	local farmId = g_localPlayer.farmId
	if not self:isActive(farmId) then return end

	local farm = self.farms[farmId]
	self.farms[farmId] = nil

	if g_animalManager.farms[farmId] ~= nil and g_client ~= nil then
		local conn = g_client:getServerConnection()
		if conn ~= nil then
			conn:sendEvent(HerdingRequestEvent.new(false, nil, farmId))
		end
	end

	-- Restore the real dog to follow-player behavior so it's not stuck at its last
	-- herding target (the moveDogTowardTarget updates stopped when we cleared farms).
	if farm ~= nil and farm.dog ~= nil and farm.dog.followEntity ~= nil then
		farm.dog:followEntity(g_localPlayer)
	end

	-- Clean up the orbit transform node we created for setCompanionBehaviorGotoEntity.
	if farm ~= nil and farm.orbitNode ~= nil and farm.orbitNode ~= 0 then
		delete(farm.orbitNode)
	end

	self:setDogInputData()

end


function DogHerding.onToggleDogHerding()

	if g_localPlayer == nil then return end

	local farmId = g_localPlayer.farmId

	-- State 1: dog herding already running → stop it (also stops player herding).
	if g_dogHerding:isActive(farmId) then
		g_dogHerding:stopLocal()
		return
	end

	-- State 2: dog is following + both in valid cow/sheep husbandry → start dog herding.
	local following = g_dogHerding:findDogFollowingLocalPlayer()
	if following ~= nil then

		local husb = g_dogHerding:findValidDogHerdingHusbandry(following)
		if husb ~= nil then
			-- Set the dog-herding flag FIRST so that when the HerdingRequestEvent
			-- dispatches and HerdingEvent.run() calls setHerdingInputData on this
			-- client, the mutex check sees dog herding as active and hides LSHIFT+N.
			local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)

			-- Seed the dog's virtual influence position at the husbandry centre.
			-- The first tick of updateModeAndTarget will recompute the real
			-- target (outlier for GATHER, balance point for DRIVE) and the
			-- virtual dog will lerp there at DOG_APPROACH_SPEED.
			local hx, _, hz = getWorldTranslation(husb.rootNode)
			local startX, startZ = hx, hz

			-- Own a transform node that we teleport around each tick. The dog is then
			-- told to walk to this node (setCompanionBehaviorGotoEntity), giving us
			-- effective "move the dog to (x,y,z)" control even though FS25 only
			-- exposes node-based companion behaviors.
			local orbitNode = createTransformGroup("ahl_dog_orbit")
			link(getRootNode(), orbitNode)
			local startY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, startX, 0, startZ)
			setWorldTranslation(orbitNode, startX, startY, startZ)

			g_dogHerding.farms[farmId] = {
				active = true,
				dog = following,
				startedWithDog = true,
				mode = "GATHER",
				position = { x = startX, z = startZ },
				targetPosition = { x = startX, z = startZ },
				ticksSinceLastMoveCommand = 0,
				orbitNode = orbitNode
			}

			-- Kick off the first GotoEntity; moveDogTowardTarget re-issues it every
			-- DOG_MOVE_COMMAND_INTERVAL ticks so the dog keeps chasing the live orbit
			-- node position. FollowEntity was tried but doesn't track teleported
			-- transform groups (it seems to require entities with their own movement).
			if following.dogInstance ~= nil then
				setCompanionBehaviorGotoEntity(following.dogInstance, following.animalId, orbitNode)
			end

			g_client:getServerConnection():sendEvent(HerdingRequestEvent.new(true, husb))

			-- Explicitly hide the regular herding prompt NOW. We do a remove +
			-- re-register just like the refreshHerdingFootEvent path, because
			-- setActionEventActive alone has been observed to silently no-op
			-- when the event's internal state was churned by a recent context
			-- event (same symptom as the tab+teleport bug).
			if g_animalManager.refreshHerdingFootEvent ~= nil then
				g_animalManager:refreshHerdingFootEvent()
			end
			if g_animalManager.herdingEventId ~= nil and g_animalManager.herdingEventId ~= "" then
				g_inputBinding:setActionEventActive(g_animalManager.herdingEventId, false)
				g_inputBinding:setActionEventTextVisibility(g_animalManager.herdingEventId, false)
			end

			g_dogHerding:setDogInputData()
			g_animalManager.ticksSinceLastInputForce = 99
			return
		end

		-- State 3: following but not in valid husbandry → send home.
		if following.goToSpawn ~= nil then following:goToSpawn() end
		return
	end

	-- State 4: not following → try to call a dog that is near its doghouse.
	local dog = g_dogHerding:findDogNearLocalPlayer()
	if dog == nil then
		g_currentMission:showBlinkingWarning(g_i18n:getText("ahl_noDog", modName), 2500)
		return
	end

	if dog.followEntity ~= nil then dog:followEntity(g_localPlayer) end
	g_dogHerding:playWhistle()

end


function DogHerding:playWhistle()

	-- Lazy-load the whistle sample. If loadSample fails (bad OGG encoding,
	-- missing file, etc.) mark it as failed so we don't retry every call.
	if self.whistleSample == nil and self.whistleLoadFailed ~= true then
		local handle = createSample("ahl_whistle")
		if handle == nil or handle == 0 then
			self.whistleLoadFailed = true
			return
		end
		local ok = pcall(loadSample, handle, modDirectory .. "Sounds/whistel.ogg", false)
		if not ok then
			self.whistleLoadFailed = true
			return
		end
		self.whistleSample = handle
	end

	if self.whistleSample == nil then return end

	-- loops=1 (one-shot), volume=1.0, pitch=0 (natural), delay=0, afterSample=0
	playSample(self.whistleSample, 1, 1.0, 0, 0, 0)

end
