-- DFPatch_RVInterior.lua — Dragonfly removable third-party patch
--
-- Fixes a per-tick crash in "[B42]PROJECT RV Interior" (RVServerMP_V3.lua).
-- Its GLOBAL UpdateGen() schedules an OnTick that places an RV generator via
--   square:AddSpecialObject(generator)
-- When the target square is in an UNLOADED chunk, square.chunk is null and the
-- native pathfinder (PathfindNative.squareChanged) throws a NullPointerException
-- every time that OnTick fires. RV's own pcall does NOT catch it — that is a
-- native Java exception, which propagates past Lua pcall.
--
-- Fix: redefine the global UpdateGen with ONE change — guard the generator
-- placement behind square:getChunk() so it only runs in a loaded chunk. If the
-- chunk is not loaded, skip (nobody is there to see it; it places correctly the
-- next time the room loads).
--
-- REMOVABLE: delete this file to drop the patch. RV Interior keeps working with
-- its original behaviour; nothing else in Dragonfly depends on this. The body
-- below mirrors RVServerMP_V3.lua:138-201 — if RV rewrites UpdateGen, re-sync.

if not isServer() then return end

local applied = false

local function apply()
    if applied then return end
    if type(UpdateGen) ~= "function" then return end -- RV Interior not present
    applied = true

    UpdateGen = function(data, hasCharge)
        if not data then return end
        local tic = 0
        local function OnTick()
            local function gen()
                Events.OnTick.Remove(OnTick)
                local roomX = data.x
                local roomY = data.y
                local roomZ = data.z
                local vehicleType = data.vType
                local genX = nil
                local genY = nil
                local genFloor = nil
                if vehicleType and VehicleTypes[vehicleType] and VehicleTypes[vehicleType].genX then
                    genX = VehicleTypes[vehicleType].genX
                end
                if vehicleType and VehicleTypes[vehicleType] and VehicleTypes[vehicleType].genY then
                    genY = VehicleTypes[vehicleType].genY
                end
                if vehicleType and VehicleTypes[vehicleType] and VehicleTypes[vehicleType].genFloor then
                    genFloor = VehicleTypes[vehicleType].genFloor
                end
                local square = nil
                if genX and genY and genFloor then
                    pcall(function() square = getCell():getOrCreateGridSquare(roomX + genX, roomY + genY, roomZ + genFloor) end)
                else
                    pcall(function() square = getCell():getOrCreateGridSquare(roomX - 1, roomY - 1, roomZ + 1) end)
                end
                local generator = nil
                if square then
                    pcall(function() generator = square:getGenerator() end)
                    local isNewGen = nil
                    if not generator then
                        local item = nil
                        pcall(function() item = instanceItem("Base.Generator_Yellow") end)
                        pcall(function() generator = IsoGenerator.new(getCell()) end)
                        if generator then
                            pcall(function() generator:setSquare(square) end)
                            if item then
                                pcall(function() generator:setInfoFromItem(item) end)
                                isNewGen = true
                            end
                        end
                    end
                    if generator then
                        pcall(function() generator:setCondition(100) end)
                        pcall(function() generator:setFuel(10) end)
                        pcall(function() generator:setConnected(true) end)
                        pcall(function() generator:setActivated(hasCharge) end)
                        if isNewGen then
                            -- DRAGONFLY FIX: only place in a LOADED chunk. square:getChunk()
                            -- returns nil for an unloaded chunk, which is what made the native
                            -- pathfinder NPE (and the surrounding pcall could not catch it).
                            if square:getChunk() then
                                pcall(function() square:AddSpecialObject(generator) end)
                                pcall(function() generator:transmitCompleteItemToClients() end)
                            end
                        end
                    end
                end
            end
            if tic > 150 then
                Events.OnTick.Remove(OnTick)
                pcall(function() gen() end)
            end
            tic = tic + 1
        end
        Events.OnTick.Add(OnTick)
    end

    print("[Dragonfly] DFPatch_RVInterior applied (RV generator unloaded-chunk guard)")
end

Events.OnServerStarted.Add(apply)
