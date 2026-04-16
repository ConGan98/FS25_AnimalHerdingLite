-- This file is sourced by RL (via rlMod.source()) and runs inside RL's _ENV,
-- where VisualAnimal is defined. We expose a factory function on the RL mod
-- object so AnimalHerdingLite can create VisualAnimal instances without going
-- through VisualAnimal.new(), which calls getAnimalRootNode() and errors on id=0.
local rlMod = FS25_RealisticLivestock or FS25_RealisticLivestockRM
if rlMod == nil or VisualAnimal == nil then return end

rlMod.AHL_createVisualAnimal = function(cluster, rootNode)
    local self = {
        animal  = cluster,
        nodes   = { root = rootNode },
        texts   = { earTagLeft = {}, earTagRight = {} },
        leftTextColour  = { 0, 0, 0 },
        rightTextColour = { 0, 0, 0 },
    }
    setmetatable(self, { __index = VisualAnimal })
    return self
end
