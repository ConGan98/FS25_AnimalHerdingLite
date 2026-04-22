-- Network event for dog-passenger mode (dog rides as passenger in a
-- vehicle). Sent by a client when the local player's dog transitions in
-- or out of passenger mode; server broadcasts to all other clients so
-- each client can apply the visual swap (hide live companion, clone the
-- animated mesh under the vehicle's passenger seat node — or tear it
-- down again on exit).
--
-- Single-direction data flow: client → server → all-other-clients.

DogPassengerEvent = {}

local DogPassengerEvent_mt = Class(DogPassengerEvent, Event)
InitEventClass(DogPassengerEvent, "DogPassengerEvent")


function DogPassengerEvent.emptyNew()
	local self = Event.new(DogPassengerEvent_mt)
	return self
end


function DogPassengerEvent.new(dog, vehicle, enter)

	local self = DogPassengerEvent.emptyNew()
	self.dog = dog
	self.vehicle = vehicle
	self.enter = enter
	return self

end


function DogPassengerEvent:readStream(streamId, connection)

	self.enter = streamReadBool(streamId)
	self.dog = NetworkUtil.readNodeObject(streamId)
	if self.enter then
		self.vehicle = NetworkUtil.readNodeObject(streamId)
	end

	self:run(connection)

	-- Server received from a client: rebroadcast to everyone so every
	-- client runs the visual swap. The originating client's
	-- installPassengerVisual is idempotent (same-vehicle = no-op), so
	-- the echo back to the sender doesn't flicker.
	if connection ~= nil and not connection:getIsServer() and g_server ~= nil then
		g_server:broadcastEvent(self, false)
	end

end


function DogPassengerEvent:writeStream(streamId, connection)

	streamWriteBool(streamId, self.enter and true or false)
	NetworkUtil.writeNodeObject(streamId, self.dog)
	if self.enter then
		NetworkUtil.writeNodeObject(streamId, self.vehicle)
	end

end


function DogPassengerEvent:run(connection)

	if self.dog == nil then return end
	if g_dogHerding == nil then return end

	if self.enter then
		if self.vehicle == nil then return end
		g_dogHerding:applyRemotePassengerEnter(self.dog, self.vehicle)
	else
		g_dogHerding:applyRemotePassengerExit(self.dog)
	end

end


-- Dispatch the event appropriately: if we ARE the server (host or SP),
-- broadcast directly to connected clients; if we're a pure client, send
-- to server which will rebroadcast. Matches the pattern used by
-- AnimalNameEvent.sendEvent and other engine events.
function DogPassengerEvent.sendToServer(dog, vehicle, enter)

	if g_currentMission == nil then return end
	local evt = DogPassengerEvent.new(dog, vehicle, enter)
	if g_currentMission:getIsServer() then
		if g_server ~= nil then g_server:broadcastEvent(evt, false) end
	else
		if g_client ~= nil then g_client:getServerConnection():sendEvent(evt) end
	end

end
