HandToolAnimal = {}

local specName = "spec_FS25_AnimalHerdingLite.animal"
local keyName = "FS25_AnimalHerdingLite.animal"


-- Freezes the carried animal at the "sleep" pose.
-- Uses getAnimClipIndex + assignAnimTrackClip (confirmed FS25 GEX API from AnimalSystem.lua).
-- Skeleton is at child[0] after createHerdableAnimalFromData normalization.
-- Chickens have a different node structure and no sleep clip — skip them entirely.
-- Clip-name fallbacks for the carried-animal sleep pose.
-- The engine's animated calf i3d uses `sleepSideLBabySource`. Custom packs
-- (e.g. FS25_AnimalPackage_vanillaEdition) use their own naming convention:
-- cattle/pig/chicken use `FA_*`, sheep/goat use `BR_*`. We try them in order
-- and use the first one that exists in the cloned animation set.
local SLEEP_CLIP_FALLBACKS = {
    "sleepSideLBabySource",   -- engine baby
    "sleepSideRBabySource",   -- engine baby alt
    "FA_sleep01",             -- pack cattle / pig / chicken
    "FA_sleep02",
    "BR_sleep01",             -- pack sheep / goat
    "BR_sleep02",
    "sleep01",                -- generic
    "FA_rest01",              -- last-resort (lying-down rest pose)
    "BR_rest01",
}


local function applySleepPose(node, cache, animalTypeIndex)

    if animalTypeIndex == AnimalType.CHICKEN then return end

    local numChildren = getNumOfChildren(node)
    if numChildren == 0 then return end

    local skeletonNode = getChildAt(node, 0)
    if skeletonNode == nil or skeletonNode == 0 then return end

    local numSkeletonChildren = getNumOfChildren(skeletonNode)
    if numSkeletonChildren == 0 then return end

    local skinNode     = getChildAt(skeletonNode, 0)
    if skinNode == nil or skinNode == 0 then return end

    local animSet      = getAnimCharacterSet(cache.animationUsesSkeleton and skeletonNode or skinNode)

    if animSet == nil or animSet == 0 then return end

    -- Disable all active tracks (walk uses 0+1, transitions may use 0-3) so the
    -- sleep clip is the sole contributor and the mesh isn't a blended walk/sleep mix.
    for i = 0, 3 do disableAnimTrack(animSet, i) end

    local clipIndex, clipName
    for _, name in ipairs(SLEEP_CLIP_FALLBACKS) do
        local idx = getAnimClipIndex(animSet, name)
        if idx ~= nil and idx >= 0 then
            clipIndex = idx
            clipName = name
            break
        end
    end
    if clipIndex == nil then
        -- No known sleep clip in this skeleton — mesh stays at last frame of whatever was playing.
        Logging.warning("[AHL] HandToolAnimal: no known sleep clip found in animation set — keeping current pose")
        return
    end

    assignAnimTrackClip(animSet, 0, clipIndex)
    setAnimTrackBlendWeight(animSet, 0, 1)
    enableAnimTrack(animSet, 0)
    setAnimTrackSpeedScale(animSet, 0, 0)   -- hold at first frame of sleep clip

end


-- Clones cache.posed and applies vanilla atlas UV. Used when RL is not active.
local function buildVisualNode(graphicalNode, cache, x, y, z, w)

    if cache.posed == nil or cache.posed == 0 then return nil end

    local node = clone(cache.posed, false, false, false)
    link(graphicalNode, node)
    setVisibility(node, true)
    I3DUtil.setShaderParameterRec(node, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
    I3DUtil.setShaderParameterRec(node, "dirt", 0, nil, nil, nil)

    return node

end


-- For RL herded animals: steals the root node directly from the HerdableAnimal rather
-- than cloning it.  The node already has breed-correct textures from when it was herded
-- (applyRLVisuals ran successfully at that point).  We nil out animal.nodes.root so
-- HerdableAnimal:delete() won't call delete() on a node we now own.
local function stealHerdedRLVisualNode(graphicalNode, cache, animal, animalTypeIndex)

    if animal.nodes == nil or animal.nodes.root == nil or animal.nodes.root == 0 then return nil end

    local node = animal.nodes.root
    animal.nodes.root = nil  -- prevents delete() in HerdableAnimal:delete()

    link(graphicalNode, node)
    setVisibility(node, true)

    -- Clear dirt accumulated while the animal was walking in the field.

    I3DUtil.setShaderParameterRec(node, "dirt", 0, nil, nil, nil)

    applySleepPose(node, cache, animalTypeIndex)

    return node

end


function HandToolAnimal.registerFunctions(handTool)

	SpecializationUtil.registerFunction(handTool, "setEngineAnimal", HandToolAnimal.setEngineAnimal)
	SpecializationUtil.registerFunction(handTool, "setHerdingAnimal", HandToolAnimal.setHerdingAnimal)
	SpecializationUtil.registerFunction(handTool, "getAnimalTypeIndex", HandToolAnimal.getAnimalTypeIndex)
	SpecializationUtil.registerFunction(handTool, "getAnimal", HandToolAnimal.getAnimal)
	SpecializationUtil.registerFunction(handTool, "loadAnimal", HandToolAnimal.loadAnimal)
	SpecializationUtil.registerFunction(handTool, "loadFromPostLoad", HandToolAnimal.loadFromPostLoad)
	SpecializationUtil.registerFunction(handTool, "showInfo", HandToolAnimal.showInfo)

end


function HandToolAnimal.registerOverwrittenFunctions(handTool)
	--SpecializationUtil.registerOverwrittenFunction(handTool, "getShowInHandToolsOverview", HandToolAnimal.getShowInHandToolsOverview)
end


function HandToolAnimal.registerEventListeners(handTool)
	SpecializationUtil.registerEventListener(handTool, "onPostLoad", HandToolAnimal)
	SpecializationUtil.registerEventListener(handTool, "onHeldStart", HandToolAnimal)
	SpecializationUtil.registerEventListener(handTool, "onHeldEnd", HandToolAnimal)
	SpecializationUtil.registerEventListener(handTool, "onDelete", HandToolAnimal)
end


function HandToolAnimal.prerequisitesPresent()

	print("Loaded handTool: HandToolAnimal")

	return true

end


function HandToolAnimal:onPostLoad(savegame)

	if savegame == nil then return end
	
	local key = string.format("%s.%s", savegame.key, keyName)
	local xmlFile = savegame.xmlFile
	local spec = self[specName]

	local classObject = ClassUtil.getClassObject(xmlFile:getString(key .. "#className", "AnimalCluster")) or AnimalCluster
	spec.tiles = xmlFile:getVector(key .. "#tiles")
	spec.animalTypeIndex = xmlFile:getInt(key .. "#animalTypeIndex", 1)
	spec.visualAnimalIndex = xmlFile:getInt(key .. "#visualAnimalIndex", 1)

	local clusterKey = key .. ".cluster"

	if g_modIsLoaded["FS25_RealisticLivestock"] then
		spec.animal = classObject.loadFromXMLFile(xmlFile, clusterKey)
	else
		spec.animal = classObject.new()
		spec.animal:loadFromXMLFile(xmlFile, clusterKey)
	end

	-- Ensure subTypeIndex is always set after loading. RL's static loadFromXMLFile
	-- may set it, but vanilla AnimalCluster does not — and applyRLVisuals / saveToXMLFile
	-- both depend on it. The saved subType name is the authoritative source.
	if spec.animal ~= nil and (spec.animal.subTypeIndex == nil or spec.animal.subTypeIndex == 0) then
		local subTypeName = xmlFile:getString(clusterKey .. "#subType", "")
		if subTypeName ~= "" then
			spec.animal.subTypeIndex = g_currentMission.animalSystem:getSubTypeIndexByName(subTypeName)
		end
	end

	spec.placeable = xmlFile:getString(key .. "#placeable")

	local cache = g_animalManager:getVisualAnimalFromCache(spec.animalTypeIndex, spec.visualAnimalIndex)

	if cache == nil then return false end

	local node
	if AnimalManager.CONFLICTS.ANIMAL_PACK_VANILLA and cache.root ~= nil and cache.root ~= 0 then
		-- Pack path: clone animated i3d for sleep pose, skip applyRLVisuals
		-- (would crash on pack i3d). See note in setEngineAnimal.
		node = clone(cache.root, false, false, false)
		link(self.graphicalNode, node)
		setVisibility(node, true)
		local meshNode = I3DUtil.indexToObject(node, cache.mesh)
		if spec.tiles ~= nil and meshNode ~= nil and meshNode ~= 0 then
			local x, y, z, w = unpack(spec.tiles)
			I3DUtil.setShaderParameterRec(meshNode, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
		end
		I3DUtil.setShaderParameterRec(node, "dirt", 0, nil, nil, nil)
		applySleepPose(node, cache, spec.animalTypeIndex)
	elseif AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK and cache.root ~= nil and cache.root ~= 0 then
		node = clone(cache.root, false, false, false)
		link(self.graphicalNode, node)
		setVisibility(node, true)
		local meshNode = I3DUtil.indexToObject(node, cache.mesh)
		-- Set atlas UV and clear dirt before RL visual load
		if spec.tiles ~= nil and meshNode ~= nil and meshNode ~= 0 then
			local x, y, z, w = unpack(spec.tiles)
			I3DUtil.setShaderParameterRec(meshNode, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
		end
		I3DUtil.setShaderParameterRec(node, "dirt", 0, nil, nil, nil)
		local pseudoAnimal = { cluster = spec.animal, nodes = { root = node, mesh = meshNode }, visualAnimalIndex = spec.visualAnimalIndex }
		local ok = pcall(g_animalManager.applyRLVisuals, g_animalManager, pseudoAnimal)
		if ok then applySleepPose(node, cache, spec.animalTypeIndex) end
	else
		local x, y, z, w = unpack(spec.tiles)
		node = buildVisualNode(self.graphicalNode, cache, x, y, z, w)
	end
	if node == nil then return false end

	g_animalManager:addHandToolToSetOnPostLoad(self)

end


function HandToolAnimal:saveToXMLFile(xmlFile, key)

	local spec = self[specName]

	xmlFile:setString(key .. "#className", ClassUtil.getClassNameByObject(spec.animal))
	xmlFile:setVector(key .. "#tiles", spec.tiles)
	xmlFile:setInt(key .. "#visualAnimalIndex", spec.visualAnimalIndex)
	xmlFile:setInt(key .. "#animalTypeIndex", spec.animalTypeIndex)
	xmlFile:setString(key .. "#placeable", spec.placeable)

	if spec.animal.subTypeIndex ~= nil then
		local subType = g_currentMission.animalSystem:getSubTypeByIndex(spec.animal.subTypeIndex)
		if subType ~= nil then
			xmlFile:setString(key .. ".cluster#subType", subType.name)
		end
	end
	spec.animal:saveToXMLFile(xmlFile, key .. ".cluster")

end


function HandToolAnimal:getAnimalTypeIndex()

	return self[specName].animalTypeIndex

end


function HandToolAnimal:getAnimal()

	return self[specName].animal

end


function HandToolAnimal:loadAnimal(animal, animalTypeIndex, placeable)

	local spec = self[specName]

	spec.animal = animal
	spec.animalTypeIndex = animalTypeIndex

	local player = self:getCarryingPlayer()
	player:setIsCarryingAnimal(true)
	g_animalManager:addCarriedAnimalToPlayer(player, self, placeable)
	spec.player = player
	spec.placeable = placeable

end


function HandToolAnimal:loadFromPostLoad()

	local spec = self[specName]

	local player = self:getCarryingPlayer()

	if player == nil then return false end

	player:setIsCarryingAnimal(true)
	player:setCurrentHandTool(self)
	g_animalManager:addCarriedAnimalToPlayer(player, self, spec.placeable)
	spec.player = player

	return true

end


function HandToolAnimal:showInfo(box)

	box:setTitle(g_i18n:getText("ahl_carriedAnimal"))
	self[specName].animal:showInfo(box)

end


function HandToolAnimal:setEngineAnimal(husbandryId, animalId)

	local spec = self[specName]

	local husbandry = g_currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)
	if husbandry == nil then return false end
	local animal = husbandry:getClusterByAnimalId(animalId, husbandryId)
	if animal == nil then return false end
	local clonedAnimal
	if animal.clone ~= nil then
		-- RL Animal: use clone() which copies all fields (birthday, uniqueId, farmId, etc.)
		local okC, c = pcall(animal.clone, animal)
		if not okC then return false end
		clonedAnimal = c
	else
		-- Vanilla AnimalCluster: use built-in attribute copy
		clonedAnimal = animal:class().new()
		clonedAnimal:copyAttributes(animal)
	end
	clonedAnimal.id = animal.id
	clonedAnimal.numAnimals = animal.numAnimals

	local animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(clonedAnimal.subTypeIndex)
	local visualAnimalIndex = g_animalManager:getVisualDataForEngineAnimal(husbandryId, animalId)
	local x, y, z, w = getAnimalShaderParameter(husbandryId, animalId, "atlasInvSizeAndOffsetUV")

	local cache = g_animalManager:getVisualAnimalFromCache(animalTypeIndex, visualAnimalIndex)

	if cache == nil then return false end

	local node
	if AnimalManager.CONFLICTS.ANIMAL_PACK_VANILLA and cache.root ~= nil and cache.root ~= 0 then
		-- Custom-pack path: clone the animated i3d (so the carried animal has a
		-- skeleton + animation set we can pose) but DO NOT call applyRLVisuals —
		-- RL's safeIndexToObject paths are designed for the engine's node
		-- hierarchy and corrupt state on pack i3ds, native-crashing one frame
		-- later when the engine renders the carried animal. applySleepPose's
		-- expanded clip-name fallback (FA_sleep01 / BR_sleep01 / etc.) covers
		-- the pack's clip naming.
		local cloneNode = clone(cache.root, false, false, false)
		link(self.graphicalNode, cloneNode)
		setVisibility(cloneNode, true)
		local meshNode = I3DUtil.indexToObject(cloneNode, cache.mesh)
		if meshNode ~= nil and meshNode ~= 0 then
			I3DUtil.setShaderParameterRec(meshNode, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
		end
		I3DUtil.setShaderParameterRec(cloneNode, "dirt", 0, nil, nil, nil)
		applySleepPose(cloneNode, cache, animalTypeIndex)
		node = cloneNode
	elseif AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK and not AnimalManager.CONFLICTS.ANIMAL_PACK_VANILLA then
		-- For pen animals we can't steal a node, so try applyRLVisuals on a fresh clone.
		-- If va:load() crashes (RLRM font issue), fall back to the vanilla posed model.
		if cache.root ~= nil and cache.root ~= 0 then
			local cloneNode = clone(cache.root, false, false, false)
			link(self.graphicalNode, cloneNode)
			setVisibility(cloneNode, true)
			local meshNode = I3DUtil.indexToObject(cloneNode, cache.mesh)
			-- Set the base atlas UV and clear dirt before RL visual load — va:load()
			-- only applies breed-specific textures, the atlas UV must already be correct.
			if meshNode ~= nil and meshNode ~= 0 then
				I3DUtil.setShaderParameterRec(meshNode, "atlasInvSizeAndOffsetUV", x, y, z, w, false)
			end
			I3DUtil.setShaderParameterRec(cloneNode, "dirt", 0, nil, nil, nil)
			local pseudoAnimal = { cluster = clonedAnimal, nodes = { root = cloneNode, mesh = meshNode }, visualAnimalIndex = visualAnimalIndex }
			local ok = pcall(g_animalManager.applyRLVisuals, g_animalManager, pseudoAnimal)
			if ok then
				applySleepPose(cloneNode, cache, animalTypeIndex)
			end
			node = cloneNode
		else
			node = buildVisualNode(self.graphicalNode, cache, x, y, z, w)
		end
	else
		node = buildVisualNode(self.graphicalNode, cache, x, y, z, w)
	end
	if node == nil then return false end

	spec.tiles = { x, y, z, w }
	spec.visualAnimalIndex = visualAnimalIndex

	if g_animalManager:getHasHusbandryConflict() then
		-- RL animals are individual (numAnimals=1); remove the cluster and refresh visuals
		g_client:getServerConnection():sendEvent(AnimalPickupEvent.new(husbandry.placeable, animal.id, clonedAnimal.numAnimals))
	else

		local numVisualAnimals, numAnimals, numRemovedAnimals = 0, clonedAnimal.numAnimals, 0

		for animalId, cluster in pairs(husbandry.animalIdToCluster) do

			if cluster.id == animal.id then numVisualAnimals = numVisualAnimals + 1 end

		end

		if numVisualAnimals == 1 then
			--husbandry.placeable:getClusterSystem():addPendingRemoveCluster(animal)
		else
			clonedAnimal.numAnimals = math.floor(numAnimals / numVisualAnimals)
		end

		g_client:getServerConnection():sendEvent(AnimalPickupEvent.new(husbandry.placeable, animal.id, clonedAnimal.numAnimals))

	end

	self:loadAnimal(clonedAnimal, animalTypeIndex, husbandry.placeable:getUniqueId())

	return true

end


function HandToolAnimal:setHerdingAnimal(animalNode, farmId)

	local spec = self[specName]

	local animal = g_animalManager:getAnimalFromCollisionNode(animalNode, farmId)
	local visualAnimalIndex = animal.visualAnimalIndex
	local animalTypeIndex = g_animalManager:getAnimalTypeIndexForFarm(farmId)

	local cache = g_animalManager:getVisualAnimalFromCache(animalTypeIndex, visualAnimalIndex)

	if cache == nil then return false end

	local node
	-- Both RL-only and RL+pack setups can steal the herded mesh: it's already
	-- cloned with the right textures (applyRLVisuals ran at herding spawn for
	-- RL-only; for the pack, the herded mesh is the pack's animated i3d with
	-- atlas UV already applied). applySleepPose's clip-name fallback handles
	-- both engine and pack skeletons.
	if AnimalManager.CONFLICTS.REALISTIC_LIVESTOCK then
		node = stealHerdedRLVisualNode(self.graphicalNode, cache, animal, animalTypeIndex)
	else
		local x, y, z, w = unpack(animal.tiles)
		node = buildVisualNode(self.graphicalNode, cache, x, y, z, w)
	end
	if node == nil then return false end

	spec.visualAnimalIndex = visualAnimalIndex
	spec.tiles = animal.tiles

	self:loadAnimal(animal.cluster, animalTypeIndex, animal.placeable)
	g_animalManager:removeHerdedAnimal(farmId, animal)

	return true

end


function HandToolAnimal:onHeldStart()

	g_localPlayer.hudUpdater:setCarriedAnimal(self)

end


function HandToolAnimal:onHeldEnd()

	if g_localPlayer == nil then return end

	g_localPlayer.hudUpdater:setCarriedAnimal()

end


function HandToolAnimal:onDelete()

	if g_localPlayer == nil then return end

	-- spec.player is only set by loadAnimal / loadFromPostLoad. If
	-- setEngineAnimal returned false (e.g. cache miss for a species visual
	-- index the mod doesn't yet cache, like a Hof Bergmann drake's
	-- visualAnimalIndex), the handtool gets markHandToolForDeletion'd
	-- before loadAnimal ever fires — spec.player stays nil. Bail so the
	-- pickup-failure path doesn't crash on top of the original failure.
	local spec = self[specName]
	if spec ~= nil and spec.player ~= nil then
		spec.player:setIsCarryingAnimal(false)
	end

	if g_localPlayer.hudUpdater ~= nil then
		g_localPlayer.hudUpdater:setCarriedAnimal()
	end

end