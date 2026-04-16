local modName = g_currentModName


TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, function(typeManager)

    if typeManager.typeName ~= "vehicle" then return end

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if SpecializationUtil.hasSpecialization(Enterable, typeEntry.specializations) then
            typeManager:addSpecialization(typeName, modName .. ".AHLVehicle")
        end
    end

end)
