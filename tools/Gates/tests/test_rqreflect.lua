-- RQReflect fixture - verifies a missing world cell is a normal lifecycle
-- state and that a loaded cell still contributes nearby zombie evidence.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQReflect: " .. message)
    end
end

local handlers = {}
local function event()
    return { Add = function(fn) handlers[#handlers + 1] = fn end }
end

Events = {
    OnPlayerGetDamage = event(),
    OnKeyPressed = event(),
    OnTick = event(),
    OnServerCommand = event(),
    OnGameStart = event(),
}

function isClient() return true end
function getTimestampMs() return 10000 end

local player = {
    getX = function() return 100 end,
    getY = function() return 200 end,
    getZ = function() return 0 end,
    getVehicle = function() return nil end,
}
function getPlayer() return player end

local cell = nil
function getCell() return cell end

RQCommon = { MODULE = "RFTD", acceptsModule = function() return true end }
RQRegistry = { activeZombies = {}, getType = function() return nil end }
RQReconcile = { lastKnownPos = {} }
RQCore = { findZombieByID = function() return nil end }

local logs, commands = {}, {}
RQReflectLog = { writeAll = function(lines) logs[#logs + 1] = lines end, write = function() end }
function sendClientCommand(module, command, args)
    commands[#commands + 1] = { module = module, command = command, args = args }
end

local realRequire = require
require = function(name)
    if name == "RQReflectLog" then return RQReflectLog end
    return realRequire(name)
end
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))

RQReflect.mark("cell-missing")
check(logs[1] and logs[1][2] == " SEEN unavailable (world cell unavailable)",
    "missing currentCell emits an explicit unavailable line")
check(commands[1] and commands[1].command == "reflectPing" and commands[1].args.reason == "cell-missing",
    "missing currentCell does not suppress the paired server ping")

local zombie = {
    getX = function() return 103 end,
    getY = function() return 204 end,
    getZ = function() return 0 end,
    getOnlineID = function() return 42 end,
    getTarget = function() return nil end,
    isDead = function() return false end,
}
local zombies = {
    size = function() return 1 end,
    get = function(_, index) if index == 0 then return zombie end end,
}
cell = { getZombieList = function() return zombies end }

RQReflect.mark("cell-ready")
local second = logs[2] or {}
check(second[2] and second[2]:find(" SEEN id=42", 1, true) ~= nil,
    "loaded currentCell contributes nearby zombie evidence")
check(not (second[2] and second[2]:find("unavailable", 1, true)),
    "loaded currentCell does not emit the unavailable line")

print(string.format("RQReflect: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
