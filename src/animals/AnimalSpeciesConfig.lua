AnimalSpeciesConfig = {}

-- ============================================================================
-- Per-species tuning for herded-animal behavior. All species share the same
-- schema; each field is documented once below, then each species table just
-- overrides values.
--
-- -- PERCEPTION --------------------------------------------------------------
--   walkDistance      (m)   Awareness radius. Non-bucket influencers within
--                           this distance contribute to arousal and are
--                           candidates for the nearest-threat flee vector.
--   runDistance       (m)   Flee switches walk → run when the nearest-threat
--                           distance drops below this.
--   turnDistance      (m)   Animal only rotates toward its flee/target
--                           direction when the target is within this range.
--                           Beyond it the animal holds its current facing.
--   grazeRadius       (m)   Max offset for a random graze target around
--                           current position. Larger = animal wanders further.
--
-- -- SPEEDS ------------------------------------------------------------------
--   maxRunSpeed     (m/s)   Hard cap on run speed (prevents overly fast chases).
--   grazeSpeedScalar (0..1) Fraction of normal walk speed used while grazing.
--
-- -- AROUSAL -----------------------------------------------------------------
--   startleThreshold (0..1) Arousal level at which the animal transitions to
--                           flee/panic. Lower = more easily spooked.
--   calmThreshold    (0..1) Arousal level below which grazing is allowed.
--   arousalDecayPerSec      Rate per second at which arousal decays when no
--                           threat is present.
--   alertLingerMs     (ms)  How long the animal stays wary (facing the last
--                           threat direction) after the threat leaves.
--   preFleeGazeMs     (ms)  Duration of the head-turn "look at threat" beat
--                           when arousal first crosses startleThreshold,
--                           before the animal commits to fleeing.
--
-- -- FLOCKING (Reynolds boids) -----------------------------------------------
--   flockRadius       (m)   Max range at which same-species animals count as
--                           flock neighbors for cohesion / alignment.
--   cohesionWeight          Strength of pull toward the herd centroid.
--                           Higher = tighter flocking. Fades with arousal.
--   alignmentWeight         Strength of "match neighbors' heading" tendency.
--                           Rises with arousal (stampede coherence).
--   maxFlockNeighbors       Cap on how many neighbors are considered (LOD).
--
-- -- VEHICLE SCARE MODIFIERS -------------------------------------------------
--   vehicleRadiusMult       Vehicle influence radius = walkDistance * this.
--                           Larger = vehicles scary from further than a person.
--   vehicleArousalMult      Vehicle arousal contribution multiplied by this.
--                           Larger = vehicles build fear faster.
--
-- -- GRAZING CADENCE ---------------------------------------------------------
--   grazeReselectMs {a,b}   Random min..max delay (ms) between graze-target
--                           reselections.
--   grazeChancePerTick      Per-tick probability of picking a new graze
--                           target while calm and idle.
--
-- -- COLLISION / AVOIDANCE ---------------------------------------------------
--   radius            (m)   Behavior radius used by separation steering and
--                           the front-neighbor yield check. Independent from
--                           the engine's physics-probe geometry — does NOT
--                           resize the collision proxy.
--   height            (m)   Behavior height (currently informational).
--   separationWeight        Strength of the repulsion-from-neighbors boids
--                           force. Higher = animals keep more personal space.
-- ============================================================================


-- Template tuning keyed by animal type NAME (looked up at first use, because
-- AnimalType.* numeric indices are not yet populated when this file loads).
local BY_NAME = {
	COW = {
		walkDistance        = 16,
		runDistance         = 5,
		turnDistance        = 13,
		grazeRadius         = 8,
		maxRunSpeed         = 3.0,
		grazeSpeedScalar    = 0.5,
		startleThreshold    = 0.55,
		calmThreshold       = 0.12,
		arousalDecayPerSec  = 0.45,
		alertLingerMs       = 6000,
		preFleeGazeMs       = 450,
		flockRadius         = 10,
		cohesionWeight      = 0.9,
		alignmentWeight     = 0.7,
		maxFlockNeighbors   = 6,
		vehicleRadiusMult   = 1.6,
		vehicleArousalMult  = 1.5,
		grazeReselectMs     = { 6000, 14000 },
		grazeChancePerTick  = 0.015,
		radius              = 0.6,
		height              = 1.4,
		separationWeight    = 1.0,
	},
	SHEEP = {
		walkDistance        = 14,
		runDistance         = 4,
		turnDistance        = 11,
		grazeRadius         = 6,
		maxRunSpeed         = 3.0,
		grazeSpeedScalar    = 0.30,
		startleThreshold    = 0.40,
		calmThreshold       = 0.10,
		arousalDecayPerSec  = 0.35,
		alertLingerMs       = 8000,
		preFleeGazeMs       = 300,
		flockRadius         = 7,
		cohesionWeight      = 1.3,
		alignmentWeight     = 1.1,
		maxFlockNeighbors   = 8,
		vehicleRadiusMult   = 1.7,
		vehicleArousalMult  = 1.6,
		grazeReselectMs     = { 5000, 12000 },
		grazeChancePerTick  = 0.020,
		radius              = 0.4,
		height              = 0.9,
		separationWeight    = 1.2,
	},
	PIG = {
		walkDistance        = 12,
		runDistance         = 3,
		turnDistance        = 9,
		grazeRadius         = 5,
		maxRunSpeed         = 3.0,
		grazeSpeedScalar    = 0.25,
		startleThreshold    = 0.65,
		calmThreshold       = 0.15,
		arousalDecayPerSec  = 0.55,
		alertLingerMs       = 4000,
		preFleeGazeMs       = 600,
		flockRadius         = 6,
		cohesionWeight      = 0.5,
		alignmentWeight     = 0.3,
		maxFlockNeighbors   = 4,
		vehicleRadiusMult   = 1.4,
		vehicleArousalMult  = 1.3,
		grazeReselectMs     = { 7000, 16000 },
		grazeChancePerTick  = 0.012,
		radius              = 0.5,
		height              = 0.8,
		separationWeight    = 1.0,
	},
	HORSE = {
		walkDistance        = 20,
		runDistance         = 6,
		turnDistance        = 16,
		grazeRadius         = 12,
		maxRunSpeed         = 3.2,
		grazeSpeedScalar    = 0.40,
		startleThreshold    = 0.50,
		calmThreshold       = 0.12,
		arousalDecayPerSec  = 0.50,
		alertLingerMs       = 7000,
		preFleeGazeMs       = 500,
		flockRadius         = 14,
		cohesionWeight      = 0.6,
		alignmentWeight     = 0.8,
		maxFlockNeighbors   = 5,
		vehicleRadiusMult   = 1.8,
		vehicleArousalMult  = 1.7,
		grazeReselectMs     = { 6000, 15000 },
		grazeChancePerTick  = 0.018,
		radius              = 0.8,
		height              = 1.8,
		separationWeight    = 0.9,
	},
	CHICKEN = {
		walkDistance        = 10,
		runDistance         = 2,
		turnDistance        = 7,
		grazeRadius         = 3,
		maxRunSpeed         = 3.0,
		grazeSpeedScalar    = 0.45,
		startleThreshold    = 0.30,
		calmThreshold       = 0.10,
		arousalDecayPerSec  = 0.70,
		alertLingerMs       = 3000,
		preFleeGazeMs       = 150,
		flockRadius         = 4,
		cohesionWeight      = 0.8,
		alignmentWeight     = 0.4,
		maxFlockNeighbors   = 4,
		vehicleRadiusMult   = 2.0,
		vehicleArousalMult  = 2.0,
		grazeReselectMs     = { 3000, 9000 },
		grazeChancePerTick  = 0.030,
		radius              = 0.25,
		height              = 0.5,
		separationWeight    = 1.4,
	},
}


AnimalSpeciesConfig.DEFAULT = BY_NAME.COW


local byIndex = nil


local function buildIndexTable()

	byIndex = {}

	for name, cfg in pairs(BY_NAME) do
		local idx = AnimalType[name]
		if idx ~= nil then byIndex[idx] = cfg end
	end

end


function AnimalSpeciesConfig.get(animalTypeIndex)

	if byIndex == nil then buildIndexTable() end

	return byIndex[animalTypeIndex] or AnimalSpeciesConfig.DEFAULT

end
