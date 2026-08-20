-- RQGlutton fixture - owned-client corpse path hints are retryable and visible.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQGlutton.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQGlutton: " .. message)
    end
end

local zombieCallbacks = {}
Events = { OnZombieUpdate = { Add = function(fn) zombieCallbacks[#zombieCallbacks + 1] = fn end } }

local logs, commands = {}, {}
RQDirgeLog = { write = function(_, line) logs[#logs + 1] = line end }
RQCommon = { MODULE = "RFTDDirge" }
RQRing = { clear = function() end }
function isClient() return true end
function getTimeInMillis() return now end
function sendClientCommand(module, command, args)
    commands[#commands + 1] = { module = module, command = command, args = args }
end
function getCell() return nil end
function ZombRandFloat(_, _) return 1.0 end

RQGlutton = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#zombieCallbacks == 1, "module registers one zombie-update handler")

local function makeZombie(id, pathFn)
    local variables = {}
    return {
        variables = variables,
        getOnlineID = function() return id end,
        getModData = function() return {} end,
        isRemoteZombie = function() return false end,
        isDead = function() return false end,
        clearAggroList = function() end,
        setTarget = function() end,
        getX = function() return 0 end,
        getY = function() return 0 end,
        getZ = function() return 0 end,
        setUseless = function(_, value) variables.useless = value end,
        setVariable = function(_, key, value) variables[key] = value end,
        pathToSound = pathFn,
    }
end

now = 1000
local pathCalls = 0
-- A FAULTED PATH HINT IS A NO-OP, NOT A THROW. pathToSound reaches currentCell
-- and PolygonalMap2 with no complete precondition (IsoGameCharacter.java:
-- 5912-5930, 5964-5966; PathFindBehavior2.java:252-257), so the fault is real -
-- but pathToSound is an exposed method, so MethodCaller catches the throw,
-- stack-traces it, and the call simply returns (MethodCaller.java:33-56).
-- Corrected 2026-08-19; this used to call error(), which made `ok` look
-- reachable and kept an unreachable logging arm alive in production.
--
-- The retry property is what actually matters and it is unchanged: a faulted
-- attempt no-ops and the next interval is fresh valid work.
local failingZombie = makeZombie(77, function()
    pathCalls = pathCalls + 1
    return nil
end)
RQGlutton.startEating(failingZombie, 77, 10, 11, 0)
zombieCallbacks[1](failingZombie)
now = 2600
zombieCallbacks[1](failingZombie)
local pathFailureLogs = 0
for i = 1, #logs do
    if string.find(logs[i], "pathToSound failed", 1, true) then
        pathFailureLogs = pathFailureLogs + 1
    end
end
check(pathCalls == 2, "failed corpse path hints are retried on later intervals")
check(pathFailureLogs == 0,
      "and log nothing: the fault never reaches Lua, so the engine's own trace is "
      .. "the only honest diagnostic")

now = 5000
local success = {}
local movingZombie = makeZombie(88, function(_, x, y, z)
    success = { x = x, y = y, z = z }
end)
RQGlutton.startEating(movingZombie, 88, 20, 21, 0)
zombieCallbacks[1](movingZombie)
check(success.x == 20 and success.y == 21 and success.z == 0,
    "owned glutton sends direct corpse coordinates to pathToSound")

print(string.format("RQGlutton: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
