FSBaseMission.onStartMission = Utils.prependedFunction(FSBaseMission.onStartMission, function(self)

	g_animalManager:validateConflicts()
	g_animalManager:configureCollisionControllerOffsets()
	g_animalManager:load()

	self:addUpdateable(g_animalManager)
	self:addDrawable(g_animalManager)

	g_dogHerding = DogHerding.new()
	self:addUpdateable(g_dogHerding)

end)


FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function(self)

	g_animalManager:setHerdingInputData()
	g_animalManager:postLoad()

end)


FSBaseMission.sendInitialClientState = Utils.prependedFunction(FSBaseMission.sendInitialClientState, function(self, connection)

    if g_animalManager.herdingEnabled then connection:sendEvent(HerdingEvent.new()) end

	g_animalManager:setConnectionInitialised(connection)

end)