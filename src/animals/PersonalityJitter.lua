PersonalityJitter = {}


-- Per-individual ±range multiplier on each behavior field. Slot index seeds the
-- hash so each field gets an independent factor. Field names line up with
-- AnimalSpeciesConfig — fields not listed here pass through unchanged.
local FIELDS = {
	{ name = "startleThreshold",   range = 0.15, slot = 1 },
	{ name = "arousalDecayPerSec", range = 0.15, slot = 2 },
	{ name = "calmThreshold",      range = 0.15, slot = 3 },
	{ name = "preFleeGazeMs",      range = 0.20, slot = 4 },
	{ name = "alertLingerMs",      range = 0.20, slot = 5 },
	{ name = "walkDistance",       range = 0.10, slot = 6 },
	{ name = "runDistance",        range = 0.10, slot = 7 },
	{ name = "grazeChancePerTick", range = 0.25, slot = 8 },
}


-- Deterministic Knuth-multiplicative hash. Returns 1±range. Pure function of
-- (seed, slot). No global RNG mutation — server, client, and reload all
-- compute identical factors as long as the seed (animal id) matches.
local function jitterFactor(seed, slot, range)
	local h = ((seed or 1) * 2654435761 + slot * 374761393) % 2147483647
	local f = (h / 2147483647) * 2 - 1
	return 1 + f * range
end


function PersonalityJitter.apply(baseCfg, seed)

	local out = {}
	for k, v in pairs(baseCfg) do out[k] = v end

	for _, f in ipairs(FIELDS) do
		local base = baseCfg[f.name]
		if type(base) == "number" then
			out[f.name] = base * jitterFactor(seed, f.slot, f.range)
		end
	end

	return out

end
