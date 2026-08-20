-- RDForage fixture - mandatory forage events are registered directly before
-- observers attach, while the optional forensic sensor stays non-invasive.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/server/RDForage.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RDForage: " .. message) end
end

function isServer() return true end
RDShared = {}
local records = {}
RDLog = {
    forensic = function(stream, event, player, payload, owner)
        records[#records + 1] = { stream, event, player, payload, owner }
    end,
}
function require(name)
    if name == "RDShared" then return RDShared end
    if name == "RDLog" then return RDLog end
    error("unexpected require: " .. tostring(name))
end

local listeners, registrationOrder = {}, {}
Events = {}
LuaEventManager = {
    AddEvent = function(name)
        registrationOrder[#registrationOrder + 1] = name
        Events[name] = Events[name] or {
            Add = function(fn)
                listeners[name] = fn
            end,
        }
    end,
}

RDForage = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(registrationOrder[1] == "OnForageRequestZone" and registrationOrder[2] == "OnForageSpot",
    "registers both mandatory events directly before observers attach")
check(type(listeners.OnForageRequestZone) == "function" and type(listeners.OnForageSpot) == "function",
    "attaches both server observers after registration")

local player = { getX = function() return 12.9 end, getY = function() return 33.1 end, getZ = function() return 0 end }
listeners.OnForageRequestZone(player, string.rep("a", 257))
check(#records == 1 and records[1][1] == "forage" and records[1][2] == "RD.FORAGE_ZONE",
    "registered request event writes a forage record")
check(records[1][4].x == 12 and records[1][4].y == 33 and #records[1][4].focus == 257,
    "record keeps position and bounds untrusted focus text")

print(string.format("RDForage: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
