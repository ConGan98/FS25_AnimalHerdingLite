AnimalSounds = {}


-- Per-species vocalisation config. Mirrors what the engine animals.xml
-- defines under <audio yellSoundGroup=...>: a pool of yell samples plus
-- min/max interval ms and a crowd scale (bigger herd = each animal yells
-- more often so the herd-as-a-whole has a sane density). Sample paths use
-- $data which Utils.getFilename resolves against g_currentMission.baseDirectory.
--
-- yellMinMs / yellMaxMs taken straight from the engine XMLs; crowdScale
-- mirrors yellTimerCrowdScale=0.2. range is the audible cull radius —
-- beyond this, we skip the playSample entirely (no point loading audio
-- the listener can't hear).
local SOUND_DEFS = {
	COW = {
		yells = {
			"$data/sounds/animals/cow/anmlCowYell_01.wav",
			"$data/sounds/animals/cow/anmlCowYell_02.wav",
			"$data/sounds/animals/cow/anmlCowYell_03.wav",
			"$data/sounds/animals/cow/anmlCowYell_04.wav",
			"$data/sounds/animals/cow/anmlCowYell_05.wav",
			"$data/sounds/animals/cow/anmlCowYell_06.wav",
			"$data/sounds/animals/cow/anmlCowYell_07.wav",
			"$data/sounds/animals/cow/anmlCowYell_08.wav",
			"$data/sounds/animals/cow/anmlCowYell_09.wav",
			"$data/sounds/animals/cow/anmlCowYell_10.wav",
			"$data/sounds/animals/cow/anmlCowYell_11.wav",
			"$data/sounds/animals/cow/anmlCowYell_12.wav",
			"$data/sounds/animals/cow/anmlCowYell_13.wav",
			"$data/sounds/animals/cow/anmlCowYell_14.wav",
		},
		yellMinMs = 150000, yellMaxMs = 300000, crowdScale = 0.10,
		range = 50, baseVolume = 0.8, pitchVar = 0.03,
		eat = {
			samples = { "$data/sounds/animals/cow/anmlCowEatLoop_01.wav" },
			pulseMinMs = 1800, pulseMaxMs = 2500,
			range = 25, baseVolume = 0.5, pitchVar = 0.05,
		},
		-- Cow uses pig step samples in the engine animals.xml.
		step = {
			samples = {
				"$data/sounds/animals/pig/anmlPigStep_01.wav",
				"$data/sounds/animals/pig/anmlPigStep_02.wav",
				"$data/sounds/animals/pig/anmlPigStep_03.wav",
				"$data/sounds/animals/pig/anmlPigStep_04.wav",
				"$data/sounds/animals/pig/anmlPigStep_05.wav",
				"$data/sounds/animals/pig/anmlPigStep_06.wav",
			},
			walkStepMs = 600, runStepMs = 320,
			range = 20, baseVolume = 0.35, pitchVar = 0.06,
		},
	},
	PIG = {
		yells = {
			"$data/sounds/animals/pig/anmlPigYell_01.wav",
			"$data/sounds/animals/pig/anmlPigYell_02.wav",
			"$data/sounds/animals/pig/anmlPigYell_03.wav",
			"$data/sounds/animals/pig/anmlPigYell_04.wav",
			"$data/sounds/animals/pig/anmlPigYell_05.wav",
			"$data/sounds/animals/pig/anmlPigYell_06.wav",
			"$data/sounds/animals/pig/anmlPigYell_07.wav",
			"$data/sounds/animals/pig/anmlPigYell_08.wav",
		},
		yellMinMs = 150000, yellMaxMs = 300000, crowdScale = 0.10,
		range = 40, baseVolume = 0.7, pitchVar = 0.04,
		eat = {
			samples = { "$data/sounds/animals/pig/anmlPigEatLoop_01.wav" },
			pulseMinMs = 1500, pulseMaxMs = 2200,
			range = 22, baseVolume = 0.5, pitchVar = 0.06,
		},
		step = {
			samples = {
				"$data/sounds/animals/pig/anmlPigStep_01.wav",
				"$data/sounds/animals/pig/anmlPigStep_02.wav",
				"$data/sounds/animals/pig/anmlPigStep_03.wav",
				"$data/sounds/animals/pig/anmlPigStep_04.wav",
				"$data/sounds/animals/pig/anmlPigStep_05.wav",
				"$data/sounds/animals/pig/anmlPigStep_06.wav",
			},
			walkStepMs = 500, runStepMs = 280,
			range = 20, baseVolume = 0.35, pitchVar = 0.06,
		},
	},
	SHEEP = {
		yells = {
			"$data/sounds/animals/sheep/anmlSheepYell_01.wav",
			"$data/sounds/animals/sheep/anmlSheepYell_02.wav",
			"$data/sounds/animals/sheep/anmlSheepYell_03.wav",
			"$data/sounds/animals/sheep/anmlSheepYell_04.wav",
		},
		yellMinMs = 175000, yellMaxMs = 350000, crowdScale = 0.10,
		range = 40, baseVolume = 0.7, pitchVar = 0.04,
		-- Sheep share the cow eat loop in the engine XMLs.
		eat = {
			samples = { "$data/sounds/animals/cow/anmlCowEatLoop_01.wav" },
			pulseMinMs = 1800, pulseMaxMs = 2500,
			range = 22, baseVolume = 0.45, pitchVar = 0.05,
		},
		-- Sheep also reuse pig steps.
		step = {
			samples = {
				"$data/sounds/animals/pig/anmlPigStep_01.wav",
				"$data/sounds/animals/pig/anmlPigStep_02.wav",
				"$data/sounds/animals/pig/anmlPigStep_03.wav",
				"$data/sounds/animals/pig/anmlPigStep_04.wav",
				"$data/sounds/animals/pig/anmlPigStep_05.wav",
				"$data/sounds/animals/pig/anmlPigStep_06.wav",
			},
			walkStepMs = 480, runStepMs = 280,
			range = 18, baseVolume = 0.30, pitchVar = 0.07,
		},
	},
	HORSE = {
		yells = {
			"$data/sounds/animals/horse/anmlHorseNeigh_01.wav",
			"$data/sounds/animals/horse/anmlHorseNeigh_02.wav",
			"$data/sounds/animals/horse/anmlHorseNeigh_03.wav",
			"$data/sounds/animals/horse/anmlHorseNeigh_04.wav",
			"$data/sounds/animals/horse/anmlHorseNeigh_05.wav",
		},
		yellMinMs = 200000, yellMaxMs = 450000, crowdScale = 0.08,
		range = 60, baseVolume = 0.7, pitchVar = 0.03,
		eat = {
			samples = { "$data/sounds/animals/horse/anmlHorseEatIdle_01.wav" },
			pulseMinMs = 2000, pulseMaxMs = 3000,
			range = 25, baseVolume = 0.4, pitchVar = 0.04,
		},
		-- Horse uses dedicated grass step samples (8 variants).
		step = {
			samples = {
				"$data/sounds/animals/horse/anmlHorseStepGrass_01.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_02.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_03.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_04.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_05.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_06.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_07.wav",
				"$data/sounds/animals/horse/anmlHorseStepGrass_08.wav",
			},
			walkStepMs = 550, runStepMs = 250,
			range = 25, baseVolume = 0.40, pitchVar = 0.05,
		},
	},
	CHICKEN = {
		yells = {
			"$data/sounds/animals/chicken/anmlHenYell_01.wav",
			"$data/sounds/animals/chicken/anmlHenYell_02.wav",
			"$data/sounds/animals/chicken/anmlHenYell_03.wav",
			"$data/sounds/animals/chicken/anmlHenYell_04.wav",
			"$data/sounds/animals/chicken/anmlHenYell_05.wav",
			"$data/sounds/animals/chicken/anmlHenYell_06.wav",
			"$data/sounds/animals/chicken/anmlHenYell_07.wav",
			"$data/sounds/animals/chicken/anmlHenYell_08.wav",
			"$data/sounds/animals/chicken/anmlHenYell_09.wav",
			"$data/sounds/animals/chicken/anmlHenYell_10.wav",
			"$data/sounds/animals/chicken/anmlHenYell_11.wav",
		},
		yellMinMs = 100000, yellMaxMs = 200000, crowdScale = 0.12,
		range = 35, baseVolume = 0.6, pitchVar = 0.04,
		-- Chicken has its own step samples (8 variants); rapid little
		-- steps so cadence is much shorter than the four-leg species.
		step = {
			samples = {
				"$data/sounds/animals/chicken/anmlChickenStep_01.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_02.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_03.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_04.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_05.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_06.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_07.wav",
				"$data/sounds/animals/chicken/anmlChickenStep_08.wav",
			},
			walkStepMs = 250, runStepMs = 150,
			range = 15, baseVolume = 0.25, pitchVar = 0.08,
		},
	},
}


-- Lazy-loaded sample handles per species. nil = not yet loaded; {} = load
-- attempted and failed (don't retry). Successful loads cache an array of
-- handles aligned with SOUND_DEFS[species].yells.
local samplesCache = {}
local loadFailed = {}

-- Separate cache for eat samples, same lazy-load pattern.
local eatSamplesCache = {}
local eatLoadFailed = {}

-- Separate cache for footstep samples.
local stepSamplesCache = {}
local stepLoadFailed = {}


local function loadSpeciesSamples(speciesName)

	if samplesCache[speciesName] ~= nil then return samplesCache[speciesName] end
	if loadFailed[speciesName] then return nil end

	local def = SOUND_DEFS[speciesName]
	if def == nil or def.yells == nil then loadFailed[speciesName] = true; return nil end

	local baseDir = (g_currentMission and g_currentMission.baseDirectory) or ""
	local handles = {}

	for i, path in ipairs(def.yells) do
		local resolved = Utils.getFilename(path, baseDir)
		local handle = createSample(speciesName .. "_yell_" .. i)
		local ok = pcall(loadSample, handle, resolved, false)
		if ok then table.insert(handles, handle) end
	end

	if #handles == 0 then
		loadFailed[speciesName] = true
		return nil
	end

	samplesCache[speciesName] = handles
	return handles

end


local function loadEatSamples(speciesName)

	if eatSamplesCache[speciesName] ~= nil then return eatSamplesCache[speciesName] end
	if eatLoadFailed[speciesName] then return nil end

	local def = SOUND_DEFS[speciesName]
	if def == nil or def.eat == nil or def.eat.samples == nil then
		eatLoadFailed[speciesName] = true
		return nil
	end

	local baseDir = (g_currentMission and g_currentMission.baseDirectory) or ""
	local handles = {}

	for i, path in ipairs(def.eat.samples) do
		local resolved = Utils.getFilename(path, baseDir)
		local handle = createSample(speciesName .. "_eat_" .. i)
		local ok = pcall(loadSample, handle, resolved, false)
		if ok then table.insert(handles, handle) end
	end

	if #handles == 0 then
		eatLoadFailed[speciesName] = true
		return nil
	end

	eatSamplesCache[speciesName] = handles
	return handles

end


local function loadStepSamples(speciesName)

	if stepSamplesCache[speciesName] ~= nil then return stepSamplesCache[speciesName] end
	if stepLoadFailed[speciesName] then return nil end

	local def = SOUND_DEFS[speciesName]
	if def == nil or def.step == nil or def.step.samples == nil then
		stepLoadFailed[speciesName] = true
		return nil
	end

	local baseDir = (g_currentMission and g_currentMission.baseDirectory) or ""
	local handles = {}

	for i, path in ipairs(def.step.samples) do
		local resolved = Utils.getFilename(path, baseDir)
		local handle = createSample(speciesName .. "_step_" .. i)
		local ok = pcall(loadSample, handle, resolved, false)
		if ok then table.insert(handles, handle) end
	end

	if #handles == 0 then
		stepLoadFailed[speciesName] = true
		return nil
	end

	stepSamplesCache[speciesName] = handles
	return handles

end


-- Resolve animalTypeIndex → species name. Lazy-built reverse lookup
-- (AnimalType.* indices aren't populated until after this file loads).
-- After first build, this is O(1); the previous linear pairs() walk
-- ran on every yell / eat / step schedule.
local typeToSpecies = nil

local function rebuildTypeToSpecies()
	typeToSpecies = {}
	if AnimalType == nil then return end
	for name, _ in pairs(SOUND_DEFS) do
		local idx = AnimalType[name]
		if idx ~= nil then typeToSpecies[idx] = name end
	end
end

local function speciesNameForType(animalTypeIndex)
	if animalTypeIndex == nil then return nil end
	if typeToSpecies == nil then rebuildTypeToSpecies() end
	return typeToSpecies[animalTypeIndex]
end


-- Same Knuth-multiplicative pattern as PersonalityJitter / CalmBehaviorCycler.
-- Pure function of (seed, slot); no global RNG mutation.
local function hash01(seed, slot)
	local h = ((seed or 1) * 2654435761 + slot * 374761393) % 2147483647
	return h / 2147483647
end


function AnimalSounds.scheduleNextYell(animal, herdSize)

	local speciesName = speciesNameForType(animal.animalTypeIndex)
	if speciesName == nil then
		-- Map-bridge species (rabbit/goose/etc.) — defer the next check by
		-- a long interval so we don't burn cycles on lookup every tick.
		animal.nextYellAtMs = (g_time or 0) + 60000
		return
	end

	local def = SOUND_DEFS[speciesName]
	-- Crowd scale: 1 / (1 + (n-1) * 0.2). Solo cow: interval 8-20s. Herd of
	-- 10: interval shrinks by ~2.8× so the herd-density of yells is roughly
	-- constant regardless of headcount. Matches engine yellTimerCrowdScale.
	local n = math.max(1, herdSize or 1)
	local crowdMul = 1 / (1 + (n - 1) * (def.crowdScale or 0))

	-- Content-aware multiplier. Linear from 3× interval at arousal=0
	-- (content — pasture is mostly quiet) down to 1× at arousal=1
	-- (panicked / actively driven — base rate matching the engine
	-- in-pen density). Animals that have settled mid-herd get rare
	-- moos; animals being chased / startled stay vocal.
	local arousal = animal.arousal or 0
	if arousal < 0 then arousal = 0 elseif arousal > 1 then arousal = 1 end
	local contentMul = 1 + (1 - arousal) * 2

	local effMin = def.yellMinMs * crowdMul * contentMul
	local effMax = def.yellMaxMs * crowdMul * contentMul

	animal._yellCycle = (animal._yellCycle or 0) + 1
	local r = hash01(animal.id, animal._yellCycle * 3 + 17)
	local interval = effMin + (effMax - effMin) * r

	animal.nextYellAtMs = (g_time or 0) + interval

end


-- Cached listener position. Each tick of the per-farm animal loop calls
-- tick + eatTick + stepTick once per animal — three getWorldTranslation
-- calls per animal per frame would be ~90 hits on a 30-cow herd. Cache
-- by g_time so a fresh frame triggers a single refresh.
local cachedListenerX, cachedListenerZ, cachedListenerTime = 0, 0, -1

local function getListenerXZ()

	local now = g_time or 0
	if now == cachedListenerTime then
		return cachedListenerX, cachedListenerZ
	end
	cachedListenerTime = now

	-- Prefer the local player's vehicle (camera follows that), fall back to
	-- the on-foot player, then world origin. xz only — sounds are 2D
	-- (positional engine API isn't readily exposed for runtime sample
	-- creation), so we cull and attenuate by horizontal distance manually.
	if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
		local node = g_currentMission.controlledVehicle.rootNode
		if node ~= nil and node ~= 0 then
			cachedListenerX, _, cachedListenerZ = getWorldTranslation(node)
			return cachedListenerX, cachedListenerZ
		end
	end
	if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
		cachedListenerX, _, cachedListenerZ = getWorldTranslation(g_localPlayer.rootNode)
		return cachedListenerX, cachedListenerZ
	end
	cachedListenerX, cachedListenerZ = 0, 0
	return 0, 0

end


function AnimalSounds.tick(animal, herdSize, now)

	if animal.nextYellAtMs == nil or animal.nextYellAtMs == 0 then
		AnimalSounds.scheduleNextYell(animal, herdSize)
		return
	end

	if (now or 0) < animal.nextYellAtMs then return end

	local speciesName = speciesNameForType(animal.animalTypeIndex)
	if speciesName == nil then
		AnimalSounds.scheduleNextYell(animal, herdSize)
		return
	end

	local def = SOUND_DEFS[speciesName]
	local range = def.range or 50

	-- Distance-cull BEFORE doing the work of loading samples / picking variant.
	local lx, lz = getListenerXZ()
	local dx, dz = animal.position.x - lx, animal.position.z - lz
	local distSq = dx * dx + dz * dz
	if distSq > range * range then
		AnimalSounds.scheduleNextYell(animal, herdSize)
		return
	end

	local handles = loadSpeciesSamples(speciesName)
	if handles == nil or #handles == 0 then
		AnimalSounds.scheduleNextYell(animal, herdSize)
		return
	end

	-- Pick variant per-(animal, cycle) — different animals on the same tick
	-- get different yells; same animal rotates through variants over time.
	local pickIdx = math.floor(hash01(animal.id, animal._yellCycle * 3 + 19) * #handles) + 1
	if pickIdx > #handles then pickIdx = #handles end
	local handle = handles[pickIdx]

	-- Linear distance attenuation. Small per-(animal, cycle) pitch jitter
	-- so even repeated samples sound a little different.
	local dist = math.sqrt(distSq)
	local volume = (def.baseVolume or 1) * math.max(0, 1 - dist / range)
	local pitch = 1 + (hash01(animal.id, animal._yellCycle * 3 + 21) - 0.5) * 2 * (def.pitchVar or 0)

	pcall(playSample, handle, 1, volume, pitch, 0, 0)

	AnimalSounds.scheduleNextYell(animal, herdSize)

end


-- Eat / chew sound. Pulsed playback rather than a true infinite loop —
-- the engine API exposes playSample (one-shot) cleanly but stopSample
-- isn't visible from decoded scripts, so we fire the short eat-loop
-- sample at ~2s intervals while the CalmBehaviorCycler's calmBehavior is
-- in {graze, eat, chew}. Each sample is ~1-2s long; the gaps between
-- pulses are small enough to feel like continuous chewing.
local EATING_BEHAVIORS = { graze = true, eat = true, chew = true }


function AnimalSounds.eatTick(animal, now)

	local cb = animal.calmBehavior
	local isEating = cb ~= nil and EATING_BEHAVIORS[cb.id] == true

	if not isEating then
		-- Reset the timer so when the animal next enters an eating state,
		-- the first pulse is delayed by the per-animal jitter (avoids a
		-- whole herd firing the eat sound on the same frame they enter
		-- graze together).
		animal._nextEatPulseAtMs = nil
		return
	end

	local speciesName = speciesNameForType(animal.animalTypeIndex)
	if speciesName == nil then return end

	local def = SOUND_DEFS[speciesName]
	if def == nil or def.eat == nil then return end

	local eatDef = def.eat
	local n = (now or 0)

	if animal._nextEatPulseAtMs == nil then
		-- First entry into eating state — stagger initial pulse per animal
		-- so a herd that just rolled over to graze together doesn't pulse
		-- in unison.
		animal._eatCycle = (animal._eatCycle or 0) + 1
		local r = hash01(animal.id, animal._eatCycle * 5 + 41)
		animal._nextEatPulseAtMs = n + 200 + r * 1500
		return
	end

	if n < animal._nextEatPulseAtMs then return end

	-- Distance cull. Eat sounds are intimate — short range, easy cull.
	local lx, lz = getListenerXZ()
	local dx, dz = animal.position.x - lx, animal.position.z - lz
	local distSq = dx * dx + dz * dz
	local range = eatDef.range or 25

	if distSq > range * range then
		-- Skip this pulse but keep the timer rolling so we resume cleanly
		-- if the listener walks back into range.
		animal._nextEatPulseAtMs = n + 1500
		return
	end

	local handles = loadEatSamples(speciesName)
	if handles == nil or #handles == 0 then
		animal._nextEatPulseAtMs = nil
		return
	end

	animal._eatCycle = (animal._eatCycle or 0) + 1
	local pickIdx = math.floor(hash01(animal.id, animal._eatCycle * 5 + 43) * #handles) + 1
	if pickIdx > #handles then pickIdx = #handles end
	local handle = handles[pickIdx]

	local dist = math.sqrt(distSq)
	local volume = (eatDef.baseVolume or 0.5) * math.max(0, 1 - dist / range)
	local pitch = 1 + (hash01(animal.id, animal._eatCycle * 5 + 45) - 0.5) * 2 * (eatDef.pitchVar or 0.05)

	pcall(playSample, handle, 1, volume, pitch, 0, 0)

	-- Schedule next pulse with per-(animal, cycle) random interval. Small
	-- range so each animal's chewing rhythm sounds organic rather than
	-- mechanical.
	local pulseRange = (eatDef.pulseMaxMs or 2500) - (eatDef.pulseMinMs or 1800)
	local interval = (eatDef.pulseMinMs or 1800)
	                 + hash01(animal.id, animal._eatCycle * 5 + 47) * pulseRange
	animal._nextEatPulseAtMs = n + interval

end


-- Footstep pulses. Driven by state.isWalking / state.isRunning, with a
-- per-species cadence (cow heavy gait ~600ms walk, chicken rapid ~250ms).
-- Skips the pure-turn-in-place state (animal rotates without translating)
-- and the calm/idle states. Same pulsed-one-shot pattern as eatTick — no
-- infinite loops to manage on/off.
function AnimalSounds.stepTick(animal, now)

	local state = animal.state
	if state == nil then return end

	-- Only fire while the animal is actually translating. inPureTurn is
	-- the persistent flag set by HerdableAnimal's pure-turn gate; during
	-- it the animal is rotating in place with no world translation, so
	-- stepping audio would be wrong.
	local isMoving = (state.isWalking or state.isRunning) and not state.inPureTurn
	if not isMoving then
		animal._nextStepAtMs = nil
		return
	end

	local speciesName = speciesNameForType(animal.animalTypeIndex)
	if speciesName == nil then return end

	local def = SOUND_DEFS[speciesName]
	if def == nil or def.step == nil then return end

	local stepDef = def.step
	local n = (now or 0)

	-- Distance cull early. Footsteps are quietest, shortest range; most
	-- of a herd's animals are out of range at any moment.
	local lx, lz = getListenerXZ()
	local dx, dz = animal.position.x - lx, animal.position.z - lz
	local distSq = dx * dx + dz * dz
	local range = stepDef.range or 20
	if distSq > range * range then
		animal._nextStepAtMs = nil
		return
	end

	if animal._nextStepAtMs == nil then
		-- Stagger initial step per animal so a herd that just started
		-- moving doesn't all step on the same frame.
		animal._stepCycle = (animal._stepCycle or 0) + 1
		local r = hash01(animal.id, animal._stepCycle * 7 + 51)
		animal._nextStepAtMs = n + r * 200
		return
	end

	if n < animal._nextStepAtMs then return end

	local handles = loadStepSamples(speciesName)
	if handles == nil or #handles == 0 then
		animal._nextStepAtMs = nil
		return
	end

	animal._stepCycle = (animal._stepCycle or 0) + 1
	local pickIdx = math.floor(hash01(animal.id, animal._stepCycle * 7 + 53) * #handles) + 1
	if pickIdx > #handles then pickIdx = #handles end
	local handle = handles[pickIdx]

	local dist = math.sqrt(distSq)
	local volume = (stepDef.baseVolume or 0.35) * math.max(0, 1 - dist / range)
	local pitch = 1 + (hash01(animal.id, animal._stepCycle * 7 + 55) - 0.5) * 2 * (stepDef.pitchVar or 0.05)

	pcall(playSample, handle, 1, volume, pitch, 0, 0)

	-- Cadence: walk vs run intervals from the species def, ±10% jitter
	-- per step so the gait doesn't sound mechanical.
	local stepInterval = state.isRunning and (stepDef.runStepMs or 320) or (stepDef.walkStepMs or 600)
	local jitter = 0.9 + hash01(animal.id, animal._stepCycle * 7 + 57) * 0.2
	animal._nextStepAtMs = n + stepInterval * jitter

end
