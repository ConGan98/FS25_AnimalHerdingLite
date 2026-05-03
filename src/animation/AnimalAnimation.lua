AnimalAnimation = {}


local AnimalAnimation_mt = Class(AnimalAnimation)


function AnimalAnimation.new(animal, animationSet, animationCache)

	local self = setmetatable({}, AnimalAnimation_mt)

	self.animal = animal
	self.animationSet = animationSet
	self.cache = animationCache
	self.tracks = {}
	self.speedModifiers = {}

	self.currentAnimationTime = 0
	self.targetAnimationTime = 10000

	-- animationSet can be 0 / nil if the source i3d failed to load or has no
	-- skeleton. Calling setAnimTrackLoopState on a bad set crashes the engine;
	-- skip the loop init so the rest of the animation plumbing can degrade
	-- gracefully (tracks won't play but the animal still moves).
	if animationSet ~= nil and animationSet ~= 0 then
		setAnimTrackLoopState(animationSet, 0, true)
		setAnimTrackLoopState(animationSet, 1, true)
		setAnimTrackLoopState(animationSet, 2, true)
		setAnimTrackLoopState(animationSet, 3, true)
	end

	self.currentAnimationTime = 0

	return self

end


function AnimalAnimation:setDefaultState()

	self.state = {
		["isIdle"] = true,
		["isWalking"] = false,
		["isRunning"] = false,
		["isTurning"] = false,
		["dirY"] = 0,
		["targetDirY"] = 0
	}

end


function AnimalAnimation:setState(state)

	self.state = state

end


function AnimalAnimation:update(dT, isWalkingFromPlayer)

	self.currentAnimationTime = self.currentAnimationTime + dT

	local state = self.state
	local animationSet = self.animationSet
	local speedModifiers = self.speedModifiers

	local dirChange = state.dirY - state.lastDirY
	self.turnDirection = dirChange > 0 and "left" or (dirChange < 0 and "right" or "none")

	if self.transition ~= nil then

		local transition = self.transition
		local targetTime = transition.targetTime
		local blendTime = transition.blendTime

		transition.currentTime = transition.currentTime - dT

		local currentTime = transition.currentTime

		if (currentTime <= targetTime and currentTime < blendTime) or (currentTime >= targetTime and currentTime > blendTime) then

			-- Remove the from tracks from self.tracks (they shared the
			-- animation-set track indices with the live tracks, not a
			-- separate fresh install). Setting to nil drops them out of
			-- getMovementSpeed iteration and the state branches below.
			for _, track in pairs(transition.from) do
				disableAnimTrack(animationSet, track.index)
				track.enabled = false
				self.tracks[track.index] = nil
			end

			for _, track in pairs(transition.to) do
				track.blend = 1 / #transition.to
				setAnimTrackBlendWeight(animationSet, track.index, track.blend)
				self.tracks[track.index] = table.clone(track, 5)
			end

			local idTo = transition.to[1].id

			if idTo == "walk" then

				self.animal:setIsWalking(true)
				self.animal:setIsIdle(false)

			elseif idTo == "idle" then

				self.animal:setIsWalking(false)
				self.animal:setIsTurning(false)
				self.animal:setIsIdle(true)

			end

			self.transition = nil
			self.currentAnimationTime = 0

			return

		end

		-- blend goes 1 → 0 over the transition duration. From tracks fade
		-- from their captured initialBlend down to 0 (preserving their
		-- relative weight ratio — e.g. an L/R pair keeps its turn-bias
		-- split intact during fade-out). To tracks fade 0 → 1/#to.
		local blend = (currentTime - targetTime) / blendTime

		for _, track in pairs(transition.from) do
			track.blend = blend * (track.initialBlend or (1 / #transition.from))
			setAnimTrackBlendWeight(animationSet, track.index, track.blend)
		end

		for _, track in pairs(transition.to) do
			track.blend = (1 - blend) / #transition.to
			setAnimTrackBlendWeight(animationSet, track.index, track.blend)
		end

		transition.blend = blend

	else

		--if self.currentAnimationTime >= self.targetAnimationTime and not isWalkingFromPlayer then
			--print("0")
			--self.animal:forceNewState()
			--state = self.state
			--self.currentAnimationTime = 0
			--dirChange = state.dirY - state.lastDirY
			--self.turnDirection = dirChange > 0 and "left" or (dirChange < 0 and "right" or "none")
		--end

		-- Pure in-place turn: animal is idle and yaw-lerping toward a target
		-- direction. Play the matching turn clip (45/90/135/180° bucket, left
		-- or right) instead of the idle pose so the legs animate. Turn clips
		-- have distance=0 so getMovementSpeed returns 0 — the yaw lerp in
		-- HerdableAnimal keeps driving the actual rotation. We key off
		-- state.inPureTurn (set by HerdableAnimal's persistent pure-turn
		-- gate) rather than state.isTurning — the turn block in update()
		-- clears isTurning whenever rotation reaches the ±0.05 rad target
		-- window, which made the turn branch flip out on single frames and
		-- the idle branch disable the turn track every other tick (the
		-- visible flicker). When inPureTurn clears, the idle branch below
		-- disables the turn track and installs the idle clip.
		if state.inPureTurn and state.isIdle and self.cache.hasTurnStates then

			-- Once a turn clip is playing, leave it alone until pure-turn
			-- mode exits. state.targetDirY can be transiently cleared to 0
			-- by the turn block in HerdableAnimal (when rotation enters
			-- the ±0.05 rad window), which would make pickTurnSide return
			-- the wrong side and cause a left↔right install swap flicker.
			if self:isPlayingTurnClip() then
				state.lastDirY = state.dirY
				return
			end

			local side = self:pickTurnSide(state)
			local animation = self:pickTurnAnimation(side, state)

			if animation ~= nil then
				self:ensureTurnTrack(side, animation)
				state.lastDirY = state.dirY
				return
			end

		end

		local names = self.animal.animNames

		if state.isIdle and state.wasWalking then

			state.wasWalking = false
			self:startTransition("walk", "idle", names.walk, names.idle)

		elseif state.isWalking and state.wasIdle then

			state.wasIdle = false
			self:startTransition("idle", "walk", names.idle, names.walk)

		elseif state.isRunning and state.wasWalking then

			state.wasWalking = false
			self:startTransition("walk", "run", names.walk, names.run)

		elseif state.isWalking and state.wasRunning then

			state.wasRunning = false
			self:startTransition("run", "walk", names.run, names.walk)

		elseif state.isIdle and state.wasRunning then

			state.wasRunning = false
			self:startTransition("run", "idle", names.run, names.idle)

		elseif state.isIdle then

			-- Calm-behavior cycler picks the desired idle-branch state per
			-- animal: graze / eat / chew / idle, rotated on a per-animal
			-- timer (CalmBehaviorCycler). Falls back to "idle" if the
			-- selected state isn't in this species' cache.
			local desiredId = "idle"
			local cb = self.animal and self.animal.calmBehavior
			if cb ~= nil and self.cache.states ~= nil and self.cache.states[cb.id] ~= nil then
				desiredId = cb.id
			end

			-- Smooth exit from a turn clip (or a mismatched idle state like
			-- graze→idle). If a non-desired track is playing, start a
			-- transition to the desired state instead of hard-cutting.
			-- startTransition now preserves the from track's playback
			-- position, so the swap is a proper crossfade.
			local otherTrack
			for _, track in pairs(self.tracks) do
				if track.enabled and track.id ~= desiredId then
					otherTrack = track
					break
				end
			end
			if otherTrack ~= nil then
				local fromAnimId = otherTrack.animationId or otherTrack.id .. "1"
				-- Default to "<state>1" — startTransition falls back to
				-- getRandomAnimation if the named clip isn't in the cache,
				-- so unusual variant names (eat = feedSource etc.) still
				-- resolve correctly.
				local toAnimId = desiredId .. "1"
				self:startTransition(otherTrack.id, desiredId, fromAnimId, toAnimId)
				state.lastDirY = state.dirY
				return
			end

			local hasTrack = false

			for i, track in pairs(self.tracks) do

				if track.enabled and track.id ~= desiredId then

					disableAnimTrack(animationSet, i)
					track.enabled = false

				elseif track.enabled then

					hasTrack = true

				end

			end

			if not hasTrack then

				local animation = self:getRandomAnimation(desiredId)
				if animation == nil or animation.clip == nil then
					animation = self:getRandomAnimation("idle")
				end
				if animation == nil or animation.clip == nil then return end

				self.tracks[0] = {
					["id"] = desiredId,
					["clip"] = animation.clip,
					["blend"] = 1,
					["enabled"] = true,
					["speed"] = 0
				}

				assignAnimTrackClip(animationSet, 0, animation.clip.index)
				setAnimTrackBlendWeight(animationSet, 0, 1)
				enableAnimTrack(animationSet, 0)
				setAnimTrackSpeedScale(animationSet, 0, 1)
				self:invalidatePlaybackSpeedCache(desiredId .. "-install")

				self.currentAnimationTime = 0
				self.targetAnimationTime = self:getTargetAnimationDuration("idle")

			end

		elseif state.isWalking or state.isRunning then

			local targetId = state.isWalking and "walk" or "run"
			-- speedId drives which speedModifier/override is used for playback rate and
			-- movement speed.  When there is no run animation we reuse walk clips but
			-- still apply the run speed modifier so the legs and body both move at run
			-- speed (young/baby sheep have no dedicated run clip).
			local speedId = targetId
			if targetId == "run" and self.cache.states.run == nil then targetId = "walk" end
			local hasTrack = false
			local track1, track2

			for i, track in pairs(self.tracks) do

				if track.enabled and track.id ~= targetId then

					disableAnimTrack(animationSet, i)
					track.enabled = false

				elseif track.enabled then

					hasTrack = true

					-- Keep speedId current so a walk→run transition (no run state) bumps
					-- the animation playback rate and movement speed to the run modifier.
					if track.speedId ~= speedId then
						track.speedId = speedId
						setAnimTrackSpeedScale(animationSet, i, speedModifiers[speedId] or 1)
					end

					if track.clip.type == "clipLeft" then track1 = track end
					if track.clip.type == "clipRight" then track2 = track end

				end

			end

			if not hasTrack then

				local animation = self:getRandomAnimation(targetId)

				self.tracks[0] = {
					["id"] = targetId,
					["speedId"] = speedId,
					["clip"] = animation.clipLeft,
					["blend"] = 0.5,
					["enabled"] = true,
					["speed"] = animation.speed
				}

				self.tracks[1] = {
					["id"] = targetId,
					["speedId"] = speedId,
					["clip"] = animation.clipRight,
					["blend"] = 0.5,
					["enabled"] = true,
					["speed"] = animation.speed
				}

				track1 = self.tracks[0]
				track2 = self.tracks[1]

				assignAnimTrackClip(animationSet, 0, animation.clipLeft.index)
				setAnimTrackBlendWeight(animationSet, 0, 0.5)
				enableAnimTrack(animationSet, 0)
				setAnimTrackSpeedScale(animationSet, 0, speedModifiers[speedId] or 1)

				assignAnimTrackClip(animationSet, 1, animation.clipRight.index)
				setAnimTrackBlendWeight(animationSet, 1, 0.5)
				enableAnimTrack(animationSet, 1)
				setAnimTrackSpeedScale(animationSet, 1, speedModifiers[speedId] or 1)
				self:invalidatePlaybackSpeedCache(targetId .. "-install")

				self.currentAnimationTime = 0
				self.targetAnimationTime = self:getTargetAnimationDuration(targetId)

			end
			
			if self.turnDirection == "left" then

				track1.blend = math.clamp(track1.blend + dT * 0.0005, 0, 1)
				track2.blend = math.clamp(track2.blend - dT * 0.0005, 0, 1)

			elseif self.turnDirection == "right" then

				track1.blend = math.clamp(track1.blend - dT * 0.0005, 0, 1)
				track2.blend = math.clamp(track2.blend + dT * 0.0005, 0, 1)

			else

				if track1.blend < 0.5 then
					track1.blend = math.clamp(track1.blend + dT * 0.0005, 0, 0.5)
				else
					track1.blend = math.clamp(track1.blend - dT * 0.0005, 0.5, 1)
				end

				if track2.blend < 0.5 then
					track2.blend = math.clamp(track2.blend + dT * 0.0005, 0, 0.5)
				else
					track2.blend = math.clamp(track2.blend - dT * 0.0005, 0.5, 1)
				end

			end
			
			setAnimTrackBlendWeight(animationSet, 0, track1.blend)
			setAnimTrackBlendWeight(animationSet, 1, track2.blend)

		end

	end

	state.lastDirY = state.dirY

end


local ALTERNATE_NAMES = {
	["walk1"] = "walk01", ["walk01"] = "walk1",
	["run1"] = "run01", ["run01"] = "run1",
	["idle1"] = "idle01", ["idle01"] = "idle1",
	["walk2"] = "walk02", ["walk02"] = "walk2",
	["run2"] = "run02", ["run02"] = "run2",
	["idle2"] = "idle02", ["idle02"] = "idle2",
}


function AnimalAnimation:getRandomAnimation(id)

	local state = self.cache.states[id]

	if state == nil then return nil end

	if state[id] ~= nil then return state[id] end
	if state[id .. "1"] ~= nil then return state[id .. "1"] end
	if state[id .. "01"] ~= nil then return state[id .. "01"] end

	local numAnimations = 0

	for _, animation in pairs(state) do numAnimations = numAnimations + 1 end

	-- Per-animal deterministic variant pick. The previous math.random call
	-- meant two animals installing the same state on the same tick both got
	-- the same variant index — visible synchronisation on the few states
	-- with multiple variants (pig idle1/idle2, horse, chicken). Hash from
	-- (animal id, 5-second time bucket) so animals desync from each other
	-- AND each animal still varies its variant choice over time.
	local animId = (self.animal and self.animal.id) or 0
	local timeBucket = math.floor((g_time or 0) / 5000)
	local h = (animId * 2654435761 + timeBucket * 374761393) % 2147483647
	local randomAnimation = (h % numAnimations) + 1

	local i = 1

	for _, animation in pairs(state) do

		if i == randomAnimation then return animation end

		i = i + 1

	end

	return nil

end


-- Signed angle delta (state.targetDirY - state.dirY) normalised to [-π, π].
-- Positive → turn left (CCW), negative → turn right (CW). "left"/"right"
-- strings map to the turnBucket side keys built by the XML loader.
function AnimalAnimation:pickTurnSide(state)

	local da = (state.targetDirY or 0) - (state.dirY or 0)
	while da >   math.pi do da = da - 2 * math.pi end
	while da <= -math.pi do da = da + 2 * math.pi end
	return da >= 0 and "left" or "right"

end


-- Pick the smallest bucket entry whose rotation (degrees) covers the
-- remaining angle. Falls back to the largest bucket (180°/190°) when the
-- remaining angle exceeds every entry. Returns the animation cache entry
-- (with .clip and .speed) or nil if no buckets exist for this side.
function AnimalAnimation:pickTurnAnimation(side, state)

	local buckets = self.cache.turnBuckets and self.cache.turnBuckets[side]
	if buckets == nil or #buckets == 0 then return nil end

	local da = (state.targetDirY or 0) - (state.dirY or 0)
	while da >   math.pi do da = da - 2 * math.pi end
	while da <= -math.pi do da = da + 2 * math.pi end
	local deg = math.abs(math.deg(da))

	for _, b in ipairs(buckets) do
		if b.rotation >= deg then return b.anim end
	end
	return buckets[#buckets].anim

end


-- Install a turn clip on track 0 (single-clip state, no L/R pair). If the
-- requested animation is already the active turn track, do nothing — swapping
-- clips mid-turn looks twitchy. All other tracks are disabled so the pure
-- pose plays cleanly.
--
-- track.speed is stored as 0 so getMovementSpeed returns 0 during the turn
-- (turn clips have distance=0 — the yaw lerp in HerdableAnimal still drives
-- actual rotation; this clip just animates the body).
-- setAnimTrackSpeedScale uses animation.speed from the XML so horse turn
-- clips (which reuse one 45° clip at speed 2.0/3.0/4.0 for larger buckets)
-- play at the correct playback rate.
-- Returns true if a turnLeft/turnRight track is currently active on this
-- animal. Used by HerdableAnimal's force-idle gate to hysteresis through
-- the turnInPlaceMinDeg threshold — once the turn clip is playing, stay
-- in pure-turn mode until the yaw lerp actually completes and the track
-- is disabled, rather than dropping out the moment the remaining angle
-- crosses 29.9° and re-entering at 30.1°.
function AnimalAnimation:isPlayingTurnClip()

	for _, track in pairs(self.tracks) do
		if track.enabled and (track.id == "turnLeft" or track.id == "turnRight") then
			return true
		end
	end
	return false

end


function AnimalAnimation:ensureTurnTrack(side, animation)

	local animationSet = self.animationSet
	local stateId = side == "left" and "turnLeft" or "turnRight"
	local clip = animation.clip
	if clip == nil then return end

	-- Keep any currently-playing turn clip for the same side even if the
	-- bucket selection would now pick a smaller angle. Swapping clips
	-- mid-turn resets the new clip to frame 0 — visible as a pose snap
	-- / flicker as the animal crosses bucket boundaries (e.g. remaining
	-- angle drops from 91° to 89° crossing the 90° bucket). Same-side is
	-- enough to keep the visual smooth; the yaw lerp in HerdableAnimal
	-- is what actually drives world rotation regardless of which clip's
	-- nominal angle is playing.
	for i, track in pairs(self.tracks) do
		if track.enabled and track.id == stateId then
			return
		end
	end

	-- If a different track (idle / walk / etc) is currently playing, do
	-- a proper crossfade transition into the turn clip instead of a hard
	-- cut. startTransition preserves the currently-playing clip at its
	-- current frame and fades its blend weight down while the turn clip
	-- fades in — no visible pose snap.
	for _, track in pairs(self.tracks) do
		if track.enabled then
			local fromAnimId = track.animationId or (track.id .. "1")
			self:startTransition(track.id, stateId, fromAnimId, animation.id)
			return
		end
	end

	-- No track currently enabled (fresh state). Direct install.
	self.tracks[0] = {
		["id"] = stateId,
		["animationId"] = animation.id,
		["clip"] = clip,
		["blend"] = 1,
		["enabled"] = true,
		["speed"] = 0
	}

	assignAnimTrackClip(animationSet, 0, clip.index)
	setAnimTrackBlendWeight(animationSet, 0, 1)
	enableAnimTrack(animationSet, 0)
	setAnimTrackSpeedScale(animationSet, 0, animation.speed or 1)
	self:invalidatePlaybackSpeedCache(stateId .. "-install")

	self.currentAnimationTime = 0

end


-- Rescale every enabled track's playback rate to `scale × speedModifier[state]`.
-- HerdableAnimal calls this each tick with `scale = actualWorldMps / targetMps`
-- so the visible animation stays locked to actual body translation, even when
-- self.speed is ramp-clamped during walk↔run transitions or grazeSpeedScalar
-- is halving the translation. Without this, feet animate at nominal clip
-- rate while the body moves slower — visible moonwalk / skating.
function AnimalAnimation:setPlaybackSpeedScale(scale)

	-- Only re-apply when the scale changed meaningfully. Per-frame
	-- setAnimTrackSpeedScale calls are cheap but appear to cause subtle
	-- clip-phase artifacts on some engine builds ("walk clip played fast
	-- and then cut off"). A 2% deadband avoids unnecessary updates for
	-- noise while still tracking genuine speed changes. Track-install
	-- paths (ensureTurnTrack, walk/run install, idle install, startTransition)
	-- self-invalidate by calling setPlaybackSpeedScaleForceRefresh at the
	-- end of the frame — but the cheap path is the common one.
	if self._lastPlaybackScale ~= nil then
		local delta = scale - self._lastPlaybackScale
		if delta > -0.02 and delta < 0.02 then return end
	end
	self._lastPlaybackScale = scale
	local animationSet = self.animationSet
	local speedModifiers = self.speedModifiers
	for i, track in pairs(self.tracks) do
		if track.enabled then
			local modId = track.speedId or track.id
			local baseMod = speedModifiers[modId] or 1
			setAnimTrackSpeedScale(animationSet, i, baseMod * scale)
		end
	end

end


-- Called by track-install paths to force the next setPlaybackSpeedScale
-- call to re-apply (since the newly-installed track has scale=baseMod,
-- which corresponds to playbackScale=1.0, and the animal may currently
-- be at a different scale due to the speed ramp).
--
-- callSite (optional string) identifies which install path triggered this
-- — used by the movement-debug log so we can see the sequence that
-- produces a red (high install-rate) overlay.
function AnimalAnimation:invalidatePlaybackSpeedCache(callSite)

	self._lastPlaybackScale = nil

	-- Instrumentation for the movement debug overlay — record each track
	-- (re)install with timestamp + caller so we can diagnose animation flicker.
	local now = g_time or 0
	self._mdbgInstallTimes = self._mdbgInstallTimes or {}
	self._mdbgInstallSites = self._mdbgInstallSites or {}
	table.insert(self._mdbgInstallTimes, now)
	table.insert(self._mdbgInstallSites, callSite or "?")

	-- If the install rate is in the red zone (>1.5/s over a 2 s window),
	-- emit a single line capturing the most recent install sequence and
	-- the animal's current state flags. Rate-limit per-animal so we don't
	-- spam the log (at most once per second).
	if g_animalManager ~= nil and g_animalManager.movementDebugEnabled then
		-- Trim window to last 2 s.
		while #self._mdbgInstallTimes > 0 and now - self._mdbgInstallTimes[1] > 2000 do
			table.remove(self._mdbgInstallTimes, 1)
			table.remove(self._mdbgInstallSites, 1)
		end
		local count = #self._mdbgInstallTimes
		-- Log threshold raised above the natural install rate for a short
		-- walk session (idle-install → trans-idle→walk → trans-walk→idle,
		-- which is 3 installs in ~1-2 s for quick graze cycles). Real
		-- flicker from an install-loop produces 5+ installs in 2 s.
		if count >= 5 then
			local lastLog = self._mdbgLastLogTime or 0
			if now - lastLog > 1000 then
				self._mdbgLastLogTime = now
				local state = self.state or {}
				local flags = {}
				if state.isIdle    then table.insert(flags, "I") end
				if state.isWalking then table.insert(flags, "W") end
				if state.isRunning then table.insert(flags, "R") end
				if state.isTurning then table.insert(flags, "T") end
				local stateStr = table.concat(flags, "")
				if stateStr == "" then stateStr = "-" end

				local seq = {}
				for i = math.max(1, count - 5), count do
					table.insert(seq, self._mdbgInstallSites[i] or "?")
				end

				local animalTag = "animal"
				if self.animal ~= nil then
					if self.animal.visualAnimalIndex ~= nil then
						animalTag = string.format("a#%d", self.animal.visualAnimalIndex)
					end
					if self.animal.animalTypeIndex ~= nil and g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
						local at = g_currentMission.animalSystem:getTypeByIndex(self.animal.animalTypeIndex)
						if at ~= nil and at.name ~= nil then
							animalTag = string.format("%s(%s)", at.name, animalTag)
						end
					end
				end

				Logging.info("[AHL movement] %s installs=%.1f/s state=%s sequence: %s",
					animalTag, count / 2, stateStr, table.concat(seq, " → "))
			end
		end
	end

end


function AnimalAnimation:setStateSpeedOverride(stateId, speed)

	if self.stateSpeedOverrides == nil then self.stateSpeedOverrides = {} end
	self.stateSpeedOverrides[stateId] = speed

end


function AnimalAnimation:getMovementSpeed()

	local speed, numTracks = 0, 0
	local speedModifiers = self.speedModifiers
	local overrides = self.stateSpeedOverrides

	-- Single accumulation loop. During a transition, both transition.to and
	-- transition.from track sets contribute weighted by their blend; outside
	-- a transition, only self.tracks is active. The body of each iteration
	-- is identical, so factor into a small helper local instead of repeating
	-- it across two/three loops.
	local function accumulate(trackSet)
		for _, track in pairs(trackSet) do
			if track.enabled then
				local modId = track.speedId or track.id
				local trackSpeed = (overrides and overrides[modId]) or track.speed
				speed = speed + trackSpeed * track.blend * (speedModifiers[modId] or 1)
				numTracks = numTracks + 1
			end
		end
	end

	if self.transition == nil then
		accumulate(self.tracks)
	else
		accumulate(self.transition.to)
		accumulate(self.transition.from)
	end

	if numTracks == 0 then return 0 end

	return math.clamp(speed, 0, 6)

end


-- Smooth crossfade from the currently-playing clips into a new state's
-- clips. KEY POINT: the from tracks are NOT re-installed — they keep
-- playing at their current frame position. We capture their existing
-- track indices + clips into transition.from and just ramp their blend
-- weight down over blendTime. The to clips are installed on FRESH track
-- indices (next free after the from tracks), assigned at frame 0, with
-- initial blend weight 0 and ramped up.
--
-- Previously startTransition disabled all live tracks and re-assigned the
-- exact same clips to fresh indices, which reset them to frame 0 — a
-- walking animal would visually snap back to the standing-start pose at
-- the moment the transition started, before the blend began. That was
-- the "hard" look on transitions the user described.
function AnimalAnimation:startTransition(stateIdFrom, stateIdTo, idFrom, idTo)

	local states = self.cache.states
	if states[stateIdTo] == nil then return end

	local animationTo = states[stateIdTo][idTo] or states[stateIdTo][ALTERNATE_NAMES[idTo]]
	if animationTo == nil then animationTo = self:getRandomAnimation(stateIdTo) end
	if animationTo == nil then return end

	-- animationFrom is used ONLY to look up the XML blendTime for this
	-- from→to pair. Its clip data is irrelevant because we don't install
	-- from clips — the already-playing tracks ARE the "from".
	local animationFrom
	if states[stateIdFrom] ~= nil then
		animationFrom = states[stateIdFrom][idFrom] or states[stateIdFrom][ALTERNATE_NAMES[idFrom]]
	end

	local templateTransition
	if animationFrom ~= nil and animationFrom.transitions ~= nil then
		templateTransition = animationFrom.transitions[idTo]
	end
	if templateTransition == nil then
		templateTransition = { ["targetTime"] = 0, ["blendTime"] = 1000 }
	end

	local speedModifiers = self.speedModifiers

	-- Capture currently-enabled tracks as the "from" set. DO NOT touch
	-- them — their clip playback continues uninterrupted. We preserve the
	-- existing blend weight as initialBlend so the fade-out ramps from
	-- wherever each track was (e.g. an L/R pair with a turn-bias split
	-- keeps that split during the fade).
	local fromTracks = {}
	local usedIndices = {}
	for i, track in pairs(self.tracks) do
		if track.enabled then
			local b = track.blend or 0
			fromTracks[#fromTracks + 1] = {
				["index"] = i,
				["id"] = track.id,
				["speedId"] = track.speedId,
				["clip"] = track.clip,
				["speed"] = track.speed or 0,
				["blend"] = b,
				["initialBlend"] = b,
				["enabled"] = true
			}
			usedIndices[i] = true
		end
	end

	-- Pick fresh indices for the "to" tracks. setAnimTrackLoopState is set
	-- for track slots 0-3 in the constructor, giving us up to 4 slots.
	local MAX_TRACKS = 4
	local function nextFreeIndex()
		for i = 0, MAX_TRACKS - 1 do
			if not usedIndices[i] then
				usedIndices[i] = true
				return i
			end
		end
		return nil
	end

	local toClips = {}
	if animationTo.clipLeft  ~= nil then table.insert(toClips, animationTo.clipLeft)  end
	if animationTo.clipRight ~= nil then table.insert(toClips, animationTo.clipRight) end
	if animationTo.clip      ~= nil then table.insert(toClips, animationTo.clip)      end
	if #toClips == 0 then return end

	local toTracks = {}
	for _, clip in ipairs(toClips) do
		local idx = nextFreeIndex()
		if idx == nil then break end    -- out of tracks; accept fewer to tracks
		toTracks[#toTracks + 1] = {
			["index"] = idx,
			["id"] = stateIdTo,
			["clip"] = clip,
			["speed"] = animationTo.speed or 0,
			["blend"] = 0,
			["enabled"] = true
		}
	end
	if #toTracks == 0 then
		-- No free tracks — would overflow. Evict oldest from track as fallback
		-- (rare; only happens if 4 tracks are already live when a new transition
		-- fires, which shouldn't happen in the current state machine).
		local victim = fromTracks[1]
		if victim == nil then return end
		disableAnimTrack(self.animationSet, victim.index)
		self.tracks[victim.index] = nil
		table.remove(fromTracks, 1)
		local idx = victim.index
		usedIndices[idx] = true
		toTracks[1] = {
			["index"] = idx, ["id"] = stateIdTo, ["clip"] = toClips[1],
			["speed"] = animationTo.speed or 0, ["blend"] = 0, ["enabled"] = true
		}
	end

	-- Assign to clips on their fresh indices. assignAnimTrackClip resets
	-- the clip to frame 0, which is FINE for incoming clips (they weren't
	-- playing before). The from tracks were NOT touched.
	for _, track in ipairs(toTracks) do
		assignAnimTrackClip(self.animationSet, track.index, track.clip.index)
		setAnimTrackBlendWeight(self.animationSet, track.index, 0)
		enableAnimTrack(self.animationSet, track.index)
		setAnimTrackSpeedScale(self.animationSet, track.index, speedModifiers[track.id] or 1)
	end

	self.targetAnimationTime = self:getTargetAnimationDuration(stateIdTo)

	self.transition = {
		["targetTime"] = templateTransition.targetTime,
		["blendTime"] = templateTransition.blendTime,
		["currentTime"] = templateTransition.blendTime,
		["from"] = fromTracks,
		["to"] = toTracks
	}

	self:invalidatePlaybackSpeedCache(string.format("trans-%s→%s", tostring(stateIdFrom), tostring(stateIdTo)))

end


function AnimalAnimation:getTargetAnimationDuration(id)

	if id == "idle" then return math.random(self.cache.idleMin, self.cache.idleMax) end
	if id == "walk" or id == "run" then return math.random(self.cache.wanderMin, self.cache.wanderMax) end

end


function AnimalAnimation:visualise(node, info)

	table.insert(info, { ["title"] = "States", ["content"] = {} })
	local infoIndex = #info

	for state, value in pairs(self.state) do

		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = state .. " = ", ["value"] = tostring(value) })

	end

	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Turning = ", ["value"] = self.turnDirection })

	table.insert(info, { ["title"] = "Animations", ["content"] = {} })
	infoIndex = #info

	for _, track in pairs(self.tracks) do

		if not track.enabled then continue end

		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "State ID = ", ["value"] = track.id })
		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Blend Weight = ", ["value"] = track.blend })
		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Clip = ", ["value"] = track.clip.name })

	end

	if self.transition ~= nil then

		table.insert(info, { ["title"] = "Transition", ["content"] = {} })
		infoIndex = #info

		local transition = self.transition

		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Blend Time = ", ["value"] = transition.blendTime })
		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Target Time = ", ["value"] = transition.targetTime })
		table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Current Time = ", ["value"] = transition.currentTime })

		for _, clip in pairs(transition.from) do

			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Type = ", ["value"] = "FROM" })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "State ID = ", ["value"] = clip.id })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Blend Weight = ", ["value"] = clip.blend })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Clip = ", ["value"] = clip.clip.name })

		end

		for _, clip in pairs(transition.to) do
		
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Type = ", ["value"] = "TO" })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "State ID = ", ["value"] = clip.id })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Blend Weight = ", ["value"] = clip.blend })
			table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "Clip = ", ["value"] = clip.clip.name })

		end

	end

end


function AnimalAnimation:changeSpeedForState(stateId, modifier)

	self.speedModifiers[stateId] = modifier

end