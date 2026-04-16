local modName = g_currentModName
local modDirectory = g_currentModDirectory

AHLVehicle = {}

function AHLVehicle.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function AHLVehicle.registerFunctions(vehicleType)
end

function AHLVehicle.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", AHLVehicle)
end

function AHLVehicle:onRegisterActionEvents(isSelected, isOnActiveVehicle)

    if not self.isClient then return end

    if self.ahlActionEvents == nil then self.ahlActionEvents = {} end
    self:clearActionEventsTable(self.ahlActionEvents)

    if isOnActiveVehicle then

        local _, eventId = g_inputBinding:registerActionEvent(
            InputAction.HerdingLite,
            AnimalManager,
            AnimalManager.onToggleHerding,
            false, true, false, true, nil
        )

        self.ahlActionEvents.herding = eventId
        g_animalManager.herdingVehicleEventId = eventId
        g_animalManager.ticksSinceLastHusbandryCheck = 75
        g_animalManager.ticksSinceLastInputForce = 100

    end

end


TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, function(typeManager)

    if typeManager.typeName ~= "vehicle" then return end

    local specName = modName .. ".AHLVehicle"

    if g_specializationManager.specializations[specName] == nil then
        AHLVehicle.className = "AHLVehicle"
        local entry = {
            name = specName,
            className = "AHLVehicle",
            filename = Utils.getFilename("src/vehicles/VehicleHerding.lua", modDirectory)
        }
        g_specializationManager.specializations[specName] = entry
        table.insert(g_specializationManager.sortedSpecializations, entry)
    end

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if SpecializationUtil.hasSpecialization(Enterable, typeEntry.specializations) then
            typeManager:addSpecialization(typeName, specName)
        end
    end

end)
