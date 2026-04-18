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

    -- If our stored event ID matches what's currently tracked globally, clear the
    -- global reference before we unregister it so later setActionEvent* calls don't
    -- target a stale event after tabbing between vehicles.
    local storedHerding = self.ahlActionEvents.herding
    if storedHerding ~= nil and g_animalManager.herdingVehicleEventId == storedHerding then
        g_animalManager.herdingVehicleEventId = nil
    end

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

    end

    -- Whether we entered or left the active vehicle, force an immediate
    -- husbandry-range re-check so the prompt state reflects the new context.
    g_animalManager.ticksSinceLastHusbandryCheck = 75
    g_animalManager.ticksSinceLastInputForce = 100

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
