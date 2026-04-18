AnimalAnimationNaming = {}


local DEFAULT_NAMES = { walk = "walk1", idle = "idle1", run = "run1" }


-- Each entry: { maxAge = N, walk = "clipId", idle = "clipId", run = "clipId" }
-- Entries are evaluated top-to-bottom; the first where age < maxAge wins.
-- A nil maxAge acts as the catch-all (adult).
-- Horse and Chicken are omitted and will use DEFAULT_NAMES.

function AnimalAnimationNaming.getConfig()

	if AnimalAnimationNaming.CONFIG ~= nil then return AnimalAnimationNaming.CONFIG end

	AnimalAnimationNaming.CONFIG = {

		[AnimalType.COW] = {
			{ maxAge = 6,   walk = "walk2", idle = "idle1", run = "run1" },   -- baby (< 6 months)
			{ maxAge = 12,  walk = "walk1", idle = "idle1", run = "run1" },   -- young (6 to < 12 months)
			{ maxAge = nil, walk = "walk1", idle = "idle1", run = "run1" },   -- adult (>= 12 months)
		},

		[AnimalType.PIG] = {
			{ maxAge = 3,   walk = "walk1", idle = "idle1", run = "run1" },   -- baby (< 3 months)
			{ maxAge = 6,   walk = "walk1", idle = "idle1", run = "run1" },   -- young (3 to < 6 months)
			{ maxAge = nil, walk = "walk1", idle = "idle1", run = "run1" },   -- adult (>= 6 months)
		},

		[AnimalType.SHEEP] = {
			{ maxAge = 3,   walk = "walk2", idle = "idle1", run = "run1" },   -- baby (< 3 months)
			{ maxAge = 8,   walk = "walk1", idle = "idle1", run = "run1" },   -- young (3 to < 8 months)
			{ maxAge = nil, walk = "walk1", idle = "idle1", run = "run1" },   -- adult (>= 8 months)
		}

	}

	return AnimalAnimationNaming.CONFIG

end


function AnimalAnimationNaming.resolve(animalTypeIndex, age)

	local config = AnimalAnimationNaming.getConfig()[animalTypeIndex]

	if config == nil then return DEFAULT_NAMES end

	for _, entry in ipairs(config) do

		if entry.maxAge == nil or age < entry.maxAge then
			return { walk = entry.walk, idle = entry.idle, run = entry.run }
		end

	end

	return DEFAULT_NAMES

end
