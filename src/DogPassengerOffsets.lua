-- Per-vehicle local-space offset for the passenger dog mesh, keyed by the
-- vehicle's xml configFileName (e.g. "$data/vehicles/brand/vehicle.xml" or
-- a mod vehicle's "$moddir$xxx.xml"). Offset is applied via setTranslation
-- on the cloned dog mesh AFTER it's linked under the passenger seat node.
--
-- Default offset is zero — dog sits exactly at the seat-node origin. Add
-- an override here for vehicles where the seat-node origin doesn't put
-- the dog in a sensible pose (e.g. floating above the seat or clipping
-- into the cabin). The in-game console command `setDogPassengerOffset
-- <x> <y> <z>` lets you live-tune the offset on the currently-ridden
-- vehicle and prints the value so you can paste it back in here.

DogPassengerOffsets = {}


local ZERO = { x = 0, y = 0, z = 0 }


-- Map of configFileName → offset. Seed with known vehicles here.
-- Keys should match whatever Vehicle:getConfigFileName() (or equivalent)
-- returns at runtime, which is typically the xml path starting with
-- "$data/" for base-game vehicles and a mod-specific path for mods.
local offsets = {
	-- example: ["$data/vehicles/example/example.xml"] = { x = 0, y = 0.05, z = -0.1 },
}


function DogPassengerOffsets.get(vehicle)

	if vehicle == nil then return ZERO end

	local key
	if type(vehicle.configFileName) == "string" then
		key = vehicle.configFileName
	elseif type(vehicle.xmlFilename) == "string" then
		key = vehicle.xmlFilename
	end

	if key == nil then return ZERO end
	return offsets[key] or ZERO

end


-- Runtime override used by the setDogPassengerOffset console command.
function DogPassengerOffsets.set(vehicle, x, y, z)

	if vehicle == nil then return false end
	local key = vehicle.configFileName or vehicle.xmlFilename
	if type(key) ~= "string" then return false end
	offsets[key] = { x = x or 0, y = y or 0, z = z or 0 }
	return true

end
