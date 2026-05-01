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

	-- Map-bridge species (RABBIT from Witcombe; GOOSE / CAT / ALPACA / QUAIL
	-- from Hof Bergmann; DUCK / DUCKWILD / etc. from other map mods) are
	-- intentionally NOT pickup-able. The herding mod only handles the five
	-- base FS25 animal types for the carry-in-hand interaction; other
	-- species can still be HERDED (LSHIFT+N) but not picked up by hand.
	-- This avoids cache-miss crashes on visual indices the engine animal
	-- system doesn't ship by default and keeps the pickup UX scoped to the
	-- animals that have full carry-state support.
	return false

end