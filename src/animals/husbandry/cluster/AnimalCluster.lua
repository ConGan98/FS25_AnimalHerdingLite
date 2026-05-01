function AnimalCluster:getCanBePickedUp()

	local animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(self.subTypeIndex)

	if animalTypeIndex == AnimalType.COW then return self.age < 3 end
	if animalTypeIndex == AnimalType.PIG then return self.age < 3 end
	if animalTypeIndex == AnimalType.SHEEP then return self.age < 3 end
	if animalTypeIndex == AnimalType.HORSE then return false end
	if animalTypeIndex == AnimalType.CHICKEN then return self.age < 60 end

	-- Map-bridge species (RABBIT / GOOSE / CAT / ALPACA / QUAIL / etc.)
	-- intentionally NOT pickup-able — see Animal.lua comment for rationale.
	return false

end