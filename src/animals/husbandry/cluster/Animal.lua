function Animal:getCanBePickedUp()

	local animalTypeIndex
	if self.getAnimalTypeIndex ~= nil then
		animalTypeIndex = self:getAnimalTypeIndex()
	elseif self.subTypeIndex ~= nil then
		animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(self.subTypeIndex)
	end

	local age = self.age or 0

	if animalTypeIndex == AnimalType.HORSE then return false end
	if animalTypeIndex == AnimalType.CHICKEN then return age < 60 end

	if self.weight ~= nil and self.weight > 100 then return false end

	if animalTypeIndex == AnimalType.COW then return age < 3 end
	if animalTypeIndex == AnimalType.PIG then return age < 3 end
	if animalTypeIndex == AnimalType.SHEEP then return age < 3 end

	return true

end