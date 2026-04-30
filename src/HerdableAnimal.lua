HerdableAnimal = {}
HerdableAnimal.WALK_DISTANCE = 20
HerdableAnimal.RUN_DISTANCE = 5
HerdableAnimal.TURN_DISTANCE = 15
HerdableAnimal.MAX_HERDING_RUN_SPEED = 3.0

local herdableAnimal_mt = Class(HerdableAnimal)
local modDirectory = g_currentModDirectory
local modName = g_currentModName
local nextId = 1


function HerdableAnimal.getNextId()

	nextId = nextId + 1
	return nextId - 1

end


function HerdableAnimal.new(placeable, rootNode, meshNode, shaderNode, skinNode, animationSet, animationCache, proxyNode)

	local self = setmetatable({}, herdableAnimal_mt)

	if g_server ~= nil then self.id = HerdableAnimal.getNextId() end

	I3DUtil.setShaderParameterRec(meshNode, "dirt", 0, nil, nil, nil)

	-- animal has 2 ways to end herding:
	-- 1. "Stop Herding" button - teleports animal to closest compatible placeable
	-- 2. Dynamic stop - stops being herdable when it enters a placeable, with the exception of the original placeable. Original placeable reference is removed after leaving for a certain amount of time, then can be dynamically returned to the original placeable

	self.placeable = placeable
	self.placeableLeaveTimer = 0
	self.stuckTimer = 0
	self.terrainHeight = 0
	self.startWalking = false
	self.stuckEscaping = false
	self.stuckEscapeDir = 0
	self.insideHusbandryPos = nil

	self.arousal = 0
	self.alertTimer = 0
	self.gazeTimer = 0
	self.lastThreatDir = nil
	self.lastAwareTick = 0
	self.grazeTarget = nil
	self.nextGrazeReselectTick = 0
	self.isGrazing = false
	self.lastNearestKey = nil
	self.lastNearestDist = nil
	self.speciesCfg = nil
	self.lastPosition = { x = 0, z = 0 }
	self._frameNeighbors = nil
	self.windowStartPosX = 0
	self.windowStartPosZ = 0
	self.windowTimer = 0
	self.lastWindowNetMove = 999

	self.nodes = {
		["root"] = rootNode,
		["mesh"] = meshNode,
		["shader"] = shaderNode,
		["skin"] = skinNode,
		["proxy"] = proxyNode
	}

	self.animation = AnimalAnimation.new(self, animationSet, animationCache)
	self.animNames = { walk = "walk1", idle = "idle1", run = "run1" }

	self.state = {
		["isIdle"] = true,
		["isWalking"] = false,
		["isRunning"] = false,
		["dirY"] = 0,
		["lastDirY"] = 0,
		["targetDirY"] = 0,
		["isTurning"] = false
	}

	self.herdingTarget = { ["distance"] = 100 }

	self.animation:setState(self.state)

	self.position = { ["x"] = 0, ["y"] = 0, ["z"] = 0 }
	self.rotation = { ["x"] = 0, ["y"] = 0, ["z"] = 0 }
	self.speed = 0
	self.tiles = { 1, 1, 1, 1 }

	self.collisionController = AnimalCollisionController.new(proxyNode)

	self.mapHotspot = AnimalHotspot.new()
	self.mapHotspot:setAnimal(self)
	g_currentMission:addMapHotspot(self.mapHotspot)
	self.lastStuckTurn = 0

	return self

end


function HerdableAnimal:delete()

	g_animalManager:deleteAnimalCollisionNode(self.collisionController.proxy)
	g_currentMission:removeMapHotspot(self.mapHotspot)
	self.mapHotspot:delete()
	if self.nodes.root ~= nil and self.nodes.root ~= 0 then
		delete(self.nodes.root)
	end

end


function HerdableAnimal:loadFromXMLFile(xmlFile, key, isRealisticLivestockLoaded)

	self.placeable = xmlFile:getString(key .. "#placeable")
	self.placeableLeaveTimer = xmlFile:getFloat(key .. "#placeableLeaveTimer")
	self.stuckTimer = xmlFile:getFloat(key .. "#stuckTimer")

	self.position.x = xmlFile:getFloat(key .. ".position#x", 0)
	self.position.y = xmlFile:getFloat(key .. ".position#y", 0)
	self.position.z = xmlFile:getFloat(key .. ".position#z", 0)

	self:updateTerrainHeight(true)

	self.rotation.x = xmlFile:getFloat(key .. ".rotation#x", 0)
	self.rotation.y = xmlFile:getFloat(key .. ".rotation#y", 0)
	self.rotation.z = xmlFile:getFloat(key .. ".rotation#z", 0)

	local classObject = ClassUtil.getClassObject(xmlFile:getString(key .. "#className", "AnimalCluster")) or AnimalCluster

	self.tiles = xmlFile:getVector(key .. "#tiles")

	local clusterKey = key .. ".cluster"

	if isRealisticLivestockLoaded then
		self.cluster = classObject.loadFromXMLFile(xmlFile, clusterKey)
	else
		self.cluster = classObject.new()
		self.cluster:loadFromXMLFile(xmlFile, clusterKey)

		if classObject == AnimalCluster or classObject == AnimalClusterHorse then
		
			self.cluster.subTypeIndex = g_currentMission.animalSystem:getSubTypeIndexByName(xmlFile:getString(clusterKey .. "#subType", ""))

		end

	end

end


function HerdableAnimal:saveToXMLFile(xmlFile, key)

	xmlFile:setInt(key .. "#visualAnimalIndex", self.visualAnimalIndex)

	if self.placeable ~= nil then xmlFile:setString(key .. "#placeable", self.placeable) end
	xmlFile:setFloat(key .. "#placeableLeaveTimer", self.placeableLeaveTimer)
	xmlFile:setFloat(key .. "#stuckTimer", self.stuckTimer)

	xmlFile:setFloat(key .. ".position#x", self.position.x)
	xmlFile:setFloat(key .. ".position#y", self.position.y)
	xmlFile:setFloat(key .. ".position#z", self.position.z)

	xmlFile:setFloat(key .. ".rotation#x", self.rotation.x)
	xmlFile:setFloat(key .. ".rotation#y", self.rotation.y)
	xmlFile:setFloat(key .. ".rotation#z", self.rotation.z)

	xmlFile:setString(key .. "#className", ClassUtil.getClassNameByObject(self.cluster))

	xmlFile:setVector(key .. "#tiles", self.tiles)

	local subType = g_currentMission.animalSystem:getSubTypeByIndex(self.cluster.subTypeIndex)
	xmlFile:setString(key .. ".cluster#subType", subType.name)
	self.cluster:saveToXMLFile(xmlFile, key .. ".cluster")

end


function HerdableAnimal:readStream(streamId)

	self.id = streamReadUInt8(streamId)
	self.placeable = streamReadString(streamId)

	if #self.placeable == 0 then self.placeable = nil end

	self.placeableLeaveTimer = streamReadFloat32(streamId)
	self.stuckTimer = streamReadFloat32(streamId)

	self.position.x = streamReadFloat32(streamId)
	self.position.y = streamReadFloat32(streamId)
	self.position.z = streamReadFloat32(streamId)

	self:updateTerrainHeight(true)

	self.rotation.x = streamReadFloat32(streamId)
	self.rotation.y = streamReadFloat32(streamId)
	self.rotation.z = streamReadFloat32(streamId)

	local classObject = ClassUtil.getClassObject(streamReadString(streamId)) or AnimalCluster
	local subTypeIndex = streamReadUInt8(streamId)

	self.cluster = classObject.new()
	self.cluster:readStream(streamId)

	if classObject == AnimalCluster or classObject == AnimalClusterHorse then self.cluster.subTypeIndex = subTypeIndex end

	local gender = streamReadString(streamId)
	if #gender > 0 then self.cluster.gender = gender end

end


function HerdableAnimal:writeStream(streamId)

	streamWriteUInt8(streamId, self.id)
	streamWriteString(streamId, self.placeable or "")
	streamWriteFloat32(streamId, self.placeableLeaveTimer)
	streamWriteFloat32(streamId, self.stuckTimer)

	streamWriteFloat32(streamId, self.position.x)
	streamWriteFloat32(streamId, self.position.y)
	streamWriteFloat32(streamId, self.position.z)

	streamWriteFloat32(streamId, self.rotation.x)
	streamWriteFloat32(streamId, self.rotation.y)
	streamWriteFloat32(streamId, self.rotation.z)

	streamWriteString(streamId, ClassUtil.getClassNameByObject(self.cluster))
	streamWriteUInt8(streamId, self.cluster.subTypeIndex)
	self.cluster:writeStream(streamId)
	streamWriteString(streamId, self.cluster.gender or "")

end


function HerdableAnimal:readUpdateStream(streamId)

	local position, rotation = self.position, self.rotation

	position.x = streamReadFloat32(streamId)
	position.z = streamReadFloat32(streamId)
	rotation.y = streamReadFloat32(streamId)

end


function HerdableAnimal:writeUpdateStream(streamId)

	local position, rotation = self.position, self.rotation

	streamWriteFloat32(streamId, position.x)
	streamWriteFloat32(streamId, position.z)
	streamWriteFloat32(streamId, rotation.y)

end


function HerdableAnimal:setHotspotIcon(animalTypeIndex)

	self.mapHotspot:setIcon(animalTypeIndex)

end


function HerdableAnimal:setHotspotFarmId(farmId)

	self.mapHotspot:setOwnerFarmId(farmId)

end


function HerdableAnimal:getHotspotFarmId()

	return self.mapHotspot:getOwnerFarmId()

end


function HerdableAnimal:setData(visualAnimalIndex, x, y, z, w)

	self.visualAnimalIndex = visualAnimalIndex
	self.tiles = { x, y, z, w }

end


function HerdableAnimal:getData()

	return self.visualAnimalIndex, self.tiles

end


function HerdableAnimal:getPlayerTeleportPosition()

	local dx, _, dz = localDirectionToWorld(self.nodes.root, 0, 0, -1)
	local radius = self.collisionController.radius

	return self.position.x + dx * radius, self.position.y + 0.2, self.position.z + dz * radius

end


function HerdableAnimal:setCluster(cluster)

	self.cluster = cluster

end


function HerdableAnimal:processPlaceableDetection(placeables)

	local x, z = self.position.x, self.position.z
	local originalPlaceable = self.placeable
	local insideOriginal = false

	for i, placeable in ipairs(placeables) do

		if originalPlaceable == placeable.id then

			if not placeable.placeable:getIsInAnimalDeliveryArea(x, z) then

				self.placeableLeaveTimer = self.placeableLeaveTimer + 1

				if self.placeableLeaveTimer >= 10 then self.placeable = nil end

			else

				self.placeableLeaveTimer = 0
				insideOriginal = true

				-- Cache husbandry center so stuck-escape can turn toward it
				local hx, _, hz = getWorldTranslation(placeable.placeable.rootNode)
				self.insideHusbandryPos = { x = hx, z = hz }

			end

		elseif placeable.placeable:getIsInAnimalDeliveryArea(x, z) then
			return i
		end

	end

	if not insideOriginal then
		self.insideHusbandryPos = nil
	end

	return nil

end


function HerdableAnimal:setPosition(x, y, z)

	self.position.x = x
	self.position.y = y
	self.position.z = z
	self:updateTerrainHeight(true)

	self.arousal = 0
	self.alertTimer = 0
	self.gazeTimer = 0
	self.lastThreatDir = nil
	self.grazeTarget = nil
	self.lastNearestKey = nil
	self.lastNearestDist = nil

end


function HerdableAnimal:setRotation(x, y, z)

	self.rotation.x = x
	self.rotation.y = y
	self.rotation.z = z

end


function HerdableAnimal:createCollisionController(height, radius, animalTypeIndex)

	self.collisionController:setAttributes(height, radius)
	self.collisionController:load(self.nodes.root, animalTypeIndex, self.cluster.age or 12)
	g_animalManager:addAnimalCollisionNode(self, self.collisionController.proxy)

end


function HerdableAnimal:validateSpeed(animalTypeIndex)

	self.speciesCfg = AnimalSpeciesConfig.get(animalTypeIndex)
	self.animalTypeIndex = animalTypeIndex

end


function HerdableAnimal:applyAnimationNames()

	local age = (self.cluster ~= nil and self.cluster.age) or 12
	self.animNames = AnimalAnimationNaming.resolve(self.animalTypeIndex, age)

end


function HerdableAnimal:applyLocomotionSpeeds(cache)

	local walkAnim = self.animation:getRandomAnimation("walk")
	local runAnim = self.animation:getRandomAnimation("run") or walkAnim

	if walkAnim ~= nil and walkAnim.speed > 0 then
		local targetWalk = cache.locomotionWalkSpeed or walkAnim.speed
		self.animation:changeSpeedForState("walk", targetWalk / walkAnim.speed)
	end

	if runAnim ~= nil then
		local locomotionRunSpeed = cache.locomotionRunSpeed
		if locomotionRunSpeed ~= nil and locomotionRunSpeed > 0 then
			-- The run animation's XML speed attr is often just the default (1.0) and does not
			-- reflect the actual designed movement speed. locomotionRunSpeed is authoritative.
			local targetRun = math.min(locomotionRunSpeed, (self.speciesCfg and self.speciesCfg.maxRunSpeed or HerdableAnimal.MAX_HERDING_RUN_SPEED))
			local modifier = targetRun / locomotionRunSpeed
			self.animation:changeSpeedForState("run", modifier)
			self.animation:setStateSpeedOverride("run", locomotionRunSpeed)
		elseif runAnim.speed > 0 then
			local walkModifier = 1.0
			if walkAnim ~= nil and walkAnim.speed > 0 then
				local targetWalk = cache.locomotionWalkSpeed or walkAnim.speed
				walkModifier = targetWalk / walkAnim.speed
			end
			local targetRun = math.min(runAnim.speed, (self.speciesCfg and self.speciesCfg.maxRunSpeed or HerdableAnimal.MAX_HERDING_RUN_SPEED))
			local runModifier = math.min(targetRun / runAnim.speed, walkModifier)
			self.animation:changeSpeedForState("run", runModifier)
		end
	end

	-- Baby sheep have no proper run clip; make walk animate at the run rate so they don't crawl.
	if self.animalTypeIndex == AnimalType.SHEEP and self.cluster ~= nil and (self.cluster.age or 12) < 3 then
		local runMod = self.animation.speedModifiers["run"] or 1
		self.animation:changeSpeedForState("walk", runMod)
		local runEffective = cache.locomotionRunSpeed
		if runEffective == nil and runAnim ~= nil then runEffective = runAnim.speed end
		if runEffective ~= nil and runEffective > 0 then
			self.animation:setStateSpeedOverride("walk", runEffective)
		end
	end

end


function HerdableAnimal:updatePosition()

	setWorldTranslation(self.nodes.root, self.position.x, self.position.y, self.position.z)

end


function HerdableAnimal:updateRotation()

	setWorldRotation(self.nodes.root, 0, self.rotation.y, 0)

end


function HerdableAnimal:update(dT)

	local x, y, z = self.position.x, self.position.y, self.position.z
	local state = self.state
	local cfg = self.speciesCfg
	local walkDist = cfg and cfg.walkDistance or HerdableAnimal.WALK_DISTANCE
	local runDist  = cfg and cfg.runDistance  or HerdableAnimal.RUN_DISTANCE

	-- Refresh terrain height every tick (not just every 10 via updateRelativeToPlayers).
	-- The async surface raycast is cheap and per-tick firing reduces the
	-- transition lag from ~10 ticks to ~2 when the animal crosses surface
	-- boundaries (terrain ↔ shed floor, etc.). Without this the
	-- onElevatedSurface flag lags ~166 ms behind the animal's actual position
	-- and the +0.2 step-up flicks on/off causing visible vertical jitter at
	-- transitions.
	self:updateTerrainHeight()

	-- Record pre-update position so the post-step geometric push (AnimalManager)
	-- can tell who actually moved this frame and weight the separation accordingly.
	self.lastPosition.x = x
	self.lastPosition.z = z

	local isWalkingFromPlayer = false
	local hasCollision = false

	-- Reset translation scale each tick so a stale grazing / yield scale
	-- from a previous walk session doesn't bleed into the current one
	-- (the translation branch overrides this when it runs).
	self.lastMoveSpeedScale = 1

	state.wasWalking, state.wasRunning, state.wasIdle = state.isWalking, state.isRunning, state.isIdle

	if self.startWalking then

		self.startWalking = false
		state.isIdle = false

	end

	-- Persistent pure-turn mode with explicit entry/exit conditions.
	-- The alert/calm/flee branches in updateRelativeToPlayers bounce
	-- state.isTurning on and off every frame via the ±0.05 rad
	-- alreadyFacing check. Previously my gate keyed off state.isTurning
	-- each frame, so it dropped out every other frame, the animation's
	-- idle branch then disabled the turn clip, and the next frame
	-- re-installed it — producing the turnRight-install ↔ idle-install
	-- flicker at 30-60 Hz visible in the movement debug log.
	--
	-- ENTRY: state.isTurning=true AND remaining > turnInPlaceMinDeg (30°).
	-- EXIT:  remaining < 3° AND state.isTurning=false (both — isTurning
	--        alone bounces; angle alone can hover at small non-zero
	--        values while the target drifts).
	-- STAY:  otherwise. Survives single-frame isTurning blips and keeps
	--        the turn clip playing smoothly to completion.
	local remaining = state.targetDirY - self.rotation.y
	while remaining >   math.pi do remaining = remaining - 2 * math.pi end
	while remaining <= -math.pi do remaining = remaining + 2 * math.pi end
	local remainingDeg = math.abs(math.deg(remaining))
	local inPureTurn = self._inPureTurn or false

	if inPureTurn then
		if remainingDeg < 3 and not state.isTurning then
			inPureTurn = false
		elseif self.herdingTarget.followingBucket then
			inPureTurn = false  -- bucket-follow overrides
		end
	else
		local minDeg = (cfg and cfg.turnInPlaceMinDeg) or 30
		if state.isTurning and remainingDeg > minDeg and not self.herdingTarget.followingBucket then
			inPureTurn = true
		end
	end
	self._inPureTurn = inPureTurn
	-- Publish the flag to the shared state struct so AnimalAnimation's turn
	-- branch can read it directly (decoupled from state.isTurning, which
	-- the turn block below clears whenever rotation reaches the target
	-- window — if animation keyed off isTurning it would miss the last
	-- frame and flicker to idle).
	state.inPureTurn = inPureTurn

	if inPureTurn then
		state.isIdle, state.isWalking, state.isRunning = true, false, false
	end

	if not state.isIdle then

		self.collisionController:updateCollisions(state.isTurning)
		hasCollision, needsYAdjustment = self.collisionController:getHasCollision()

		-- Skip the +0.2 step-up while standing on an elevated placeable surface
		-- (shed flooring, road, building platform). The groundLow probe still
		-- hits the surface mesh as STATIC_OBJECT, but the surface IS the ground
		-- here — adding +0.2 floats the animal and oscillates with the next
		-- frame's drop-back-to-surface. The step-up is only needed for stepping
		-- over small obstacles on raw terrain.
		local targetStepUp = (needsYAdjustment and not self.onElevatedSurface) and 0.2 or 0
		-- Smooth toggling so a brief stepUp transition (e.g. crossing a surface
		-- boundary while the async raycast result is still updating) doesn't
		-- snap the animal vertically. dT is in ms; ~1.0 m/s ramp = 0.001 m/ms,
		-- which gives ~200 ms for the full 0.2 m step — fast enough that real
		-- obstacle step-overs still look natural, slow enough that 1-2 tick
		-- false-positives on placeable floors barely register visually.
		self.smoothedStepUp = self.smoothedStepUp or 0
		local maxDelta = (dT or 16) * 0.001
		if targetStepUp > self.smoothedStepUp then
			self.smoothedStepUp = math.min(self.smoothedStepUp + maxDelta, targetStepUp)
		elseif targetStepUp < self.smoothedStepUp then
			self.smoothedStepUp = math.max(self.smoothedStepUp - maxDelta, targetStepUp)
		end
		self.position.y = self.terrainHeight + self.smoothedStepUp

		if hasCollision then

			state.isIdle, state.isWalking, state.isRunning = true, false, false
			self.stuckTimer = math.min(self.stuckTimer + dT, 2000)

			-- After 400 ms stuck, start an escape turn (once per escape, extend each 90° cycle)
			if self.stuckTimer > 400 and not state.isTurning then

				-- Choose escape direction once at the start of each escape attempt
				if not self.stuckEscaping then
					self.stuckEscaping = true
					if self.insideHusbandryPos == nil then
						-- Outside husbandry: prefer the side with no lateral collision
						local canLeft  = self.collisionController:getCanTurnLeft()
						local canRight = self.collisionController:getCanTurnRight()
						self.stuckEscapeDir = canRight and 1 or (canLeft and -1 or 1)
					end
				end

				local escapeTarget
				if self.insideHusbandryPos ~= nil then
					-- Inside husbandry: turn to face the husbandry centre and walk back to it
					local dx = self.insideHusbandryPos.x - self.position.x
					local dz = self.insideHusbandryPos.z - self.position.z
					escapeTarget = math.atan2(dx, dz)
				else
					-- Outside husbandry: rotate 90° in the chosen clear direction each cycle
					-- stuckEscapeDir=1 → CW (decrease ry); -1 → CCW (increase ry)
					escapeTarget = self.rotation.y - math.rad(self.stuckEscapeDir * 90)
					if escapeTarget >  math.pi then escapeTarget = escapeTarget - 2 * math.pi end
					if escapeTarget < -math.pi then escapeTarget = escapeTarget + 2 * math.pi end
				end

				state.targetDirY = escapeTarget
				state.isTurning  = true

			end

			-- When both sides and front are blocked for > 800ms (truly wedged between two walls),
			-- back up to create room for the escape turn to work.
			if self.stuckTimer > 800 then
				local canLeft  = self.collisionController:getCanTurnLeft()
				local canRight = self.collisionController:getCanTurnRight()
				if not canLeft and not canRight then
					local stepX, _, stepZ = localDirectionToWorld(self.nodes.root, 0, 0, 1)
					self.position.x = x - stepX * dT * 0.001 * 1.5
					self.position.z = z - stepZ * dT * 0.001 * 1.5
					self:updatePosition()
				end
			end

		else

			self.stuckTimer = 0
			self.stuckEscaping = false
			self.stuckEscapeDir = 0

			local distance

			if self.herdingTarget.distance < walkDist and not (self.herdingTarget.followingBucket and self.herdingTarget.distance < runDist / 2) then

				distance = self.herdingTarget.distance
				isWalkingFromPlayer = true

			else

				state.isIdle = true
				state.isWalking, state.isRunning = false, false

			end

			if isWalkingFromPlayer then

				local stepX, _, stepZ = localDirectionToWorld(self.nodes.root, 0, 0, 1)

				local speedScale = 1
				if self.isGrazing and cfg ~= nil then speedScale = cfg.grazeSpeedScalar or 1 end
				-- Remember the translation scale so the post-update animation-
				-- playback sync can feed it into the anim track speed scale.
				-- Without it the walk clip plays at full rate while the body
				-- moves at grazeSpeedScalar * walk — visible moonwalk.
				self.lastMoveSpeedScale = speedScale

				-- Front-neighbor yield: slow down when another animal is directly ahead
				-- within a tight forward cone. Panicking animals skip this so stampede
				-- keeps its momentum (separation still pushes them apart laterally).
				local yieldedToStop = false
				local arousalValue = self.arousal or 0
				local startleTh = (cfg and cfg.startleThreshold) or 0.55
				if arousalValue < startleTh and self._frameNeighbors ~= nil then
					local selfR = (self.collisionController and (self.collisionController.behaviorRadius or self.collisionController.radius)) or 0.5
					local nearestAhead = nil
					local nearestAheadDist = math.huge
					for _, other in ipairs(self._frameNeighbors) do
						if other ~= self then
							local odx = other.position.x - x
							local odz = other.position.z - z
							local oDistSq = odx * odx + odz * odz
							if oDistSq > 0.0001 then
								local oDist = math.sqrt(oDistSq)
								local invD = 1 / oDist
								-- Forward-cone test: ±25° → cos(25°) ≈ 0.906
								local dot = (odx * invD) * stepX + (odz * invD) * stepZ
								if dot > 0.906 then
									local otherR = (other.collisionController and (other.collisionController.behaviorRadius or other.collisionController.radius)) or 0.5
									local frontRange = (selfR + otherR) * 1.2
									if oDist < frontRange and oDist < nearestAheadDist then
										nearestAheadDist = oDist
										nearestAhead = { d = oDist, minD = selfR + otherR + 0.1, range = frontRange }
									end
								end
							end
						end
					end
					if nearestAhead ~= nil then
						local span = nearestAhead.range - nearestAhead.minD
						local yieldScale
						if span <= 0.01 then
							yieldScale = 0
						else
							yieldScale = (nearestAhead.d - nearestAhead.minD) / span
							if yieldScale < 0 then yieldScale = 0 end
							if yieldScale > 1 then yieldScale = 1 end
						end
						speedScale = speedScale * yieldScale
						-- If yield effectively halted us, switch the animation to idle
						-- instead of looping walk/run in place behind the obstructing animal.
						if yieldScale < 0.15 then yieldedToStop = true end
					end
				end

				if distance > 0 then

					self.position.x = x + stepX * dT * 0.001 * self.speed * speedScale
					self.position.z = z + stepZ * dT * 0.001 * self.speed * speedScale

				end

				local isMoving = stepX ~= 0 or stepZ ~= 0

				state.isWalking = isMoving
				state.isRunning = false

				if isMoving and not self.isGrazing then

					if self.herdingTarget.followingBucket then

						if state.wasRunning then
							state.isRunning = distance > runDist
						else
							state.isRunning = distance > walkDist - runDist
						end
						state.isWalking = not state.isRunning

					elseif isWalkingFromPlayer and distance < runDist then

						state.isRunning = true
						state.isWalking = false

					end

				end

				-- Yield override: if blocked by the animal ahead, switch animation
				-- to idle even though we're still in the walk branch. Turning in
				-- place is still allowed (state.isTurning untouched).
				if yieldedToStop then
					state.isIdle = true
					state.isWalking = false
					state.isRunning = false
				end

				if state.isWalking then

					--self.walkingState.movementDirX = stepX
					--self.walkingState.movementDirZ = stepZ

				end

				--if distance <= 0.25 then

					--if math.random() >= 0.65 then

						--state.isIdle = true
						--state.isWalking = false
						--state.isRunning = false

					--else

						--self:findTarget()

					--end

				--end

			end

			self:updatePosition()

		end

	else

		--if math.random() >= 0.95 then self:findTarget() end

	end


	-- ##########################################################################
	-- TODO:
	-- Animal sometimes gets stuck on tight corners when being herded with bucket
	-- Have tried to mitigate this but still occasionally happens
	-- ##########################################################################


	if state.isTurning or (hasCollision and not state.isIdle and self.herdingTarget.followingBucket) then

		local ry = math.deg(self.rotation.y)
		--local turnTarget = hasCollision and self.stuckTimer > 1000 and (ry + 10) or math.deg(state.targetDirY)
		local turnTarget = math.deg(state.targetDirY)

		local canTurnLeft = self.collisionController:getCanTurnLeft()
		local canTurnRight = self.collisionController:getCanTurnRight()

		-- Wedge override: when a stuck escape is in progress but both sides are blocked,
		-- allow rotation anyway. Without this the turn code has no valid branch and the
		-- animal freezes permanently between two parallel walls.
		if self.stuckEscaping and not canTurnLeft and not canTurnRight then
			canTurnLeft = true
			canTurnRight = true
		end

		state.lastDirY = self.rotation.y
		ry, turnTarget = ry + 180, turnTarget + 180

		if self.herdingTarget.followingBucket and hasCollision then

			if canTurnRight and canTurnLeft then
				turnTarget = ry + 10 * (ry < turnTarget and 1 or -1)
				self.lastStuckTurn = (ry < turnTarget and 1 or -1)
			elseif canTurnLeft then
				turnTarget = ry - 10
				self.lastStuckTurn = -1
			elseif canTurnRight then
				turnTarget = ry + 10
				self.lastStuckTurn = 1
			end

		else

				self.lastStuckTurn = 0

		end

		if ry < turnTarget then

			if canTurnLeft and math.abs(ry - turnTarget) < 180 then
				ry = ry + dT * 0.035
			elseif canTurnRight then
				ry = ry - dT * 0.035
			end

		else

			if canTurnRight and math.abs(ry - turnTarget) < 180 then
				ry = ry - dT * 0.035
			elseif canTurnLeft then
				ry = ry + dT * 0.035
			end

		end

		ry = ry - 180
		if ry < -180 then ry = 180 end
		if ry > 180 then ry = -180 end

		self.rotation.y = math.rad(ry)

		state.dirY = self.rotation.y

		if self.rotation.y <= state.targetDirY + 0.05 and self.rotation.y >= state.targetDirY - 0.05 then
			state.targetDirY = 0
			state.isTurning = false
		end

		self:updateRotation()

	end

	-- Stall detector: while the animal is trying to walk/run, sample end-of-update
	-- position every 500 ms and compute net displacement. Unlike a per-frame step
	-- check, this captures "step cancelled by push" cases — e.g. an animal
	-- converging on a bucket carrier whose path is blocked by others, where each
	-- frame's step is promptly undone by the geometric separation push. If net
	-- movement over the window is tiny, switch animation to idle.
	if state.isIdle then
		-- Natural idle — reset the window so we don't false-positive stalled
		-- when the animal next starts walking after a long idle period.
		self.windowStartPosX = self.position.x
		self.windowStartPosZ = self.position.z
		self.windowTimer = 0
		self.lastWindowNetMove = 999
	else
		self.windowTimer = self.windowTimer + dT
		if self.windowTimer >= 500 then
			local wdx = self.position.x - self.windowStartPosX
			local wdz = self.position.z - self.windowStartPosZ
			self.lastWindowNetMove = math.sqrt(wdx * wdx + wdz * wdz)
			self.windowStartPosX = self.position.x
			self.windowStartPosZ = self.position.z
			self.windowTimer = 0
		end
	end

	-- <0.08 m over 500 ms = <0.16 m/s net: walking animation would look like
	-- walking-in-place. Force idle. Turning is left alone so the animal can
	-- still rotate toward its target direction.
	if self.lastWindowNetMove < 0.08 and (state.isWalking or state.isRunning) then
		state.isIdle = true
		state.isWalking = false
		state.isRunning = false
	end

	self.animation:setState(self.state)
	self.animation:update(dT, isWalkingFromPlayer)

	-- World-speed ramp. getMovementSpeed reflects the target gait (walk/run
	-- blend-aware during clip transitions), but at the end of a walk↔run
	-- transition the speedId/speedModifier snap to the new state in one
	-- frame — visible as a forward lurch in world translation. Clamping
	-- the rate of change on self.speed kills the lurch at the one place
	-- speed reaches the world, without interfering with the animation
	-- engine's own clip-blend or the baby-sheep walk-at-run-speed override.
	local targetSpeed = self.animation:getMovementSpeed()
	local accel = (cfg and cfg.speedAccelMps2) or 2.5
	local maxStep = accel * dT * 0.001
	if self.speed < targetSpeed then
		self.speed = math.min(self.speed + maxStep, targetSpeed)
	else
		self.speed = math.max(self.speed - maxStep, targetSpeed)
	end

	-- Sync animation playback to ACTUAL world movement so legs match body.
	-- getMovementSpeed returns the animation's nominal m/s given its
	-- current clip blend + speedModifiers, but the actual world translation
	-- is (self.speed * lastMoveSpeedScale) — self.speed is ramp-clamped
	-- during walk↔run transitions, and lastMoveSpeedScale carries the
	-- grazeSpeedScalar (cow 0.5 during grazing) plus any front-neighbor
	-- yield scaling. Without this adjustment the walk clip plays at full
	-- rate while the body creeps — visible moonwalk / skating feet.
	-- Clamp playback ratio so transition-edge spikes (e.g. targetSpeed
	-- briefly tiny during walk→idle blend while self.speed hasn't caught
	-- down yet) don't send the clip to 5× playback and back. Lower bound
	-- keeps the animation just-visibly moving during ramp-up.
	local scale = self.lastMoveSpeedScale or 1
	local playbackRatio = 1
	if targetSpeed > 0.05 then
		playbackRatio = (self.speed * scale) / targetSpeed
		if playbackRatio < 0.3 then playbackRatio = 0.3
		elseif playbackRatio > 1.3 then playbackRatio = 1.3 end
	end
	self.animation:setPlaybackSpeedScale(playbackRatio)

end


function HerdableAnimal:updateRelativeToPlayers(players, updateTerrain, dtSec, neighbors)

	local x, y, z = self.position.x, self.position.y, self.position.z
	local state = self.state
	local cfg = self.speciesCfg or AnimalSpeciesConfig.DEFAULT
	dtSec = dtSec or 0

	-- STAGE A: Sense threats and bucket
	local hasBucketInRange = false
	local bucketX, bucketZ, bucketNearestDist
	local nearest = nil
	local nearestSq = math.huge
	-- "Real" threat tracker — excludes synthetic guide influencers (isGuide).
	-- Used for arousal buildup in Stage B so a non-scary directional pull
	-- doesn't ratchet arousal to 1.0 just by being nearby.
	local nearestThreat = nil
	local nearestThreatSq = math.huge
	local fleeAccX, fleeAccZ = 0, 0
	local fleeWeight = 0

	for _, player in pairs(players) do

		local px, pz = player[1], player[2]
		local isBucket = player[3]
		local isVehicle = player[4] or false
		local isGuide = player[5] or false
		local threatScale = player[6] or 1

		local dx, dz = x - px, z - pz
		local distSq = dx * dx + dz * dz

		if isBucket then

			if distSq <= HerdableAnimal.WALK_DISTANCE * HerdableAnimal.WALK_DISTANCE then
				local dist = math.sqrt(distSq)
				if not hasBucketInRange or dist < bucketNearestDist then
					bucketNearestDist = dist
					bucketX, bucketZ = px, pz
				end
				hasBucketInRange = true
			end

		else

			local radius = cfg.walkDistance
			if isVehicle then radius = radius * cfg.vehicleRadiusMult end

			if distSq <= radius * radius then

				local w = 1.0 / math.max(distSq, 0.5)
				if isVehicle then w = w * cfg.vehicleArousalMult end
				fleeAccX = fleeAccX + dx * w
				fleeAccZ = fleeAccZ + dz * w
				fleeWeight = fleeWeight + w

				if distSq < nearestSq then
					nearestSq = distSq
					local d = math.sqrt(distSq)
					local keyX = math.floor(px * 2 + 0.5)
					local keyZ = math.floor(pz * 2 + 0.5)
					local key = keyX * 100000 + keyZ
					local approachSpeed = 0
					if self.lastNearestKey == key and self.lastNearestDist ~= nil and dtSec > 0 then
						approachSpeed = (self.lastNearestDist - d) / dtSec
					end
					nearest = {
						px = px, pz = pz, dx = dx, dz = dz,
						dist = d, distSq = distSq, key = key,
						isVehicle = isVehicle, isGuide = isGuide, approachSpeed = approachSpeed
					}
				end

				-- Track the nearest non-guide threat separately so arousal
				-- only builds from real threats (the dog / a player / a
				-- vehicle), not from synthetic directional pulls.
				if not isGuide and distSq < nearestThreatSq then
					nearestThreatSq = distSq
					local d = math.sqrt(distSq)
					local keyX = math.floor(px * 2 + 0.5)
					local keyZ = math.floor(pz * 2 + 0.5)
					local key = keyX * 100000 + keyZ
					local approachSpeed = 0
					if self.lastNearestThreatKey == key and self.lastNearestThreatDist ~= nil and dtSec > 0 then
						approachSpeed = (self.lastNearestThreatDist - d) / dtSec
					end
					nearestThreat = {
						px = px, pz = pz, dx = dx, dz = dz,
						dist = d, distSq = distSq, key = key,
						isVehicle = isVehicle, threatScale = threatScale,
						approachSpeed = approachSpeed
					}
				end

			end

		end

	end

	-- Remember nearest threat for next-frame approach-speed derivation
	if nearest ~= nil then
		self.lastNearestKey = nearest.key
		self.lastNearestDist = nearest.dist
	else
		self.lastNearestKey = nil
		self.lastNearestDist = nil
	end
	if nearestThreat ~= nil then
		self.lastNearestThreatKey = nearestThreat.key
		self.lastNearestThreatDist = nearestThreat.dist
	else
		self.lastNearestThreatKey = nil
		self.lastNearestThreatDist = nil
	end

	-- BUCKET: hard override (preserves existing behavior)
	if hasBucketInRange then

		self.isGrazing = false
		self.grazeTarget = nil
		self.arousal = math.max(0, self.arousal - cfg.arousalDecayPerSec * dtSec)

		-- Close-arrival deadzone: once the animal is within 1.5 m of the
		-- bucket, freeze rotation + stop commanding new walk starts. The
		-- direction-to-bucket vector becomes unstable at near-zero distance
		-- (tiny player movements produce large angle swings), and
		-- getHasPlayerInVicinity() flickers at the collision probe boundary
		-- — previously produced visible "vibration" on the animal.
		local BUCKET_ARRIVED_DIST = 1.5
		if bucketNearestDist < BUCKET_ARRIVED_DIST then
			state.isTurning = false
			state.targetDirY = self.rotation.y
			state.isIdle = true
			self.herdingTarget = {
				ry = self.rotation.y,
				distance = bucketNearestDist,
				followingBucket = true,
				dx = x - bucketX, dz = z - bucketZ,
				x = x, z = z, ax = bucketX, az = bucketZ
			}
			if updateTerrain then self:updateTerrainHeight() end
			return
		end

		local dirX, dirZ = MathUtil.vector2Normalize(bucketX - x, bucketZ - z)
		local dy = MathUtil.getYRotationFromDirection(dirX, dirZ)

		if state.isIdle and not self.startWalking and not (bucketNearestDist < HerdableAnimal.RUN_DISTANCE / 2) then
			self.startWalking = true
		end

		self.herdingTarget = {
			ry = dy,
			distance = bucketNearestDist,
			followingBucket = true,
			dx = x - bucketX, dz = z - bucketZ,
			x = x, z = z, ax = bucketX, az = bucketZ
		}

		if bucketNearestDist > HerdableAnimal.TURN_DISTANCE or
		   (self.rotation.y <= dy + 0.05 and self.rotation.y >= dy - 0.05) or
		   self.collisionController:getHasPlayerInVicinity() then
			state.isTurning = false
			state.targetDirY = self.rotation.y
		else
			state.isTurning = true
			state.targetDirY = dy
		end

		if bucketNearestDist < HerdableAnimal.WALK_DISTANCE and state.isIdle then
			self.startWalking = true
		end

		if updateTerrain then self:updateTerrainHeight() end
		return

	end

	-- STAGE B: Arousal update. Only REAL threats (nearestThreat) build
	-- arousal — synthetic guide influencers feed flee direction and the
	-- turn gate but are never scary in themselves, so arousal decays when
	-- only a guide is present. `nearest` (which may be the guide) still
	-- drives the "last threat direction" so gaze/alert behaviour points
	-- toward whatever the animal is reacting to.
	local prevArousal = self.arousal

	if nearestThreat ~= nil then

		local radius = cfg.walkDistance * (nearestThreat.isVehicle and cfg.vehicleRadiusMult or 1)
		local dNorm = math.max(0, 1 - nearestThreat.dist / radius)

		-- Proximity floor: a far, non-approaching INFLUENCER should allow decay
		-- so a stationary player at the edge of awareness doesn't build fear
		-- indefinitely. Pedestrians tolerate animals past 70% of walkDistance.
		-- Vehicles (including the sheepdog) are genuinely scary throughout most
		-- of their effective radius — if you're within 90% of a vehicle's
		-- scare zone and it's watching you, you should be building arousal,
		-- not decaying. Otherwise a stationary dog parked at the balance point
		-- never gets animals above startleThreshold.
		local staleRadius
		if nearestThreat.isVehicle then
			staleRadius = radius * 0.9
		else
			staleRadius = cfg.walkDistance * 0.7
		end
		local isStaleThreat = (nearestThreat.approachSpeed <= 0 and nearestThreat.dist > staleRadius)

		if isStaleThreat then
			self.arousal = math.max(0, self.arousal - cfg.arousalDecayPerSec * dtSec)
		else
			local dA = dNorm * 1.2 * dtSec
			if nearestThreat.approachSpeed > 0 then
				local sNorm = math.min(nearestThreat.approachSpeed / 4.0, 1.5)
				local vMult = nearestThreat.isVehicle and cfg.vehicleArousalMult or 1
				dA = dA + sNorm * 0.8 * dtSec * vMult
			end
			-- Per-threat scale (set by DogHerding.getInfluencers for the
			-- dog, defaults to 1 for players / regular vehicles).
			dA = dA * (nearestThreat.threatScale or 1)
			self.arousal = math.min(1.0, self.arousal + dA)
		end

		self.lastAwareTick = g_time
		self.alertTimer = cfg.alertLingerMs

	end

	if nearest ~= nil then
		local invD = 1.0 / math.max(nearest.dist, 0.001)
		self.lastThreatDir = { x = nearest.dx * invD, z = nearest.dz * invD }
	end

	if nearestThreat == nil then

		self.arousal = math.max(0, self.arousal - cfg.arousalDecayPerSec * dtSec)
		if self.alertTimer > 0 then
			self.alertTimer = math.max(0, self.alertTimer - dtSec * 1000)
		end

	end

	-- Pre-flee gaze seeding: first frame crossing startleThreshold from below while idle
	if nearest ~= nil and prevArousal < cfg.startleThreshold and self.arousal >= cfg.startleThreshold
	   and self.gazeTimer <= 0 and self.lastThreatDir ~= nil and state.isIdle then
		self.gazeTimer = cfg.preFleeGazeMs
	end
	if self.gazeTimer > 0 then self.gazeTimer = self.gazeTimer - dtSec * 1000 end

	-- STAGE C: Accumulate steering forces

	local fleeX, fleeZ, fleeW = 0, 0, 0
	if nearest ~= nil and self.arousal >= cfg.startleThreshold and fleeWeight > 0 then
		local len = math.sqrt(fleeAccX * fleeAccX + fleeAccZ * fleeAccZ)
		if len > 0.0001 then
			fleeX = fleeAccX / len
			fleeZ = fleeAccZ / len
			fleeW = 0.6 + 0.8 * self.arousal
		end
	end

	local cohX, cohZ, cohW = 0, 0, 0
	local aliX, aliZ, aliW = 0, 0, 0
	local sepX, sepZ, sepW = 0, 0, 0
	if neighbors ~= nil then
		local cx, cz, count = 0, 0, 0
		local avgRx, avgRz = 0, 0
		local sepAccX, sepAccZ, sepCount = 0, 0, 0
		local selfR = (self.collisionController and (self.collisionController.behaviorRadius or self.collisionController.radius)) or 0.5
		for _, other in ipairs(neighbors) do
			if other ~= self then
				local ox, oz = other.position.x, other.position.z
				local odx, odz = ox - x, oz - z
				local oDistSq = odx * odx + odz * odz
				if oDistSq > 0.01 then
					-- Separation: cross-species close-range repulsion. Uses each
					-- animal's own radius so a horse pushes harder on a chicken than
					-- a chicken pushes on a horse (handled via arousal/weight downstream).
					local otherR = (other.collisionController and (other.collisionController.behaviorRadius or other.collisionController.radius)) or 0.5
					local sepRange = (selfR + otherR) * 1.5
					if oDistSq <= sepRange * sepRange then
						local sq = math.max(oDistSq, 0.1)
						sepAccX = sepAccX + (x - ox) / sq
						sepAccZ = sepAccZ + (z - oz) / sq
						sepCount = sepCount + 1
					end

					-- Cohesion/alignment: same-species only, within flock radius.
					if other.animalTypeIndex == self.animalTypeIndex
					   and oDistSq <= cfg.flockRadius * cfg.flockRadius then
						cx = cx + ox
						cz = cz + oz
						avgRx = avgRx + math.sin(other.rotation.y)
						avgRz = avgRz + math.cos(other.rotation.y)
						count = count + 1
						if count >= cfg.maxFlockNeighbors then break end
					end
				end
			end
		end

		if sepCount > 0 then
			local slenSep = math.sqrt(sepAccX * sepAccX + sepAccZ * sepAccZ)
			if slenSep > 0.0001 then
				sepX = sepAccX / slenSep
				sepZ = sepAccZ / slenSep
				sepW = (cfg.separationWeight or 1.0) * (1 + 0.5 * self.arousal)
			end
		end

		if count > 0 then
			local dxc, dzc = (cx / count) - x, (cz / count) - z
			local lenC = math.sqrt(dxc * dxc + dzc * dzc)

			-- Cohesion only engages once the animal has drifted past a comfortable
			-- bunching distance. Inside that radius it's already "with the herd"
			-- and should idle/graze rather than keep walking into its neighbors.
			local comfortRadius = math.max(2.5, cfg.flockRadius * 0.4)
			if lenC > comfortRadius then
				cohX = dxc / lenC
				cohZ = dzc / lenC
				local drift = math.min((lenC - comfortRadius) / comfortRadius, 1.0)
				cohW = cfg.cohesionWeight * math.max(0, 1 - self.arousal) * drift
			end

			-- Alignment drives stampede coherence in panic; no reason to bias
			-- heading when calm and already grouped.
			local lenA = math.sqrt(avgRx * avgRx + avgRz * avgRz)
			if lenA > 0.0001 and (self.arousal > cfg.calmThreshold or lenC > comfortRadius) then
				aliX = avgRx / lenA
				aliZ = avgRz / lenA
				aliW = cfg.alignmentWeight * (0.3 + 0.7 * self.arousal)
			end
		end
	end

	-- In-place grazing. The animal stands still and plays its species
	-- graze clip (head-down eating motion) via the idle branch in
	-- AnimalAnimation when isGrazing is true and a graze state exists
	-- in the cache. No wandering — the previous "pick a random graze
	-- target and walk to it" behaviour was producing short walk cycles
	-- that interrupted the animation and drifted the herd around the pen.
	-- Grazing is suppressed during dog herding so calm animals don't drift
	-- back to the feed area when the dog is out of range.
	if self.arousal < cfg.calmThreshold and nearest == nil and not self.dogHerdingActive then
		self.isGrazing = true
	else
		self.isGrazing = false
	end
	self.grazeTarget = nil

	-- STAGE D: Blend & decide

	-- Pre-flee gaze: face away, no translation
	if self.gazeTimer > 0 and self.arousal < 0.85 and self.lastThreatDir ~= nil then
		local dy = math.atan2(self.lastThreatDir.x, self.lastThreatDir.z)
		state.isIdle = true
		state.isTurning = not (self.rotation.y <= dy + 0.05 and self.rotation.y >= dy - 0.05)
		state.targetDirY = dy
		self.herdingTarget.distance = cfg.walkDistance + 1
		self.herdingTarget.followingBucket = false
		self.isGrazing = false
		if updateTerrain then self:updateTerrainHeight() end
		return
	end

	-- Flee branch (panic)
	if self.arousal >= cfg.startleThreshold and nearest ~= nil then

		self.isGrazing = false

		local sx = fleeX * fleeW + aliX * aliW + sepX * sepW
		local sz = fleeZ * fleeW + aliZ * aliW + sepZ * sepW
		local slen = math.sqrt(sx * sx + sz * sz)
		if slen > 0.0001 then
			sx = sx / slen
			sz = sz / slen
		else
			sx, sz = fleeX, fleeZ
		end

		local dy = math.atan2(sx, sz)
		local dist = nearest.dist

		self.herdingTarget = {
			ry = dy, distance = dist, followingBucket = false,
			dx = x - nearest.px, dz = z - nearest.pz,
			x = x, z = z, ax = nearest.px, az = nearest.pz
		}

		-- When a stuck-escape is in progress (the animal is pinned against
		-- a fence/wall with a front collision) the update() flow has set
		-- state.targetDirY to an escape heading (husbandry center, or a
		-- 90° rotation to a clear side). The flee branch must not
		-- overwrite that — otherwise the animal keeps rotating back
		-- toward the threat, walking straight into the wall again, and
		-- the escape never completes. Once the escape turn clears the
		-- collision, stuckEscaping resets and the flee direction is
		-- allowed through again.
		if not self.stuckEscaping then
			-- Player-vicinity block is only applied when the NEAREST threat is
			-- a real one (player / vehicle / dog). During dog herding each
			-- animal also gets a synthetic guide influencer at 5 m — if that
			-- guide is the nearest, the flee direction is coming from a
			-- directional pull, not from the player, so the player happening
			-- to stand near the animal shouldn't toggle isTurning off. That
			-- toggling produced a visible turn-clip flicker as the player
			-- moved around the herd.
			local blockForPlayer = self.collisionController:getHasPlayerInVicinity()
				and not (nearest ~= nil and nearest.isGuide)

			if dist > cfg.turnDistance or (self.rotation.y <= dy + 0.05 and self.rotation.y >= dy - 0.05) or blockForPlayer then
				state.isTurning = false
				state.targetDirY = self.rotation.y
			else
				state.isTurning = true
				state.targetDirY = dy
			end
		end

		if dist < cfg.walkDistance and state.isIdle then self.startWalking = true end

		if updateTerrain then self:updateTerrainHeight() end
		return

	end

	-- Lingering alert: face last threat direction, maybe drift slowly with flock
	if self.alertTimer > 0 and self.lastThreatDir ~= nil then

		self.isGrazing = false

		local dy = math.atan2(self.lastThreatDir.x, self.lastThreatDir.z)

		local sx = cohX * cohW + aliX * aliW + sepX * sepW
		local sz = cohZ * cohW + aliZ * aliW + sepZ * sepW
		local slen = math.sqrt(sx * sx + sz * sz)

		if slen > 0.3 then
			local sdy = math.atan2(sx, sz)
			self.herdingTarget = {
				ry = sdy, distance = cfg.walkDistance - 1, followingBucket = false,
				dx = sx, dz = sz, x = x, z = z, ax = x + sx, az = z + sz
			}
			state.targetDirY = sdy
			state.isTurning = not (self.rotation.y <= sdy + 0.05 and self.rotation.y >= sdy - 0.05)
			if state.isIdle then self.startWalking = true end
		else
			state.targetDirY = dy
			state.isTurning = not (self.rotation.y <= dy + 0.05 and self.rotation.y >= dy - 0.05)
			self.herdingTarget.distance = cfg.walkDistance + 1
			self.herdingTarget.followingBucket = false
			state.isIdle = true
		end

		if updateTerrain then self:updateTerrainHeight() end
		return

	end

	-- Calm fall-through. Grazing animals stay put and play the graze clip
	-- (AnimalAnimation's idle branch swaps to the graze state when
	-- self.isGrazing is true). Non-grazing calm animals still follow
	-- flock + separation forces so cohesion/separation continue to tidy
	-- the herd.
	if self.isGrazing then
		state.isIdle = true
		state.isWalking = false
		state.isRunning = false
		self.herdingTarget.distance = cfg.walkDistance + 1
		self.herdingTarget.followingBucket = false
	else
		local sx = cohX * cohW + aliX * aliW + sepX * sepW
		local sz = cohZ * cohW + aliZ * aliW + sepZ * sepW
		local slen = math.sqrt(sx * sx + sz * sz)

		if slen > 0.1 then
			local dy = math.atan2(sx, sz)
			self.herdingTarget = {
				ry = dy, distance = cfg.walkDistance - 1, followingBucket = false,
				dx = sx, dz = sz, x = x, z = z, ax = x + sx, az = z + sz
			}
			state.targetDirY = dy
			state.isTurning = not (self.rotation.y <= dy + 0.05 and self.rotation.y >= dy - 0.05)
			if state.isIdle then self.startWalking = true end
		else
			state.isIdle = true
			self.herdingTarget.distance = cfg.walkDistance + 1
			self.herdingTarget.followingBucket = false
		end
	end

	if updateTerrain then self:updateTerrainHeight() end

end


function HerdableAnimal:updateTerrainHeight(updateY)

	local terrainH = getTerrainHeightAtWorldPos(g_terrainNode, self.position.x, 0, self.position.z) + 0.01

	-- Apply the surface height found by the most recent async raycast.
	-- We deliberately don't clear surfaceRaycastHitY before re-firing — the
	-- previous valid hit stays in place during the 1-2 tick async window so
	-- transitions onto/off elevated surfaces (e.g. shed flooring on Witcombe)
	-- don't briefly fall back to terrain height and snap the cow vertically.
	-- A new callback simply overwrites the field with the latest hit.
	if self.surfaceRaycastHitY ~= nil and self.surfaceRaycastHitY > terrainH then
		self.terrainHeight = self.surfaceRaycastHitY + 0.01
		self.onElevatedSurface = true
	else
		self.terrainHeight = terrainH
		self.onElevatedSurface = false
	end

	-- Fire a fresh downward scan. Async = non-blocking; multiple in-flight
	-- raycasts just overwrite the same field. Ray starts 3 m above terrain
	-- and shoots down; first hit = topmost walkable surface.
	raycastAllAsync(self.position.x, terrainH + 3.0, self.position.z, 0, -1, 0, 3.0, "onSurfaceHeightRaycast", self, CollisionFlag.STATIC_OBJECT + CollisionFlag.ROAD)

	if updateY then self.position.y = self.position.y > self.terrainHeight and self.position.y or self.terrainHeight end

end


function HerdableAnimal:onSurfaceHeightRaycast(hitObjectId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId, isLast)

	-- Skip this animal's own physics proxy
	if self.collisionController ~= nil and hitObjectId == self.collisionController.proxy then return end

	-- First valid hit descending from above is the topmost walkable surface — store and stop
	self.surfaceRaycastHitY = y
	return false

end


function HerdableAnimal:forceNewState()

	local state = self.state

	if state.followingPath then return end

	if state.isIdle then
		state.isIdle = false
		state.wasIdle = true
	elseif state.isWalking then
		state.isIdle = true
		state.wasWalking = true
		state.isWalking = false
		state.isTurning = false
		state.targetDirY = 0
	elseif state.isRunning then
		state.isIdle = false
		state.wasWalking = false
		state.isWalking = true
		state.isRunning = false
		state.wasRunning = true
	end

	self.animation:setState(self.state)

end


function HerdableAnimal:setIsWalking(value)

	self.state.isWalking = value
	self.state.wasWalking = not value

end


function HerdableAnimal:setIsRunning(value)

	self.state.isRunning = value
	self.state.wasRunning = not value

end


function HerdableAnimal:setIsIdle(value)

	self.state.isIdle = value
	self.state.wasIdle = not value

end


function HerdableAnimal:setIsTurning(value)

	self.state.isTurning = value

end


function HerdableAnimal:showInfo(box)

	box:setTitle(g_i18n:getText("ahl_herdedAnimal", modName))
	self.cluster:showInfo(box)

end


function HerdableAnimal:visualise()

	local info = {
		{ ["title"] = "Player Response", ["content"] = {} },
		{ ["title"] = "Movement", ["content"] = {} }
	}

	for key, value in pairs(self.herdingTarget) do table.insert(info[1].content, { ["sizeFactor"] = 0.7, ["name"] = key .. " = ", ["value"] = tostring(value) }) end

	local stepX, _, stepZ = localDirectionToWorld(self.nodes.root, 0, 0, 1)

	table.insert(info[2].content, { ["sizeFactor"] = 0.7, ["name"] = "stepX = ", ["value"] = tostring(stepX) })
	table.insert(info[2].content, { ["sizeFactor"] = 0.7, ["name"] = "stepZ = ", ["value"] = tostring(stepZ) })

	self.animation:visualise(self.nodes.root, info)
	self.collisionController:visualise(info, self.position.x, self.position.y + 0.15, self.position.z, self.rotation.x, self.rotation.y, self.rotation.z)
	table.insert(info[#info].content, { ["sizeFactor"] = 0.7, ["name"] = "lastStuckTurn = ", ["value"] = tostring(self.lastStuckTurn) })

	local infoTable = DebugInfoTable.new()
	infoTable:createWithNodeToCamera(self.nodes.root, info, 1, 0.05)
	g_debugManager:addFrameElement(infoTable)

end


function HerdableAnimal:visualiseCollisionInfo()

	self.collisionController:updateDiscoveryProbe(self.position.x, self.position.y, self.position.z)

	local info = {}
	self.collisionController:addCollisionDebugInfo(info)

	local infoTable = DebugInfoTable.new()
	infoTable:createWithNodeToCamera(self.nodes.root, info, 1, 0.05)
	g_debugManager:addFrameElement(infoTable)

end