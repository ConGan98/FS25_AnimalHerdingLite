function AnimalCluster:getCanBePickedUp()

	local animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(self.subTypeIndex)

	if animalTypeIndex == AnimalType.COW then return self.age < 3 end
	if animalTypeIndex == AnimalType.PIG then return self.age < 3 end
	if animalTypeIndex == AnimalType.SHEEP then return self.age < 3 end
	if animalTypeIndex == AnimalType.HORSE then return false end
	if animalTypeIndex == AnimalType.CHICKEN then return self.age < 60 end

	return self.age < 6

end