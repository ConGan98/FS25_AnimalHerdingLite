CalmBehaviorCycler = {}


-- Per-species behavior pool with normalised weights and per-behavior duration
-- ranges (ms). Behaviors get filtered against the animal's cache.states at pick
-- time, so missing clips never leak through. Species not in the table fall to
-- DEFAULT (graze + idle only — works for any animal that has the standard
-- engine state machine).
local POOLS = {
	COW = {
		{ id = "graze", w = 0.55, durMin = 12000, durMax = 30000 },
		{ id = "chew",  w = 0.25, durMin =  8000, durMax = 15000 },
		{ id = "idle",  w = 0.15, durMin =  6000, durMax = 12000 },
		{ id = "eat",   w = 0.05, durMin =  8000, durMax = 18000 },
	},
	SHEEP = {
		{ id = "graze", w = 0.60, durMin = 12000, durMax = 30000 },
		{ id = "chew",  w = 0.20, durMin =  8000, durMax = 15000 },
		{ id = "idle",  w = 0.15, durMin =  6000, durMax = 12000 },
		{ id = "eat",   w = 0.05, durMin =  8000, durMax = 18000 },
	},
	PIG = {
		{ id = "graze", w = 0.40, durMin = 12000, durMax = 30000 },
		{ id = "eat",   w = 0.30, durMin =  8000, durMax = 18000 },
		{ id = "idle",  w = 0.20, durMin =  6000, durMax = 12000 },
		{ id = "chew",  w = 0.10, durMin =  8000, durMax = 15000 },
	},
	HORSE = {
		{ id = "graze", w = 0.50, durMin = 12000, durMax = 30000 },
		{ id = "idle",  w = 0.40, durMin =  6000, durMax = 12000 },
		{ id = "chew",  w = 0.10, durMin =  8000, durMax = 15000 },
	},
	CHICKEN = {
		{ id = "graze", w = 0.45, durMin =  6000, durMax = 15000 },
		{ id = "idle",  w = 0.45, durMin =  4000, durMax =  9000 },
		{ id = "eat",   w = 0.10, durMin =  6000, durMax = 12000 },
	},
}

local DEFAULT_POOL = {
	{ id = "graze", w = 0.60, durMin = 10000, durMax = 22000 },
	{ id = "idle",  w = 0.40, durMin =  6000, durMax = 12000 },
}


local function speciesPool(animal)
	if animal == nil or animal.animalTypeIndex == nil or AnimalType == nil then
		return DEFAULT_POOL
	end
	for name, pool in pairs(POOLS) do
		if AnimalType[name] == animal.animalTypeIndex then return pool end
	end
	return DEFAULT_POOL
end


-- Deterministic per-(animal, slot) hash. Same Knuth-multiplicative pattern
-- as PersonalityJitter — stays consistent across server/client and never
-- mutates the global RNG.
local function hash01(animalId, slot)
	local h = ((animalId or 1) * 2654435761 + slot * 374761393) % 2147483647
	return h / 2147483647
end


local function pickFromPool(animal, cacheStates, cycleIndex)

	-- Cache not yet populated (animal spawned before AnimalSystem cache
	-- finished building, e.g. early-load race). Return the always-safe
	-- idle behavior with a short duration so we re-roll soon and pick
	-- up real species behaviors once the cache lands. Without this, the
	-- previous "fall through unfiltered" path could pick `eat` for an
	-- animal whose cache lacks an eat state — AnimalAnimation falls
	-- back to idle visually, but isGrazing tracks the wrong cb.id.
	if cacheStates == nil then
		return { id = "idle", expiresAtMs = (g_time or 0) + 2000, cycle = cycleIndex }
	end

	local pool = speciesPool(animal)

	local filtered = {}
	local totalW = 0
	for _, entry in ipairs(pool) do
		if cacheStates[entry.id] ~= nil then
			table.insert(filtered, entry)
			totalW = totalW + entry.w
		end
	end
	if #filtered == 0 then filtered = { { id = "idle", w = 1, durMin = 6000, durMax = 12000 } }; totalW = 1 end

	local id = animal and animal.id or 0
	local r = hash01(id, cycleIndex * 2 + 1) * totalW
	local picked = filtered[#filtered]
	local acc = 0
	for _, entry in ipairs(filtered) do
		acc = acc + entry.w
		if r <= acc then picked = entry; break end
	end

	local durRange = picked.durMax - picked.durMin
	local dur = picked.durMin + math.floor(hash01(id, cycleIndex * 2 + 2) * durRange)

	return { id = picked.id, expiresAtMs = (g_time or 0) + dur, cycle = cycleIndex }

end


function CalmBehaviorCycler.pickInitialBehavior(animal, cacheStates)
	-- cycle 0 — phase-offset across animals comes from animal.id alone.
	return pickFromPool(animal, cacheStates, 0)
end


function CalmBehaviorCycler.maybeRotate(animal, cacheStates, now)

	local cb = animal and animal.calmBehavior
	if cb == nil then
		animal.calmBehavior = pickFromPool(animal, cacheStates, 0)
		return
	end

	if (now or 0) < (cb.expiresAtMs or 0) then return end

	animal.calmBehavior = pickFromPool(animal, cacheStates, (cb.cycle or 0) + 1)

end
