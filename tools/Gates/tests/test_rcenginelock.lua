-- RCEngineLock fixture - vanilla completion commits before its secondary
-- audit send, and a failed send cannot change the completed result.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/client/RCEngineLock.lua"

local realPrint = print
local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL RCEngineLock: " .. message)
    end
end

function isServer() return false end
function isClient() return true end
function getText(key) return key end

RCShared = {
    MODULE = "Reclamation",
    cfg = function() return { enabled = true, engineLockEnabled = true } end,
    isAdmin = function() return false end,
    halo = function() end,
    dbg = function() end,
}

local gameStart
Events = { OnGameStart = { Add = function(fn) gameStart = fn end } }
ISVehicleMechanics = { onTakeEngineParts = function() return "take" end }
ISVehiclePartMenu = { onUninstallPart = function() return "uninstall" end }

local completion = false
local timeline = {}
ISTakeEngineParts = { complete = function()
    timeline[#timeline + 1] = "complete"
    return completion
end }

local sentArgs
function sendClientCommand(_, module, command, args)
    timeline[#timeline + 1] = "send"
    sentArgs = { module = module, command = command, args = args }
end

local vehicle = {
    getScriptName = function() return "Base.TestCar" end,
    getId = function() return 44 end,
    getX = function() return 10.9 end,
    getY = function() return 20.1 end,
    getZ = function() return 0 end,
}
local part = { getVehicle = function() return vehicle end }
local action = { character = { id = "player" }, part = part }

local diagnostics = {}
print = function(message) diagnostics[#diagnostics + 1] = tostring(message) end
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(gameStart) == "function", "registers the delayed wrapper installer")
gameStart()

local result = ISTakeEngineParts.complete(action)
check(result == false and #timeline == 1 and timeline[1] == "complete",
      "a refused vanilla completion sends no audit record")

completion = true
timeline = {}
result = ISTakeEngineParts.complete(action)
check(result == true and timeline[1] == "complete" and timeline[2] == "send",
      "sends only after vanilla completion commits")
check(sentArgs and sentArgs.module == "Reclamation"
      and sentArgs.command == "enginePull" and sentArgs.args.vid == 44
      and sentArgs.args.x == 10 and sentArgs.args.y == 20,
      "sends the completed vehicle identity and floored location")

-- A FAILED AUDIT SEND IS INVISIBLE TO LUA, and that is the contract now.
-- sendClientCommand is an exposed global (LuaManager.java:7219-7236): every
-- fault inside it, including the packet write, is swallowed and stack-traced by
-- MethodCaller before Lua sees anything (MethodCaller.java:33-56;
-- GameClient.java:1741-1760). Corrected 2026-08-19 - this block used to inject
-- error() and then assert on a once-flag diagnostic. Neither could ever fire,
-- so the fixture was pinning dead recovery code into production.
--
-- What is pinned instead: a send that returns nothing still completes the
-- action, and nothing is logged, because the engine's own trace is the
-- diagnostic and a second one from us would be a lie about detection.
local before = #diagnostics
sendClientCommand = function() return nil end
result = ISTakeEngineParts.complete(action)
check(result == true, "a silent audit send preserves completion")
check(#diagnostics == before,
      "and logs nothing - Lua cannot see the failure, so claiming to report it would be false")
result = ISTakeEngineParts.complete(action)
check(result == true and #diagnostics == before,
      "later completed actions remain usable without log flooding")
print = realPrint

realPrint(string.format("RCEngineLock: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
