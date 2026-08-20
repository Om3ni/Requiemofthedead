-- LMZeds fixture - zone lifecycle always tells clients to run their local
-- sweep, even when the server has no currently materialized zombies to remove.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/server/LMZeds.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL LMZeds: " .. message) end
end

function isServer() return true end
local zoneListener = nil
Limes = {
    raw = function() return {} end,
    onChanged = function() end,
    onZoneEvent = function(fn) zoneListener = fn end,
    getLocation = function() return nil end,
}
Events = {
    OnZombieCreate = { Add = function() end },
    EveryTenMinutes = { Add = function() end },
    OnServerStarted = { Add = function() end },
}
LMZedsShared = { cull = function() end }
local broadcasts = {}
RDNet = {
    broadcast = function(module, command, args)
        broadcasts[#broadcasts + 1] = { module = module, command = command, args = args }
    end,
}
function require(name)
    if name == "LMCore" then return Limes end
    if name == "LMZedsShared" then return LMZedsShared end
    if name == "RDNet" then return RDNet end
    error("unexpected require: " .. tostring(name))
end

LMZeds = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(zoneListener) == "function", "registers the zone lifecycle listener")

zoneListener("added", "QuietStreet")
check(#broadcasts == 1 and broadcasts[1].module == "RFTDLimes"
    and broadcasts[1].command == "zedsSweep" and broadcasts[1].args.name == "QuietStreet",
    "an added zone broadcasts its client sweep directly")

zoneListener("deleted", "QuietStreet")
check(#broadcasts == 1, "a deleted zone does not request a sweep")

local emptyZombies = { size = function() return 0 end }
local gridCalls = 0
local cell = {
    getZombieList = function() return emptyZombies end,
    getGridSquare = function(_, x, y, z)
        gridCalls = gridCalls + 1
        return (x == 10 and y == 20 and z == 0) and {} or nil
    end,
}
IsoWorld = { instance = { getCell = function() return cell end } }
function getOnlinePlayers() return nil end
local warmZone = { name = "WarmStreet", template = false, rects = { { 10, 20, 10, 20 } }, fields = {} }
Limes.zoneNames = function() return { "WarmStreet" } end
Limes.getZone = function(name) return name == "WarmStreet" and warmZone or nil end
Limes.revision = 1
local report = LMZeds.report()
check(gridCalls > 0 and report.rows[1].observable == true,
    "a cold loaded zone is observable through the direct nullable grid probe")

print(string.format("LMZeds: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
