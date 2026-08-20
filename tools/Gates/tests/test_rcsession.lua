-- test_rcsession.lua - hourly loaded-vehicle pass fault isolation.
--
-- One car can be in a teardown/foreign-mod failure state. It must not prevent
-- later cars from reconciling, and the pass must leave a bounded diagnostic
-- instead of silently discarding the failed unit.

local ROOT = arg[1] or "."
local HELPER = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCLoadedVehicles.lua"
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCSession.lua"

local pass, fail = 0, 0
local realPrint = print
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

function isServer() return true end
require = function() end
local handlers = {}
local function event(name)
    return { Add = function(fn) handlers[name] = fn end }
end
Events = {
    EveryTenMinutes = event("EveryTenMinutes"),
    EveryHours = event("EveryHours"),
    OnServerStarted = event("OnServerStarted"),
}

local diagnostics, reconciled, considered, observed = {}, {}, {}, {}
local vehicles = { { name = "bad", bad = true }, { name = "remove" }, { name = "good" } }
local collectionVersion = 0
function print(message) diagnostics[#diagnostics + 1] = tostring(message) end
RCShared = {
    cfg = function()
        return { enabled = true, claimsEnabled = true, janitorEnabled = true,
                 respawnOnDestroy = true }
    end,
    need = function(_, value) return value ~= nil end,
    dbg = function() end,
}
RCRegistry = {
    heartbeat = function() end,
    stampSeen = function() end,
    notePresence = function() end,
    pruneOrphans = function() end,
    prunePendingRelease = function() end,
    prunePresence = function() end,
    syncFromVehicle = function(vehicle)
        if vehicle.bad then error("simulated vehicle fault") end
        reconciled[#reconciled + 1] = vehicle.name
    end,
}
RCJanitor = {
    beginSweep = function() end,
    consider = function(vehicle)
        considered[#considered + 1] = vehicle.name
        if vehicle.name == "remove" then
            for i = #vehicles, 1, -1 do
                if vehicles[i] == vehicle then table.remove(vehicles, i) end
            end
            collectionVersion = collectionVersion + 1
        end
    end,
}
RCRespawn = {
    observe = function(vehicle) observed[#observed + 1] = vehicle.name end,
    sweep = function() end,
}

function getCell()
    local index = 0
    return {
        getVehicles = function()
            return {
                iterator = function()
                    local expectedVersion = collectionVersion
                    return {
                        hasNext = function()
                            if collectionVersion ~= expectedVersion then
                                error("ConcurrentModificationException")
                            end
                            return index < #vehicles
                        end,
                        next = function()
                            if collectionVersion ~= expectedVersion then
                                error("ConcurrentModificationException")
                            end
                            index = index + 1
                            return vehicles[index]
                        end,
                    }
                end,
            }
        end,
    }
end
function getOnlinePlayers()
    return { size = function() return 0 end }
end

local okLoad, loadErr = pcall(dofile, HELPER)
if okLoad then okLoad, loadErr = pcall(dofile, TARGET) end
if not okLoad then
    realPrint("FATAL: could not load " .. TARGET)
    realPrint("  " .. tostring(loadErr))
    os.exit(2)
end

local okRun, runErr = pcall(handlers.EveryHours)
eq("hourly event itself remains contained", okRun, true)
eq("mutating vehicle is reconciled before janitor removal", reconciled[1], "remove")
eq("later vehicle reconciles after prior failure and Set mutation", reconciled[2], "good")
eq("later vehicle reaches janitor", considered[2], "good")
eq("later vehicle reaches destruction observer", observed[2], "good")
eq("one bounded failure diagnostic is emitted", #diagnostics, 1)
eq("diagnostic counts failed and visited vehicles",
    diagnostics[1]:find("1 of 3 vehicle%(s%) failed", 1) ~= nil, true)
eq("diagnostic retains first failure", diagnostics[1]:find("simulated vehicle fault", 1, true) ~= nil, true)

realPrint(string.format("RCSession: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
