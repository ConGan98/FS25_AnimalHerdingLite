DogHerdingRequestEvent = {}

local DogHerdingRequestEvent_mt = Class(DogHerdingRequestEvent, Event)
InitEventClass(DogHerdingRequestEvent, "DogHerdingRequestEvent")


function DogHerdingRequestEvent.emptyNew()
    local self = Event.new(DogHerdingRequestEvent_mt)
    return self
end


function DogHerdingRequestEvent.new(enable, farmId)

    local self = DogHerdingRequestEvent.emptyNew()

    self.enable = enable
    self.farmId = farmId

    return self

end


function DogHerdingRequestEvent:readStream(streamId, connection)

    if not connection:getIsServer() then
        self.enable = streamReadBool(streamId)
        self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self:run(connection)
    end

end


function DogHerdingRequestEvent:writeStream(streamId, connection)

    if connection:getIsServer() then
        streamWriteBool(streamId, self.enable or false)
        streamWriteUIntN(streamId, self.farmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
    end

end


function DogHerdingRequestEvent:run(connection)

    if g_dogHerding == nil then return end

    if self.enable then
        g_dogHerding:activate(self.farmId)
    else
        g_dogHerding:deactivate(self.farmId)
    end

end
