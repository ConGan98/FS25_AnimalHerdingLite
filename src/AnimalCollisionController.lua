AnimalCollisionController = {}


local AnimalCollisionController_mt = Class(AnimalCollisionController)
local modDirectory = g_currentModDirectory
local collisionFlag = CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.BUILDING + CollisionFlag.ANIMAL + CollisionFlag.PLAYER + CollisionFlag.ROAD

-- ROAD and BUILDING are intentionally excluded from the groundLow probe: flat walkable surfaces
-- (road surfaces, building platforms) are not step-obstacles. Including them here causes the
-- animal to oscillate vertically because the probe fires on the surface, snapping Y up, then
-- terrain height snaps it back down. The front probe keeps both flags so animals still stop
-- at road/building edges.
local groundLowCollisionFlag = CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.ANIMAL + CollisionFlag.PLAYER


-- Returns a short type label and the raw node name for debug display.
local function classifyNode(node)
	local rbType = getRigidBodyType(node)
	if rbType == nil or rbType == "" or rbType == "NoRigidBody" then rbType = "Unknown" end
	local name = getName(node) or "?"
	return rbType, name
end


-- Per-node trigger cache. The original gate-trigger filter ran
-- string.lower(getName(node)) and string.find on every overlap hit, every
-- probe (front/left/right/groundLow), every animal, every frame — non-trivial
-- string churn. The set of distinct trigger nodes encountered in a session
-- is small (a few dozen gates, husbandry triggers, etc.) so a per-node bool
-- cache is bounded and avoids the repeated string ops. Node IDs are integer
-- handles; no GC pressure from keys.
local triggerNodeCache = {}

local function isTriggerNode(node)
	local cached = triggerNodeCache[node]
	if cached ~= nil then return cached end
	local name = getName(node)
	local result = name ~= nil and string.find(string.lower(name), "trigger") ~= nil
	triggerNodeCache[node] = result
	return result
end


-- Broad discovery sweep: catches all physics objects near the animal regardless of their group bits.
-- Used to find objects the normal probes miss (group not in collisionFlag).
local DISCOVERY_SWEEP_FLAG = 0x7FFFFFFF

-- Named CollisionFlag entries used to decode a node's group bits into readable labels.
-- Evaluated lazily at first use so CollisionFlag is guaranteed to be initialised.
local KNOWN_COLLISION_FLAGS = nil
local function getKnownFlags()
	if KNOWN_COLLISION_FLAGS ~= nil then return KNOWN_COLLISION_FLAGS end
	KNOWN_COLLISION_FLAGS = {}
	local flagNames = {
		"STATIC_OBJECT", "DYNAMIC_OBJECT", "VEHICLE", "BUILDING",
		"ANIMAL", "PLAYER", "TERRAIN", "FOLIAGE",
		"TRIGGER_PLAYER", "TRIGGER_VEHICLE", "TRIGGER_ANIMAL",
		"WATER", "ROAD", "FILLABLE",
	}
	for _, name in ipairs(flagNames) do
		local v = CollisionFlag[name]
		if v ~= nil and v ~= 0 then
			table.insert(KNOWN_COLLISION_FLAGS, { name = name, value = v })
		end
	end
	return KNOWN_COLLISION_FLAGS
end

-- Decodes a bitmask into a comma-separated string of known flag names.
local function decodeFlags(bits)
	if bits == nil or bits == 0 then return "0x0" end
	local names = {}
	for _, flag in ipairs(getKnownFlags()) do
		if bitAND(bits, flag.value) ~= 0 then
			table.insert(names, flag.name)
		end
	end
	if #names == 0 then return string.format("0x%X (unknown)", bits) end
	return string.format("0x%X  %s", bits, table.concat(names, " | "))
end


function AnimalCollisionController.new(proxy)

	local self = setmetatable({}, AnimalCollisionController_mt)

	self.hasFrontCollision, self.hasGroundHighCollision, self.hasGroundLowCollision, self.hasLeftCollision, self.hasRightCollision, self.hadLeftCollision, self.hadRightCollision = false, false, false, false, false, false, false
	self.height, self.radius = 1, 0.5
	self.proxy = proxy
	self.debugHitInfo = { front = nil, left = nil, right = nil, groundLow = nil }
	self.discoveryHits = {}

	return self

end


function AnimalCollisionController:load(rootNode, animalTypeIndex, age)

	local node = g_animalManager:getCollisionController(animalTypeIndex)
	link(rootNode, node)

	-- young animals should have smaller navMeshAgent attributes. default attributes are intended for adults
	local isYoung = age < (AnimalManager.ANIMAL_TYPE_INDEX_TO_AGE_OFFSET[animalTypeIndex] or 12)
	if isYoung then
		self.height, self.radius = self.height * 0.5, self.radius * 0.75
		setScale(node, self.radius, self.height, self.radius)
	end

	setTranslation(node, 0, self.height / 2 + 0.15, self.radius * 1.5)

	-- Behavior radius: separation / yield code uses this (species-tuned), independent
	-- of the physics probe geometry above which stays driven by engine navMeshAgent.
	local cfg = AnimalSpeciesConfig ~= nil and AnimalSpeciesConfig.get(animalTypeIndex) or nil
	self.behaviorRadius = (cfg and cfg.radius) or self.radius
	if isYoung then self.behaviorRadius = self.behaviorRadius * 0.75 end
	
	self.frontCollision = getChild(node, "frontCollision")
	self.leftCollision = getChild(node, "leftCollision")
	self.rightCollision = getChild(node, "rightCollision")
	self.groundCollisionLow = getChild(node, "groundCollisionLow")
	self.groundCollisionHigh = getChild(node, "groundCollisionHigh")
	self.playerCollision = getChild(node, "playerCollision")

	if self.proxy ~= nil then
		removeFromPhysics(self.proxy)
	end
	local proxyI3D = g_animalManager:getCollisionProxy(animalTypeIndex)
	link(rootNode, proxyI3D)
	setScale(proxyI3D, self.radius, self.height, self.radius)
	setTranslation(proxyI3D, 0, 0, -self.radius * 0.5)
	self.proxy = getChildAt(proxyI3D, 0)
	addToPhysics(self.proxy)

end


function AnimalCollisionController:setAttributes(height, radius)

	self.height, self.radius = height, radius

end


function AnimalCollisionController:onOverlapFrontConvexCallback(node)

	if node ~= self.proxy and g_animalManager.collisionNodes[node] == nil then

		if isTriggerNode(node) then return end

		-- Player-specific detection: walk up the parent chain to the local
		-- player's root. When the front probe overlaps the player, route
		-- it to a separate flag instead of hasFrontCollision. The regular
		-- collision branch in HerdableAnimal toggles isIdle each tick the
		-- overlap flips state, producing visible vibration as the player
		-- shuffles around the animal. The pre-translation skip in
		-- updateRelativeToPlayers reads this flag instead and freezes the
		-- position write before it can move INTO the player.
		local playerRoot = g_localPlayer ~= nil and g_localPlayer.rootNode or nil
		if playerRoot ~= nil and playerRoot ~= 0 then
			local n = node
			for _ = 1, 6 do
				if n == playerRoot then
					self.hasFrontPlayerCollision = true
					if g_animalManager.collisionDebugEnabled and self.debugHitInfo.front == nil then
						self.debugHitInfo.front = { type = "Player", name = "g_localPlayer.rootNode" }
					end
					return true
				end
				local p = getParent(n)
				if p == nil or p == 0 then break end
				n = p
			end
		end

		self.hasFrontCollision = true

		if g_animalManager.collisionDebugEnabled and self.debugHitInfo.front == nil then
			local rbType, nodeName = classifyNode(node)
			self.debugHitInfo.front = { type = rbType, name = nodeName }
		end

		return true

	end

end


function AnimalCollisionController:onOverlapLeftConvexCallback(node)

	if node ~= self.proxy and g_animalManager.collisionNodes[node] == nil then

		if isTriggerNode(node) then return end

		self.hasLeftCollision = true

		if g_animalManager.collisionDebugEnabled and self.debugHitInfo.left == nil then
			local rbType, nodeName = classifyNode(node)
			self.debugHitInfo.left = { type = rbType, name = nodeName }
		end

		return true

	end

end


function AnimalCollisionController:onOverlapRightConvexCallback(node)

	if node ~= self.proxy and g_animalManager.collisionNodes[node] == nil then

		if isTriggerNode(node) then return end

		self.hasRightCollision = true

		if g_animalManager.collisionDebugEnabled and self.debugHitInfo.right == nil then
			local rbType, nodeName = classifyNode(node)
			self.debugHitInfo.right = { type = rbType, name = nodeName }
		end

		return true

	end

end


function AnimalCollisionController:onOverlapGroundLowConvexCallback(node)

	if node ~= self.proxy then

		self.hasGroundLowCollision = true

		if g_animalManager.collisionDebugEnabled and self.debugHitInfo.groundLow == nil then
			local rbType, nodeName = classifyNode(node)
			self.debugHitInfo.groundLow = { type = rbType, name = nodeName }
		end

		return true

	end

end


function AnimalCollisionController:onOverlapGroundHighConvexCallback(node)

	if node ~= self.proxy then

		self.hasGroundHighCollision = true
		return true

	end

end


function AnimalCollisionController:onOverlapPlayerConvexCallback()

	return true

end


function AnimalCollisionController:onOverlapConvexCallbackTemp(node)

	self.hasTempCollision = true
	return true

end


function AnimalCollisionController:onDiscoveryCallback(node)

	if node == self.proxy then return end

	-- Skip pure trigger volumes — they are not walkable obstacles
	local name = getName(node)
	if name ~= nil and string.find(string.lower(name), "trigger") then return end

	-- Only record up to 8 unique nodes to keep the overlay readable
	if #self.discoveryHits >= 8 then return end
	for _, entry in ipairs(self.discoveryHits) do
		if entry.node == node then return end
	end

	local rbType = getRigidBodyType(node) or "Unknown"
	local group  = (getCollisionFilterGroup ~= nil and getCollisionFilterGroup(node)) or 0
	local mask   = (getCollisionFilterMask  ~= nil and getCollisionFilterMask(node))  or 0

	table.insert(self.discoveryHits, {
		node    = node,
		name    = name or "?",
		rbType  = rbType,
		group   = group,
		mask    = mask,
	})

end


-- Broad sphere sweep centered on the animal body; catches objects the directional probes miss.
-- Call once per debug visualise frame.
function AnimalCollisionController:updateDiscoveryProbe(x, y, z)

	self.discoveryHits = {}
	overlapSphere(x, y + self.height * 0.5, z, math.max(self.radius * 3, 1.5), "onDiscoveryCallback", self, DISCOVERY_SWEEP_FLAG)

end


function AnimalCollisionController:updateCollisions(updateTurningCollisions)

	self.hasFrontCollision, self.hasGroundLowCollision, self.hasGroundHighCollision = false, false, false
	-- Reset player-specific front-collision flag too. Read by HerdableAnimal
	-- the next frame to skip the position update before it pushes INTO the
	-- player (the toggle that produces visible vibration).
	self.hasFrontPlayerCollision = false

	if g_animalManager.collisionDebugEnabled then
		self.debugHitInfo = { front = nil, left = nil, right = nil, groundLow = nil }
	end

	overlapConvex(self.frontCollision, "onOverlapFrontConvexCallback", self, collisionFlag)
	overlapConvex(self.groundCollisionLow, "onOverlapGroundLowConvexCallback", self, groundLowCollisionFlag)

	if updateTurningCollisions then

		self.hadLeftCollision, self.hadRightCollision = self.hasLeftCollision, self.hasRightCollision
		self.hasLeftCollision, self.hasRightCollision = false, false

		overlapConvex(self.leftCollision, "onOverlapLeftConvexCallback", self, collisionFlag)
		overlapConvex(self.rightCollision, "onOverlapRightConvexCallback", self, collisionFlag)

	end

	--if self.hasGroundLowCollision then overlapConvex(self.groundCollisionHigh, "onOverlapGroundHighConvexCallback", self, collisionFlag) end

end


function AnimalCollisionController:getHasFrontPlayerCollision()

	return self.hasFrontPlayerCollision == true

end


function AnimalCollisionController:getHasPlayerInVicinity()

	return overlapConvex(self.playerCollision, "onOverlapPlayerConvexCallback", self, CollisionFlag.PLAYER) > 0

end


function AnimalCollisionController:getHasCollisionAtPosition(x, y, z, rx, ry, rz)

	self.hasTempCollision = false
	overlapBox(x, y + self.height / 2, z, rx, ry, rz, self.radius, self.height, self.radius, "onOverlapConvexCallbackTemp", self, CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.BUILDING)

	return self.hasTempCollision

end


function AnimalCollisionController:getHasCollision()

	return self.hasFrontCollision, self.hasGroundLowCollision

end


function AnimalCollisionController:getCanTurnLeft()

	local canTurn = true

	if self.hasLeftCollision or self.hadLeftCollision then canTurn = false end

	return canTurn

end


function AnimalCollisionController:getCanTurnRight()

	local canTurn = true

	if self.hasRightCollision or self.hadRightCollision then canTurn = false end

	return canTurn

end


function AnimalCollisionController:visualise(info, x, y, z, rx, ry, rz)

	local dx, dz = MathUtil.getDirectionFromYRotation(ry)
	DebugUtil.drawOverlapBox(x + dx * self.radius * 2, y + self.height / 2, z + dz * self.radius * 2, rx, ry, rz, self.radius / 2, self.height / 2, self.radius / 2, 1, 0, 0)

	table.insert(info, { ["title"] = "Collision", ["content"] = {} })
	local infoIndex = #info

	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "hasFrontCollision = ", ["value"] = tostring(self.hasFrontCollision) })
	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "canTurnLeft = ", ["value"] = tostring(self:getCanTurnLeft()) })
	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "canTurnRight = ", ["value"] = tostring(self:getCanTurnRight()) })
	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "hasGroundLowCollision = ", ["value"] = tostring(self.hasGroundLowCollision) })
	table.insert(info[infoIndex].content, { ["sizeFactor"] = 0.7, ["name"] = "hasPlayerInVicinity = ", ["value"] = tostring(self:getHasPlayerInVicinity()) })

end


function AnimalCollisionController:addCollisionDebugInfo(info)

	-- Section 1: probe results (front/left/right/ground — only detects objects inside collisionFlag)
	table.insert(info, { ["title"] = "Probe Hits  (collisionFlag mask)", ["content"] = {} })
	local probeIdx = #info

	local probes = {
		{ key = "front",     label = "Front" },
		{ key = "left",      label = "Left" },
		{ key = "right",     label = "Right" },
		{ key = "groundLow", label = "Ground" },
	}

	for _, probe in ipairs(probes) do
		local hit = self.debugHitInfo[probe.key]
		local value = hit ~= nil and string.format("%s  [%s]", hit.type, hit.name) or "clear"
		table.insert(info[probeIdx].content, { ["sizeFactor"] = 0.75, ["name"] = probe.label .. ":  ", ["value"] = value })
	end

	local playerNear = self:getHasPlayerInVicinity()
	table.insert(info[probeIdx].content, { ["sizeFactor"] = 0.75, ["name"] = "Player nearby:  ", ["value"] = tostring(playerNear) })

	-- Section 2: discovery sweep results — ALL nodes within ~1.5 m, decoded flags shown
	-- Nodes here that are NOT in section 1 are candidates for a missing collisionFlag group.
	table.insert(info, { ["title"] = "Nearby Nodes  (broad sweep, all flags)", ["content"] = {} })
	local discIdx = #info

	if #self.discoveryHits == 0 then
		table.insert(info[discIdx].content, { ["sizeFactor"] = 0.75, ["name"] = "none", ["value"] = "" })
	else
		for _, entry in ipairs(self.discoveryHits) do
			local inProbe = (self.debugHitInfo.front ~= nil and self.debugHitInfo.front.name == entry.name)
				or (self.debugHitInfo.left  ~= nil and self.debugHitInfo.left.name  == entry.name)
				or (self.debugHitInfo.right ~= nil and self.debugHitInfo.right.name == entry.name)
				or (self.debugHitInfo.groundLow ~= nil and self.debugHitInfo.groundLow.name == entry.name)
			local marker = inProbe and "" or "  *** PROBE MISS ***"
			table.insert(info[discIdx].content, { ["sizeFactor"] = 0.75, ["name"] = entry.name .. "  (" .. entry.rbType .. ")" .. marker, ["value"] = "" })
			table.insert(info[discIdx].content, { ["sizeFactor"] = 0.65, ["name"] = "   group: ", ["value"] = decodeFlags(entry.group) })
			table.insert(info[discIdx].content, { ["sizeFactor"] = 0.65, ["name"] = "   mask:  ", ["value"] = decodeFlags(entry.mask) })
		end
	end

end