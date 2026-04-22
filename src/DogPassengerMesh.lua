-- Cloned animated dog mesh used when the player's companion dog rides as
-- a passenger in a vehicle (see DogHerding.lua). The live FS25 companion
-- dog's rendering ignores scene-graph parenting, so a direct reparent of
-- the companion's node under a vehicle seat node does nothing — we have
-- to render a second, mod-owned mesh and hide the live companion.
--
-- The game ships animated dog i3ds (labradorRetriever.i3d, borderCollie.i3d)
-- which already contain the skeleton + clip library (including `sitSource`).
-- We load one of those, get the animation character set from its skeleton,
-- assign the sit clip to track 0, and link the loaded root under the
-- vehicle's passenger seat node. The engine then renders the mesh with
-- the sit animation playing and transforms it with the vehicle.
--
-- The *posed* variants (labradorRetriever_posed.i3d etc.) would be ~100x
-- smaller but carry no skeleton so they can't play any animation.

DogPassengerMesh = {}


-- FS25's engine loader accepts bare `dataS/...` paths directly and
-- resolves them against the game data directory. The `$dataS/` prefix
-- is for XML-embedded filenames (which get run through Utils.getFilename);
-- loadSharedI3DFile doesn't expand `$` and returns failedReason=2 when it
-- sees one. Confirmed by observing engine's own asset loads in the log:
--   "dataS/character/playerM/attachments/headgearMotorbike.i3d (14.30 ms)"
local LABRADOR_I3D     = "dataS/character/animals/domesticated/dog/labradorRetriever/labradorRetriever.i3d"
local BORDER_COLLIE_I3D = "dataS/character/animals/domesticated/dog/borderCollie/borderCollie.i3d"

local SIT_CLIP_NAME = "sitSource"


-- Pick the i3d path based on the dog instance's xml filename. Falls back
-- to labrador if the breed can't be inferred.
local function i3dPathForDog(dog)
	local xml = (dog and dog.xmlFilename) or ""
	if xml:find("borderCollie", 1, true) then return BORDER_COLLIE_I3D end
	return LABRADOR_I3D
end


-- Load the animated dog i3d, attach the sit clip on track 0, and return
-- a table describing the cloned mesh. Caller should:
--   1) Link `instance.root` under a seat node.
--   2) setTranslation / setRotation on `instance.root` for the offset.
--   3) Eventually call DogPassengerMesh.release(instance) to clean up.
function DogPassengerMesh.acquire(dog)

	local path = i3dPathForDog(dog)

	-- loadSharedI3DFile returns three values: node, sharedLoadRequestId,
	-- failedReason. The request id is REQUIRED for correct cleanup via
	-- releaseSharedI3DFile — just calling delete() on the node leaks the
	-- shared reference.
	local root, sharedLoadRequestId, failedReason
	local ok, err = pcall(function()
		root, sharedLoadRequestId, failedReason = g_i3DManager:loadSharedI3DFile(path, false, false)
	end)
	if not ok then
		Logging.warning("[DogPassengerMesh] loadSharedI3DFile threw: %s (path=%s)", tostring(err), tostring(path))
		return nil
	end
	if root == nil or root == 0 then
		Logging.warning("[DogPassengerMesh] loadSharedI3DFile returned 0/nil: path=%s failedReason=%s",
			tostring(path), tostring(failedReason))
		return nil
	end

	-- Re-link to our control root so we own the lifetime; caller will
	-- re-link under the vehicle seat next.
	link(getRootNode(), root)
	setVisibility(root, true)

	-- Dog XMLs declare skeletonNode="0" — skeleton is child[0] of the
	-- loaded i3d root. The animation character set is attached at the
	-- skeleton (or at its child[0] "skin" node for some species).
	local skeletonNode = getChildAt(root, 0)
	if skeletonNode == nil or skeletonNode == 0 then
		Logging.warning("[DogPassengerMesh] could not resolve skeleton child at %s", path)
		delete(root)
		return nil
	end

	-- Try skin (child of skeleton) first, fall back to skeleton itself.
	local skinNode = getChildAt(skeletonNode, 0)
	local animationSet = 0
	if skinNode ~= nil and skinNode ~= 0 then animationSet = getAnimCharacterSet(skinNode) end
	if animationSet == 0 then animationSet = getAnimCharacterSet(skeletonNode) end

	if animationSet ~= 0 then
		local sitIndex = getAnimClipIndex(animationSet, SIT_CLIP_NAME)
		if sitIndex ~= nil and sitIndex >= 0 then
			clearAnimTrackClip(animationSet, 0)
			assignAnimTrackClip(animationSet, 0, sitIndex)
			setAnimTrackLoopState(animationSet, 0, true)
			setAnimTrackBlendWeight(animationSet, 0, 1)
			enableAnimTrack(animationSet, 0)
			setAnimTrackSpeedScale(animationSet, 0, 1)
		end
	end

	return {
		root = root,
		animationSet = animationSet,
		sharedLoadRequestId = sharedLoadRequestId,
		path = path
	}

end


-- Clean up a cloned mesh instance. Safe to call with nil.
-- Unlinks from whatever parent the mesh is currently under (typically the
-- vehicle's passenger seat node) BEFORE deleting — delete() on a node
-- that's still part of another object's scene graph can crash when the
-- parent is later iterated / serialised.
--
-- The shared-i3d reference is NOT released here — doing so during the
-- vehicle-exit path crashed the game. The caller (DogHerding) defers the
-- release to a later tick via its pending-release queue.
function DogPassengerMesh.release(instance)

	if instance == nil then return nil end

	local root = instance.root
	local requestId = instance.sharedLoadRequestId
	local animSet = instance.animationSet
	instance.root = nil
	instance.animationSet = nil
	instance.sharedLoadRequestId = nil

	if root ~= nil and root ~= 0 then
		if animSet ~= nil and animSet ~= 0 then
			pcall(disableAnimTrack, animSet, 0)
		end
		pcall(link, getRootNode(), root)
		local ok, exists = pcall(entityExists, root)
		if ok and exists then
			local okD, errD = pcall(delete, root)
			if not okD then Logging.warning("[DogPassengerMesh] release: delete failed: %s", tostring(errD)) end
		end
	end

	-- Return the pending shared-load request id so DogHerding can schedule
	-- its deferred release. Caller may drop nil safely.
	return requestId

end
