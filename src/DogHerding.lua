DogHerding = {}


local DogHerding_mt = Class(DogHerding)
local modName = g_currentModName
local modDirectory = g_currentModDirectory


local DOG_APPROACH_SPEED = 4.0        -- fallback virtual lerp speed when the real dog position isn't queryable
local DOG_MOVE_COMMAND_INTERVAL = 1   -- Re-issue GotoEntity every N ticks (~16ms @ 60Hz). Every-tick = tightest orbit tracking.
local DOG_HOUSE_INTERACT_RANGE = 8
local DOG_COMMAND_MOVE_THRESHOLD = 0.8 -- metres: if the orbit moved more than this since the last GotoEntity issue, re-issue immediately instead of waiting for the interval
local CAST_CLEAR_FRACTION = 0.6       -- dog is "on the far side" once its projection along outward passes this fraction of centroid→target distance
local CAST_EDGE_INSET = 0.5           -- how far inside the pen fence the cast waypoint sits
local ORBIT_PROJECTION_FAR  = 10.0    -- APPROACH orbit while dog is still TRAVELLING toward target. Keeps goto target outside the dog's walk/run hysteresis so it picks the run gait.
local ORBIT_PROJECTION_NEAR = 3.0     -- APPROACH orbit once the dog is inside APPROACH_ARRIVAL_ZONE. Matches the dog's engine-side arrival threshold (~3 m per labradorRetriever.xml followRange min=3) so the dog rests AT the target, not past it.
local APPROACH_ARRIVAL_ZONE = 5.0     -- dog-to-target distance at which orbit switches from FAR to NEAR projection
local DOG_THREAT_SCALE = 0.8          -- dog's arousal contribution multiplier (1.0 = full vehicle threat, 0.5 = half)
local HOLD_ENTER_DISTANCE = 4.0       -- centroid within this distance of player → dog stops pushing (HOLD mode)
local HOLD_EXIT_DISTANCE = 6.0        -- centroid past this distance of player → HOLD releases (hysteresis prevents flapping)

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
local GATHER_EDGE_INSET      = 1.5    -- how far inside the husbandry perimeter the dog parks in GATHER (unused fallback)
local EDGE_SEARCH_START      = 60     -- starting outward cap for the perimeter binary search (metres)
local FAR_OUTLIER_APPROACH   = 0.8    -- how far past the far-side outlier the dog parks in GATHER
local OUTLIER_FENCE_MARGIN   = 0.3    -- minimum distance between target and pen fence (metres)
local OUTLIER_MIN_CLEARANCE  = 0.35   -- minimum room past outlier needed for GATHER; below this, fall through to DRIVE





function DogHerding.new()

	local self = setmetatable({}, DogHerding_mt)

	self.farms = {}
	self.isServer = g_currentMission:getIsServer()
	self.isClient = g_currentMission:getIsClient()

	-- Lazy-loaded 2D whistle sample played locally when calling the dog.
	self.whistleSample = nil

	self.debugDraw = false

	-- Passenger mode state — keyed by dog.dogInstance (the engine companion
	-- handle). Per-dog so that a client can track multiple farms' dogs
	-- in MP. Entry:
	--   { dog, vehicle, seatNode, meshInstance, offset }
	-- meshInstance is what DogPassengerMesh.acquire returned; its .root
	-- is linked under seatNode.
	self.passengers = {}

	-- Deferred shared-i3d releases. Calling releaseSharedI3DFile on the
	-- request id during the vehicle-exit path crashed the game (presumably
	-- because the node handle it's about to drop is still referenced by
	-- some engine structure that tick). We queue the release here and
	-- process entries once the grace delay has elapsed. Each entry:
	--   { requestId = <int>, releaseAtMs = <game-time-ms> }
	self.pendingI3dReleases = {}

	addConsoleCommand("dumpDogInfo", "Dump FS25 dog/companion info to log", "consoleCommandDumpDogInfo", self)
	addConsoleCommand("dumpDogNearby", "Check whether the local player is near their dog house with a dog", "consoleCommandDumpDogNearby", self)
	addConsoleCommand("dumpDogHerdState", "Dump what animals see as influencers during dog herding", "consoleCommandDumpDogHerdState", self)
	addConsoleCommand("callDog", "If near your dog house, command the dog to follow you", "consoleCommandCallDog", self)
	addConsoleCommand("sendDogHome", "Send your dog back to its doghouse", "consoleCommandSendDogHome", self)
	addConsoleCommand("toggleDogHerdingDebug", "Toggle visual debug overlay for dog herding (centroid, dog target, animals)", "consoleCommandToggleDogHerdingDebug", self)

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
	self:processPendingI3dReleases()

	-- Refresh the dog input event whenever the local player enters or leaves
	-- a vehicle. Context churn can otherwise leave setActionEventActive
	-- silently no-oping so the "Send Dog" prompt never reappears after an
	-- exit. This is a lightweight remove + re-register.
	--
	-- Foot → vehicle: if the dog is following AND the vehicle has a
	-- `passengerSeat##PlayerSkin` node, install the passenger visual
	-- (cloned animated dog mesh on the seat, live companion hidden).
	-- Otherwise fall back to `goToSpawn()` — dog runs home instead of
	-- chasing a vehicle it can't keep up with.
	--
	-- Vehicle → foot: if we were in passenger mode, tear it down and
	-- resume following.
	--
	-- Tab between vehicles: treat as exit-then-enter to retarget the
	-- new vehicle's seat.
	if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
		local currentVehicle = g_localPlayer:getCurrentVehicle()
		if currentVehicle ~= self._lastControlledVehicle then

			local enteringVehicle = currentVehicle ~= nil and self._lastControlledVehicle == nil
			local exitingVehicle  = currentVehicle == nil and self._lastControlledVehicle ~= nil
			local swappingVehicle = currentVehicle ~= nil and self._lastControlledVehicle ~= nil

			-- Tear down any existing passenger state first (exit or swap).
			if (exitingVehicle or swappingVehicle) and self._passengerDog ~= nil then
				self:exitPassengerMode(self._passengerDog)
				self._passengerDog = nil
			end

			-- Try to enter passenger mode on a new vehicle (enter or swap).
			if (enteringVehicle or swappingVehicle) and not self:isActive(g_localPlayer.farmId) then
				local following = self:findDogFollowingLocalPlayer()
				if following ~= nil then
					if self:enterPassengerMode(following, currentVehicle) then
						self._passengerDog = following
					elseif following.goToSpawn ~= nil then
						following:goToSpawn()
					end
				end
			end

			self:refreshDogFootEvent()
			self._lastControlledVehicle = currentVehicle

		end
	end

	-- Safety: if the vehicle carrying the passenger dog gets deleted
	-- mid-ride, clean up so the cloned mesh doesn't end up orphaned and
	-- the live dog comes back.
	if self._passengerDog ~= nil then
		local state = self.passengers[self._passengerDog.dogInstance]
		local stillValid = state ~= nil and state.vehicle ~= nil
			and state.vehicle.rootNode ~= nil and state.vehicle.rootNode ~= 0
		if stillValid then
			local ok, exists = pcall(entityExists, state.vehicle.rootNode)
			if not ok or not exists then stillValid = false end
		end
		if not stillValid then
			self:exitPassengerMode(self._passengerDog)
			self._passengerDog = nil
		end
	end

	-- Keep farm state in sync: if the player stopped herding via their own key,
	-- clear the dog-herding flag so the prompt resets properly.
	-- Only clear AFTER we've observed regular herding as active at least once —
	-- HerdingRequestEvent dispatches through a queue, so there's a one-tick gap
	-- between setting the dog flag and regular herding actually starting.
	-- When regular herding ends (player stopped, all animals loaded into a
	-- trailer, all animals despawned) we go through deactivate() so the real
	-- dog gets setCompanionBehaviorDefault() and the prompt refreshes —
	-- otherwise the dog is left stuck on the (now-dangling) orbit node and
	-- won't follow the player again.
	for farmId, farm in pairs(self.farms) do
		if not farm.active then continue end

		if g_animalManager.farms[farmId] ~= nil then
			farm.sawRegular = true
		elseif farm.sawRegular then
			self:deactivate(farmId)
			continue
		end

		-- Only run orbit-and-push for dog-started herding (not any herd that might be
		-- running from the regular LSHIFT+N flow).
		if farm.startedWithDog and self.isServer and g_animalManager.farms[farmId] ~= nil then
			self:updateModeAndTarget(farmId, dT)
			self:moveDogTowardTarget(farmId, dT)
		end
	end

	if self.debugDraw then
		self:drawDebugOverlay()
	end

end


function DogHerding:consoleCommandToggleDogHerdingDebug()
	self.debugDraw = not self.debugDraw
	return "Dog herding debug overlay: " .. (self.debugDraw and "ON" or "OFF")
end


-- Draw a vertical stake with a ground cross and an optional 3D text label at (x, y, z).
-- Called every frame from update when debugDraw is toggled on.
function DogHerding:drawStake(x, y, z, r, g, b, label)
	drawDebugLine(x, y, z, r, g, b, x, y + 4, z, r, g, b)
	drawDebugLine(x - 1, y, z, r, g, b, x + 1, y, z, r, g, b)
	drawDebugLine(x, y, z - 1, r, g, b, x, y, z + 1, r, g, b)
	if label ~= nil then
		setTextColor(r, g, b, 1)
		setTextAlignment(RenderText.ALIGN_CENTER)
		renderText3D(x, y + 4.3, z, 0, 0, 0, 0.35, label)
		setTextAlignment(RenderText.ALIGN_LEFT)
		setTextColor(1, 1, 1, 1)
	end
end


function DogHerding:drawDebugOverlay()
	if g_localPlayer == nil then return end

	local farmId = g_localPlayer.farmId
	local farm = self.farms[farmId]
	if farm == nil or not farm.active then return end

	local animalFarm = g_animalManager.farms[farmId]
	if animalFarm == nil or animalFarm.animals == nil or #animalFarm.animals == 0 then return end

	local terrain = g_currentMission.terrainRootNode

	-- Live centroid of the herded animals (recomputed here so clients see it too).
	local cx, cz, n = 0, 0, 0
	for _, a in ipairs(animalFarm.animals) do
		cx = cx + a.position.x
		cz = cz + a.position.z
		n = n + 1
	end
	cx, cz = cx / n, cz / n
	local cy = getTerrainHeightAtWorldPos(terrain, cx, 0, cz)

	-- Each animal: vertical stick coloured and scaled by arousal (fear of
	-- the dog). Calm = short green, alert = medium yellow, panicking = tall
	-- red. Makes it easy to see the dog's actual influence radius at a
	-- glance — sticks close to the dog should be tall and red, sticks far
	-- from the dog should be short and green.
	local arousalCfg = animalFarm.animals[1].speciesCfg or AnimalSpeciesConfig.DEFAULT
	local startle = arousalCfg.startleThreshold or 0.6
	for _, a in ipairs(animalFarm.animals) do
		local ax, az = a.position.x, a.position.z
		local ay = getTerrainHeightAtWorldPos(terrain, ax, 0, az)
		local arousal = a.arousal or 0
		if arousal < 0 then arousal = 0 elseif arousal > 1 then arousal = 1 end

		-- Green (0) → yellow (startle threshold) → red (1). Height scales
		-- from 0.4 m (calm) up to 2.5 m (fully panicked).
		local r, g
		if arousal < startle then
			local t = arousal / startle
			r = t
			g = 1
		else
			local t = (arousal - startle) / math.max(0.001, 1 - startle)
			r = 1
			g = 1 - t
		end
		local h = 0.4 + arousal * 2.1

		drawDebugLine(ax, ay, az, r, g, 0, ax, ay + h, az, r, g, 0)

		-- Numeric arousal readout above the stick for precise tuning.
		setTextColor(r, g, 0, 1)
		setTextAlignment(RenderText.ALIGN_CENTER)
		renderText3D(ax, ay + h + 0.15, az, 0, 0, 0, 0.18, string.format("%.2f", arousal))
		setTextAlignment(RenderText.ALIGN_LEFT)
		setTextColor(1, 1, 1, 1)
	end

	-- Centroid — cyan stake.
	self:drawStake(cx, cy, cz, 0, 1, 1, "CENTROID (" .. n .. ")")

	-- Dog virtual target (where the orbit node wants to be) — green.
	if farm.targetPosition ~= nil and farm.targetPosition.x ~= nil then
		local tx, tz = farm.targetPosition.x, farm.targetPosition.z
		local ty = getTerrainHeightAtWorldPos(terrain, tx, 0, tz)
		self:drawStake(tx, ty, tz, 0, 1, 0, "DOG TARGET")
	end

	-- Real dog position (the influence point) — orange stake.
	if farm.position ~= nil and farm.position.x ~= nil then
		local dx, dz = farm.position.x, farm.position.z
		local dy = getTerrainHeightAtWorldPos(terrain, dx, 0, dz)
		local phase = farm.castPhase and "CAST" or "APPROACH"
		self:drawStake(dx, dy, dz, 1, 0.5, 0, "DOG (" .. (farm.mode or "?") .. "/" .. phase .. ")")
	end

	-- Orbit node — white stake (the "carrot" waypoint the companion
	-- pathfinder is told to walk to; should sit just ahead of the dog).
	if farm.orbitNode ~= nil and farm.orbitNode ~= 0 then
		local ox, _, oz = getWorldTranslation(farm.orbitNode)
		local oy = getTerrainHeightAtWorldPos(terrain, ox, 0, oz)
		self:drawStake(ox, oy, oz, 1, 1, 1, "ORBIT")
	end

	-- Player → centroid line — yellow (the "dog parks on the far side of
	-- this axis" axis).
	if g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then
		local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
		drawDebugLine(px, py + 1, pz, 1, 1, 0, cx, cy + 1, cz, 1, 1, 0)
	end

	-- Far-side outlier (the animal the dog is currently targeting in GATHER)
	-- — magenta stake. This is the furthest-from-centroid animal on the far
	-- side of the centroid from the player.
	if farm.farOutlierX ~= nil and farm.farOutlierZ ~= nil then
		local ox, oz = farm.farOutlierX, farm.farOutlierZ
		local oy = getTerrainHeightAtWorldPos(terrain, ox, 0, oz)
		self:drawStake(ox, oy, oz, 1, 0, 1, "OUTLIER")
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


-- Search a scene-graph subtree for the first SHAPE node that carries a
-- given shader parameter. Both getShaderParameter and getHasShaderParameter
-- throw "invalid type in method" errors on non-shape nodes (transform
-- groups, skeleton joints). pcall catches the Lua error but FS25 still
-- prints the stack trace to the log — calling across every dog bone
-- produces 30+ log entries per frame which hangs the game.
--
-- getHasClassId(node, ClassIds.SHAPE) is SAFE on any node type; use it
-- as the gate before touching any shader API.
function DogHerding:_findShaderParameterInSubtree(root, paramName)

	if root == nil or root == 0 then return nil end

	local okCls, isShape = pcall(getHasClassId, root, ClassIds.SHAPE)
	if okCls and isShape then
		local okHas, hasParam = pcall(getHasShaderParameter, root, paramName)
		if okHas and hasParam then
			local ok, x, y, z, w = pcall(getShaderParameter, root, paramName)
			if ok and x ~= nil then return root, x, y, z, w end
		end
	end

	local okN, numChildren = pcall(getNumOfChildren, root)
	if okN and numChildren ~= nil then
		for i = 0, numChildren - 1 do
			local okC, child = pcall(getChildAt, root, i)
			if okC and child ~= nil and child ~= 0 then
				local n, rx, ry, rz, rw = self:_findShaderParameterInSubtree(child, paramName)
				if n ~= nil then return n, rx, ry, rz, rw end
			end
		end
	end

	return nil

end


-- Copy the `atlasInvSizeAndOffsetUV` shader parameter from the live dog's
-- visual node to the cloned mesh so the clone displays the same breed
-- variant. The live dog's node tree is reached via getCompanionNodes;
-- we walk it looking for the first node that exposes the parameter, then
-- propagate to the clone subtree via I3DUtil.setShaderParameterRec.
-- Also resets `dirt` to 0 on the clone (clones default to the loaded
-- i3d's authored value, which may be a grubby variant).
function DogHerding:_copyDogAtlasToClone(dog, cloneRoot)

	if dog == nil or dog.dogInstance == nil then return end
	if cloneRoot == nil or cloneRoot == 0 then return end

	local ok, nodes = pcall(getCompanionNodes, dog.dogInstance, dog.animalId or 0)
	if not ok or nodes == nil then return end

	-- getCompanionNodes returns the dog's skeleton tree (joints / bones).
	-- The mesh node with the atlas shader parameter is a SIBLING under
	-- the i3d root, not a descendant of the skeleton — so we also
	-- search each skeleton's parent to reach the sibling mesh.
	local candidates = {}
	local seen = {}
	local function addCandidate(n)
		if n ~= nil and n ~= 0 and not seen[n] then
			seen[n] = true
			table.insert(candidates, n)
		end
	end

	local raw = {}
	if type(nodes) == "table" then
		for _, n in pairs(nodes) do table.insert(raw, n) end
	elseif type(nodes) == "number" then
		table.insert(raw, nodes)
	end

	for _, n in ipairs(raw) do
		addCandidate(n)
		local okP, parent = pcall(getParent, n)
		if okP then addCandidate(parent) end
	end

	local x, y, z, w
	for _, n in ipairs(candidates) do
		local _, rx, ry, rz, rw = self:_findShaderParameterInSubtree(n, "atlasInvSizeAndOffsetUV")
		if rx ~= nil then
			x, y, z, w = rx, ry, rz, rw
			break
		end
	end

	if x == nil then return end

	pcall(I3DUtil.setShaderParameterRec, cloneRoot, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
	pcall(I3DUtil.setShaderParameterRec, cloneRoot, "dirt", 0, nil, nil, nil)

end


-- Recursively set visibility on `node` and all descendants. Used after
-- linking a cloned dog mesh under a vehicle seat to ensure every node
-- in the subtree is visible regardless of per-node flags stored in the
-- loaded i3d. Also covers the case where a node's visibility doesn't
-- inherit from its parent (some meshes are flagged independently).
function DogHerding:_setSubtreeVisible(node, visible)

	if node == nil or node == 0 then return end
	pcall(setVisibility, node, visible)
	local ok, numChildren = pcall(getNumOfChildren, node)
	if ok and numChildren ~= nil then
		for i = 0, numChildren - 1 do
			local okC, child = pcall(getChildAt, node, i)
			if okC and child ~= nil and child ~= 0 then
				self:_setSubtreeVisible(child, visible)
			end
		end
	end

end


-- Drain the pending shared-i3d release queue. Entries whose grace delay
-- has elapsed get their request id released. We use a pcall wrapper
-- because if the engine has already dropped the shared reference for
-- any other reason, releaseSharedI3DFile can error.
function DogHerding:processPendingI3dReleases()

	local q = self.pendingI3dReleases
	if q == nil or #q == 0 then return end

	local now = g_time or 0
	local i = 1
	while i <= #q do
		local entry = q[i]
		if entry ~= nil and now >= (entry.releaseAtMs or 0) then
			pcall(g_i3DManager.releaseSharedI3DFile, g_i3DManager, entry.requestId)
			table.remove(q, i)
		else
			i = i + 1
		end
	end

end


-- Walk the vehicle's scene graph looking for a child node whose name
-- matches `passengerSeat##PlayerSkin` (## = any digits). Returns the
-- first matching node (and its name for logging) or nil.
function DogHerding:findPassengerSeatNode(vehicle)

	if vehicle == nil or vehicle.rootNode == nil or vehicle.rootNode == 0 then return nil end

	-- Iterative DFS to avoid deep recursion.
	local stack = { vehicle.rootNode }
	while #stack > 0 do
		local node = table.remove(stack)
		local ok, name = pcall(getName, node)
		if ok and type(name) == "string" and name:find("^passengerSeat%d+PlayerSkin$") ~= nil then
			return node, name
		end
		local ok2, numChildren = pcall(getNumOfChildren, node)
		if ok2 and numChildren ~= nil then
			for i = 0, numChildren - 1 do
				local ok3, child = pcall(getChildAt, node, i)
				if ok3 and child ~= nil and child ~= 0 then
					table.insert(stack, child)
				end
			end
		end
	end

	return nil

end


-- Install the passenger visual on the local client. This is the core
-- operation: hide the live companion, clone the animated dog i3d, link
-- it under the vehicle seat node, apply the per-vehicle offset. Same
-- function is used both when the LOCAL player triggers passenger mode
-- and when a remote DogPassengerEvent fires for another player's dog.
function DogHerding:installPassengerVisual(dog, vehicle)

	if dog == nil or dog.dogInstance == nil then return false end
	if vehicle == nil or vehicle.rootNode == nil or vehicle.rootNode == 0 then return false end

	-- Already in passenger mode for this dog?
	-- - Same vehicle: idempotent no-op (a network rebroadcast can bounce
	--   the sender's own event back to them; we don't want to flicker
	--   the mesh by tearing down and rebuilding).
	-- - Different vehicle: tear down first (tabbed to a new vehicle).
	local existing = self.passengers[dog.dogInstance]
	if existing ~= nil then
		if existing.vehicle == vehicle then return true end
		self:removePassengerVisual(dog)
	end

	local seatNode, seatName = self:findPassengerSeatNode(vehicle)
	if seatNode == nil then return false end

	local mesh = DogPassengerMesh.acquire(dog)
	if mesh == nil or mesh.root == nil or mesh.root == 0 then
		Logging.warning("[DogHerding] passenger: mesh acquire failed — falling back to goToSpawn")
		return false
	end

	local offset = DogPassengerOffsets.get(vehicle)

	-- Re-link under the seat node, apply offset, reset rotation to the
	-- seat's local forward (caller can rotate later if the seat forward
	-- isn't what the vehicle models expect).
	link(seatNode, mesh.root)
	setTranslation(mesh.root, offset.x or 0, offset.y or 0, offset.z or 0)
	setRotation(mesh.root, 0, 0, 0)

	-- passengerSeat##PlayerSkin nodes are hidden by default — they only
	-- show when the game assigns a driver character skin to them. Our
	-- mesh linked underneath inherits that hidden state. Force-set
	-- visibility on the seat node AND recursively on every node under
	-- our mesh root (some i3ds have per-node visibility that doesn't
	-- propagate from the parent).
	pcall(setVisibility, seatNode, true)
	self:_setSubtreeVisible(mesh.root, true)

	-- Copy the texture atlas variant from the live dog to the clone so
	-- both show the same breed colour (labrador variants share one i3d
	-- and differentiate via atlas UV offset). Without this the clone
	-- shows the default 0,0 tile regardless of which breed the player
	-- actually owns.
	self:_copyDogAtlasToClone(dog, mesh.root)

	-- Route the live companion far off-map so it's invisible during the
	-- ride without using setCompanionsVisibility (which crashed on exit
	-- when toggled back to true). FS25 maps are typically < 2 km square
	-- so an offset of 10 km from the player puts the dog well outside
	-- any reasonable render / clip distance. The Y coord terrain-snaps
	-- to wherever — doesn't matter, we're too far for it to render.
	-- On exit, setCompanionPosition (step 2) teleports it back to the
	-- player and followEntity resumes the normal AI.
	local px, pz = 0, 0
	if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then
		px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
	end
	pcall(setCompanionPosition, dog.dogInstance, dog.animalId or 0, px + 10000, 0, pz + 10000)
	if dog.goToSpawn ~= nil then
		pcall(dog.goToSpawn, dog)
	end

	self.passengers[dog.dogInstance] = {
		dog = dog,
		vehicle = vehicle,
		seatNode = seatNode,
		seatName = seatName,
		mesh = mesh,
		offset = offset
	}

	return true

end


-- Reverse of installPassengerVisual. Safe to call even if no passenger
-- state exists for the dog.
function DogHerding:removePassengerVisual(dog)

	if dog == nil or dog.dogInstance == nil then return end

	local state = self.passengers[dog.dogInstance]
	if state == nil then return end

	-- Visibility was never toggled (see installPassengerVisual note),
	-- so we don't need to restore it here. Just release the clone.
	-- DogPassengerMesh.release returns the sharedLoadRequestId; we defer
	-- the actual releaseSharedI3DFile call by ~500ms because calling it
	-- synchronously during vehicle-exit crashed the game.
	if state.mesh ~= nil then
		local requestId = DogPassengerMesh.release(state.mesh)
		if requestId ~= nil then
			table.insert(self.pendingI3dReleases, {
				requestId = requestId,
				releaseAtMs = (g_time or 0) + 500
			})
		end
	end

	self.passengers[dog.dogInstance] = nil

end


-- Called by the vehicle-transition block in update() when the LOCAL player
-- just entered a vehicle while their dog was following. Tries the visual
-- swap locally, then emits the MP event so all other clients mirror it.
function DogHerding:enterPassengerMode(dog, vehicle)

	if not self:installPassengerVisual(dog, vehicle) then return false end
	-- Always dispatch; the event is a no-op in singleplayer (no peers).
	DogPassengerEvent.sendToServer(dog, vehicle, true)
	return true

end


-- Called when the LOCAL player exits their vehicle, or the vehicle
-- becomes invalid. Removes visual locally + teleports the live companion
-- to the player, resumes follow, and emits the MP exit event.
function DogHerding:exitPassengerMode(dog)

	if dog == nil or dog.dogInstance == nil then return end

	local state = self.passengers[dog.dogInstance]
	if state == nil then return end

	self:removePassengerVisual(dog)

	-- Teleport the live companion to the player's current position so it
	-- reappears next to them instead of popping back at the spawn.
	if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then
		local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
		local ok, err = pcall(setCompanionPosition, dog.dogInstance, dog.animalId or 0, px, py, pz)
		if not ok then Logging.warning("[DogHerding] setCompanionPosition failed: %s", tostring(err)) end
	end

	-- Resume following the local player.
	if dog.followEntity ~= nil and g_localPlayer ~= nil then
		local ok, err = pcall(dog.followEntity, dog, g_localPlayer)
		if not ok then Logging.warning("[DogHerding] followEntity failed: %s", tostring(err)) end
	end

	-- Tell other clients the passenger mode ended so they tear down
	-- their local clone visual. No-op in singleplayer.
	local okS, errS = pcall(DogPassengerEvent.sendToServer, dog, nil, false)
	if not okS then Logging.warning("[DogHerding] sendToServer failed: %s", tostring(errS)) end

end


-- Called by DogPassengerEvent:run when a remote client's dog has entered
-- passenger mode. Visual swap only — no network echo.
function DogHerding:applyRemotePassengerEnter(dog, vehicle)

	self:installPassengerVisual(dog, vehicle)

end


-- Called by DogPassengerEvent:run when a remote client's dog has exited
-- passenger mode. Visual swap only.
function DogHerding:applyRemotePassengerExit(dog)

	if dog == nil or dog.dogInstance == nil then return end
	if self.passengers[dog.dogInstance] == nil then return end
	self:removePassengerVisual(dog)

end


-- True if the given dog is currently in passenger mode on this client.
function DogHerding:isDogInPassengerMode(dog)

	if dog == nil or dog.dogInstance == nil then return false end
	return self.passengers[dog.dogInstance] ~= nil

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

	-- Restore the real dog to following the local player. Default behavior
	-- alone left the dog stuck on the orbit node it was chasing, so it
	-- wouldn't rejoin the player after auto-teardown (herd loaded into
	-- trailer, etc.). followEntity is the explicit re-follow, default is
	-- the fallback when followEntity isn't available on the dog instance.
	if farm.dog ~= nil then
		if farm.dog.followEntity ~= nil and g_localPlayer ~= nil and farm.dog.ownerFarmId == g_localPlayer.farmId then
			farm.dog:followEntity(g_localPlayer)
		elseif farm.dog.dogInstance ~= nil then
			setCompanionBehaviorDefault(farm.dog.dogInstance, farm.dog.animalId)
		end
	end

	-- Delete the orbit transform group we owned for GotoEntity routing.
	if farm.orbitNode ~= nil and farm.orbitNode ~= 0 then
		delete(farm.orbitNode)
	end

	self.farms[farmId] = nil

	self:setDogInputData()

end


function DogHerding:isActive(farmId)

	return self.farms[farmId] ~= nil and self.farms[farmId].active

end


-- True when dog herding is active AND in HOLD mode for this farm. Used by
-- AnimalManager to skip the per-animal guide influence while HOLD is in
-- effect so arousal decays and animals don't keep creeping toward the
-- centroid after the dog has paused.
function DogHerding:isHolding(farmId)

	local farm = self.farms[farmId]
	return farm ~= nil and farm.active and farm.mode == "HOLD"

end


-- Current FSM mode for this farm, or nil if dog herding isn't active.
-- AnimalManager uses this to pick the synthetic guide target: GATHER →
-- animals guided toward centroid (consolidate); DRIVE → animals guided
-- toward the player (herd rotates to face and walk to the handler).
function DogHerding:getMode(farmId)

	local farm = self.farms[farmId]
	return farm ~= nil and farm.active and farm.mode or nil

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


-- Walk outward from (cx,cz) along unit vector (ux,uz) and return the last
-- point that is still inside the husbandry's animal delivery area (i.e. the
-- perimeter on that side). Works for any pen shape — rectangular, irregular,
-- L-shaped — because it just samples the engine's point-in-area test.
-- Returns (x, z) or nil if the center is already outside or the husbandry is gone.
function DogHerding:findHusbandryEdge(husb, cx, cz, ux, uz)

	if husb == nil or husb.getIsInAnimalDeliveryArea == nil then return nil end
	if not husb:getIsInAnimalDeliveryArea(cx, cz) then return nil end

	-- Expand "outside" bound until we find a point outside the pen, doubling each time.
	local inside, outside = 0, EDGE_SEARCH_START
	local found = false
	for _ = 1, 6 do
		local px, pz = cx + outside * ux, cz + outside * uz
		if not husb:getIsInAnimalDeliveryArea(px, pz) then found = true; break end
		inside = outside
		outside = outside * 2
	end
	if not found then return nil end

	-- Binary search between inside (known inside) and outside (known outside).
	for _ = 1, 10 do
		local mid = (inside + outside) * 0.5
		local px, pz = cx + mid * ux, cz + mid * uz
		if husb:getIsInAnimalDeliveryArea(px, pz) then
			inside = mid
		else
			outside = mid
		end
	end

	return cx + inside * ux, cz + inside * uz

end


-- Autonomous sheepdog FSM. The dog picks its own mode each tick based on the
-- herd's position/spread relative to the handler; the player only starts
-- herding, the dog reads the situation from there.
--
-- Three-mode FSM. HOLD overrides the others: when the herd centroid is
-- within 4 m of the player (exit at 6 m for hysteresis), the dog stops
-- pushing, getInfluencers returns {}, and the per-animal guide pull in
-- AnimalManager is skipped — animals calm down instead of continuing to
-- creep inward. Otherwise: GATHER (spread > 5 m) targets the furthest
-- far-side outlier and parks just past it along the outward-from-centroid
-- direction; DRIVE (spread ≤ 3 m) parks walkDist × 0.35 past the centroid
-- along unit(centroid - player) for a direct push toward the handler.
-- Hysteresis on the spread threshold prevents GATHER↔DRIVE flapping.
-- Pressure is applied through the normal vehicle-class influencer pipeline —
-- no per-animal synthetic pulls.
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

	-- Direction from player toward centroid. The "far side" half-space is
	-- everything with a positive projection onto this direction from centroid.
	local fromDx, fromDz = cx - px, cz - pz
	local fromLen = math.sqrt(fromDx * fromDx + fromDz * fromDz)

	-- Scan animals once for two things:
	--   maxSpread  — furthest-from-centroid (any side), drives mode hysteresis.
	--   farOutlier — furthest-from-centroid among animals on the FAR SIDE of
	--                the centroid from the player. This is what GATHER targets
	--                so the dog is always behind the herd from the player's
	--                perspective; pushing an outlier on the near side would
	--                shove animals away from the player.
	local maxSpread = 0
	local farOutlier, farOutlierDist = nil, 0
	local ux, uz
	if fromLen >= 0.1 then ux, uz = fromDx / fromLen, fromDz / fromLen end

	for _, a in ipairs(animalFarm.animals) do
		local dx = a.position.x - cx
		local dz = a.position.z - cz
		local dc = math.sqrt(dx * dx + dz * dz)
		if dc > maxSpread then maxSpread = dc end
		if ux ~= nil then
			local proj = dx * ux + dz * uz
			if proj > 0 and dc > farOutlierDist then
				farOutlierDist = dc
				farOutlier = a
			end
		end
	end

	-- Sample species tuning from first animal for the DRIVE balance distance.
	local cfg = animalFarm.animals[1].speciesCfg or AnimalSpeciesConfig.DEFAULT
	local walkDist = cfg.walkDistance

	-- Mode transition (hysteresis).
	local mode = farm.mode or "GATHER"
	-- HOLD overrides GATHER/DRIVE: once the herd has been pushed close
	-- enough to the player, the dog stops pressing and the animals are
	-- allowed to calm down. Hysteresis (enter 4 m, exit 6 m) prevents
	-- flapping when the centroid sits near the boundary.
	if mode == "HOLD" then
		if fromLen > HOLD_EXIT_DISTANCE then
			mode = (maxSpread > GATHER_THRESHOLD) and "GATHER" or "DRIVE"
		end
	else
		if fromLen <= HOLD_ENTER_DISTANCE then
			mode = "HOLD"
		elseif mode == "DRIVE" and maxSpread > GATHER_THRESHOLD then
			mode = "GATHER"
		elseif mode == "GATHER" and maxSpread <= DRIVE_THRESHOLD then
			mode = "DRIVE"
		end
	end
	farm.mode = mode

	-- Cache for the debug overlay.
	farm.farOutlierX = farOutlier ~= nil and farOutlier.position.x or nil
	farm.farOutlierZ = farOutlier ~= nil and farOutlier.position.z or nil

	local tx, tz
	if mode == "HOLD" then
		-- HOLD: dog stays put at its current position. getInfluencers
		-- returns {} during HOLD so the dog no longer adds arousal, and
		-- AnimalManager skips the per-animal guide pull — animals calm
		-- down instead of continuing to creep toward the centroid.
		tx, tz = farm.position.x, farm.position.z
	elseif fromLen < 0.1 then
		-- Player standing on top of the centroid; hold current dog position.
		tx, tz = farm.position.x, farm.position.z
	elseif mode == "GATHER" and farOutlier ~= nil and farOutlierDist >= 0.1 then
		-- GATHER: park just past the furthest far-side outlier along the
		-- outward-from-centroid direction. The outlier's flee vector then
		-- points back toward the centroid, collecting it into the herd,
		-- and because we only consider far-side animals the dog is always
		-- behind the herd from the player's perspective.
		--
		-- Critical: the target must stay INSIDE the pen. If the outlier is
		-- near a fence, a naive "outlier + 1.5m outward" lands past the
		-- fence — the dog can't reach it and ends up stuck on the centroid-
		-- side of the outlier, pushing the animal INTO the fence. We find
		-- the actual fence distance outward from the outlier and clamp the
		-- target to stay at least OUTLIER_FENCE_MARGIN inside. If there
		-- isn't enough room past the outlier for the dog to be on the
		-- correct side, fall through to DRIVE (push the whole herd from
		-- behind the centroid) instead of trying to squeeze the dog into
		-- a gap that doesn't exist.
		local ox = farOutlier.position.x - cx
		local oz = farOutlier.position.z - cz
		local oux, ouz = ox / farOutlierDist, oz / farOutlierDist

		local approachDist = FAR_OUTLIER_APPROACH
		if farm.husbandry ~= nil then
			local ex, ez = self:findHusbandryEdge(farm.husbandry, farOutlier.position.x, farOutlier.position.z, oux, ouz)
			if ex ~= nil then
				local fenceDist = math.sqrt((ex - farOutlier.position.x) ^ 2 + (ez - farOutlier.position.z) ^ 2)
				approachDist = math.min(approachDist, fenceDist - OUTLIER_FENCE_MARGIN)
			end
		end

		if approachDist >= OUTLIER_MIN_CLEARANCE then
			tx = farOutlier.position.x + oux * approachDist
			tz = farOutlier.position.z + ouz * approachDist
		else
			-- No room to push this outlier from the correct side. Fall
			-- through to the DRIVE position so the dog at least applies
			-- useful pressure from behind the centroid instead of stalling.
			local driveDistance = walkDist * DRIVE_BALANCE_FRACTION
			tx = cx + ux * driveDistance
			tz = cz + uz * driveDistance
			farm.farOutlierX, farm.farOutlierZ = nil, nil  -- debug: no outlier being worked
		end
	else
		-- DRIVE (tight herd) or GATHER fallback when no far-side outlier
		-- exists: push the whole group from behind the centroid along the
		-- far-from-player direction.
		local driveDistance = walkDist * DRIVE_BALANCE_FRACTION
		tx = cx + ux * driveDistance
		tz = cz + uz * driveDistance
	end

	if tx == nil then return end
	farm.targetPosition.x = tx
	farm.targetPosition.z = tz

	-- Orbit node visual rotation: always face the herd centroid.
	farm.faceX, farm.faceZ = cx, cz

end


function DogHerding:moveDogTowardTarget(farmId, dT)

	local farm = self.farms[farmId]
	local target = farm.targetPosition

	-- Use the real dog's world position as the influence point so animals
	-- react to where the player visually sees the dog. Fall back to a virtual
	-- lerp (DOG_APPROACH_SPEED) only while the companion node isn't
	-- queryable — e.g. during spawn / teleport transitions.
	local dogX, dogZ
	if farm.dog ~= nil then
		dogX, dogZ = self:getDogPosition(farm.dog)
	end
	if dogX ~= nil then
		farm.position.x = dogX
		farm.position.z = dogZ
	else
		local pos = farm.position
		local dx = target.x - pos.x
		local dz = target.z - pos.z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist >= 0.1 then
			local step = math.min(DOG_APPROACH_SPEED * dT * 0.001, dist)
			pos.x = pos.x + (dx / dist) * step
			pos.z = pos.z + (dz / dist) * step
		end
		dogX, dogZ = pos.x, pos.z
	end

	-- Drive the real dog via an orbit node it is told to walk to.
	-- FS25's companion API is node-based (no setCompanionBehaviorMoveTo
	-- exists) and FollowEntity doesn't track teleported transform groups;
	-- GotoEntity re-issued every few ticks is the working approach.
	--
	-- CAST PHASE: while the dog is still on the centroid-side of the
	-- target (i.e. its projection along the outward direction hasn't
	-- cleared the herd), route the orbit to a cast point at the pen edge
	-- along the outward direction from centroid. The dog paths along the
	-- outside of the herd to reach it instead of walking THROUGH the herd
	-- toward the target. Once the dog has cleared the centroid (projection
	-- > CAST_CLEAR_FRACTION × centroid→target distance), the orbit snaps
	-- to the real target for the close approach.
	if farm.orbitNode == nil or farm.orbitNode == 0 then return end

	local ox, oz = target.x, target.z
	farm.castPhase = false

	local animalFarm = g_animalManager.farms[farmId]
	if animalFarm ~= nil and animalFarm.animals ~= nil and #animalFarm.animals > 0 and farm.husbandry ~= nil then
		local cx, cz, n = 0, 0, 0
		for _, a in ipairs(animalFarm.animals) do
			cx = cx + a.position.x
			cz = cz + a.position.z
			n = n + 1
		end
		cx, cz = cx / n, cz / n

		local outDx, outDz = target.x - cx, target.z - cz
		local outLen = math.sqrt(outDx * outDx + outDz * outDz)
		if outLen > 0.1 then
			local oux, ouz = outDx / outLen, outDz / outLen
			local dogProj = (dogX - cx) * oux + (dogZ - cz) * ouz

			-- The orbit is intentionally placed at a waypoint the dog can
			-- NEVER fully reach. Previous attempts to place the orbit
			-- exactly at the target produced visible walk-arrive-sit-
			-- re-issue-walk cycling because the companion pathfinder's
			-- arrival threshold was hit every re-issue. Extending the
			-- orbit past the pen fence (or past the target in APPROACH)
			-- keeps the pathfinder continuously walking toward an
			-- unreachable waypoint — the dog stops at the fence / target
			-- as a physical constraint but stays in motion.
			if dogProj < outLen * CAST_CLEAR_FRACTION then
				local ex, ez = self:findHusbandryEdge(farm.husbandry, cx, cz, oux, ouz)
				if ex ~= nil then
					local edgeDist = math.sqrt((ex - cx) * (ex - cx) + (ez - cz) * (ez - cz))
					ox = cx + oux * (edgeDist + 5)
					oz = cz + ouz * (edgeDist + 5)
					farm.castPhase = true
				end
			else
				-- APPROACH: project the orbit past the target, adaptive.
				-- When the dog is far from target, orbit is far so the
				-- goto target sits outside the walk/run hysteresis and
				-- the dog picks the run gait. When the dog is close to
				-- target, orbit shrinks to match the engine's arrival
				-- threshold so the dog rests AT the target instead of
				-- stopping short of it.
				local ddx = target.x - dogX
				local ddz = target.z - dogZ
				local dogToTargetSq = ddx * ddx + ddz * ddz
				local proj
				if dogToTargetSq > APPROACH_ARRIVAL_ZONE * APPROACH_ARRIVAL_ZONE then
					proj = ORBIT_PROJECTION_FAR
				else
					proj = ORBIT_PROJECTION_NEAR
				end
				ox = target.x + oux * proj
				oz = target.z + ouz * proj
			end
		end
	end

	local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, ox, 0, oz)
	setWorldTranslation(farm.orbitNode, ox, y, oz)

	-- Face the orbit node toward the current focus — the herd centroid.
	-- faceX/faceZ is set by updateModeAndTarget.
	if farm.faceX ~= nil then
		local dirX, dirZ = farm.faceX - ox, farm.faceZ - oz
		if dirX * dirX + dirZ * dirZ > 0.01 then
			setWorldRotation(farm.orbitNode, 0, math.atan2(dirX, dirZ), 0)
		end
	end

	farm.ticksSinceLastMoveCommand = (farm.ticksSinceLastMoveCommand or 0) + 1

	-- Re-issue GotoEntity either on the periodic tick or immediately if the
	-- orbit has jumped more than DOG_COMMAND_MOVE_THRESHOLD since the last
	-- command. GotoEntity snapshots the orbit position at issue time — between
	-- re-issues the engine walks the dog toward that stale snapshot, so a
	-- big jump (e.g. CAST→APPROACH phase flip, or the target animal changed)
	-- would otherwise incur up to one full interval of lag. Small drifts
	-- (animals shuffling, centroid inching) wait for the periodic re-issue.
	local orbitJumped = false
	if farm.lastCommandX ~= nil then
		local jdx = ox - farm.lastCommandX
		local jdz = oz - farm.lastCommandZ
		if jdx * jdx + jdz * jdz > DOG_COMMAND_MOVE_THRESHOLD * DOG_COMMAND_MOVE_THRESHOLD then
			orbitJumped = true
		end
	end

	if farm.dog ~= nil and farm.dog.dogInstance ~= nil
	   and (farm.ticksSinceLastMoveCommand >= DOG_MOVE_COMMAND_INTERVAL or orbitJumped) then
		farm.ticksSinceLastMoveCommand = 0
		farm.lastCommandX, farm.lastCommandZ = ox, oz
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

	-- HOLD mode: dog is waiting, not threatening. No influence → animals
	-- are free to calm down. AnimalManager also skips the per-animal guide
	-- pull for this farm while isHolding(farmId) is true.
	if farm.mode == "HOLD" then return {} end

	-- Influencer tuple: { x, z, isBucket, isVehicle, isGuide, threatScale }.
	-- The dog is a vehicle-class influencer (gets the species vehicleRadiusMult
	-- scare radius) but with a scaled-down arousal contribution so animals
	-- don't instantly panic to 1.0 when the dog is close — DOG_THREAT_SCALE
	-- trims the per-tick arousal increment.
	return { { farm.position.x, farm.position.z, false, true, false, DOG_THREAT_SCALE } }

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
				orbitNode = orbitNode,
				husbandry = husb,
				huspCenter = { x = hx, z = hz }
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
