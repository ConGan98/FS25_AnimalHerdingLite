HerdingPlayerSyncEvent = {}

local HerdingPlayerSyncEvent_mt = Class(HerdingPlayerSyncEvent, Event)
InitEventClass(HerdingPlayerSyncEvent, "HerdingPlayerSyncEvent")


function HerdingPlayerSyncEvent.emptyNew()
    local self = Event.new(HerdingPlayerSyncEvent_mt)
    return self
end


function HerdingPlayerSyncEvent.new()

    local self = HerdingPlayerSyncEvent.emptyNew()

    return self

end


function HerdingPlayerSyncEvent:readStream(streamId, connection)

    -- sync player positions for animal direction calculation

    local playerPositions = {}
    local farms = g_animalManager.farms
    local numFarms = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)

    for i = 1, numFarms do
    
        local farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        local numPositions = streamReadUIntN(streamId, 5)
        local positions = {}

        for j = 1, numPositions do

            local x = streamReadFloat32(streamId)
            local z = streamReadFloat32(streamId)
            local hasBucket = streamReadBool(streamId)
            local isVehicle = streamReadBool(streamId)

            table.insert(positions, { x, z, hasBucket, isVehicle })

        end

        -- Two race windows where the client-side farm record may not yet
        -- exist for an inbound player-sync: (a) mid-join, before the
        -- HerdingEvent initial-state burst lands, and (b) cross-farm,
        -- where the per-farm HerdingEvent for a newly-started farm hasn't
        -- been processed yet. Bytes are already consumed above; just
        -- skip the assignment if the record isn't there.
        if farms[farmId] ~= nil then farms[farmId].players = positions end
        playerPositions[farmId] = positions

    end

    g_animalManager.playerPositions = playerPositions

end


function HerdingPlayerSyncEvent:writeStream(streamId, connection)

    -- Mirror the guard in HerdingSyncEvent: skip clients that haven't
    -- finished receiving their initial state. Without this, a tick can
    -- broadcast a player-sync to a connection in g_server.clientConnections
    -- whose HerdingEvent initial-state burst hasn't been queued yet —
    -- reader would crash on missing farm records.
    if not g_animalManager:getIsConnectionInitialised(connection) then return end

    local playerPositions = g_animalManager.playerPositions
    local numFarms = 0

    for farmId, _ in pairs(playerPositions) do numFarms = numFarms + 1 end

    streamWriteUIntN(streamId, numFarms, FarmManager.FARM_ID_SEND_NUM_BITS)

    for farmId, positions in pairs(playerPositions) do

        streamWriteUIntN(streamId, farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteUIntN(streamId, #positions, 5)

        for _, position in ipairs(positions) do

            streamWriteFloat32(streamId, position[1])
            streamWriteFloat32(streamId, position[2])
            streamWriteBool(streamId, position[3]) -- is carrying feed bucket
            streamWriteBool(streamId, position[4] or false) -- is vehicle

        end

    end

end


function HerdingPlayerSyncEvent:run(connection)



end