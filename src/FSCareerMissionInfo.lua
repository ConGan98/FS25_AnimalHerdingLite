-- Prepend: return all carried and herded animals to their husbandries BEFORE placeables
-- are saved, so the cluster system includes them when the husbandry data is written to
-- disk. This also prevents the game from reloading into herding mode after a quit.
FSCareerMissionInfo.saveToXMLFile = Utils.prependedFunction(FSCareerMissionInfo.saveToXMLFile, function(self)

	g_animalManager:returnAllCarriedAnimals()
	g_animalManager:returnAllHerdedAnimals()

end)

-- Append: save herding state (herded animals on the field) after the career data.
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function(self)

	g_animalManager:save(self.savegameDirectory .. "/animalHerding.xml")

end)