-- ASScale fixture - a foreign craftRecipe getter cannot break the global timed
-- action hook, and its first failure is visible without becoming a log stream.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds/42/media/lua/shared/ActionSpeed/ASScale.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL ASScale: " .. message) end
end

local callbacks = { gameStart = nil }
Events = {
    OnGameStart = { Add = function(fn) callbacks.gameStart = fn end },
    OnServerStarted = { Add = function() end },
}
function isServer() return false end
ISBaseTimedAction = { adjustMaxTime = function(_, maxTime) return maxTime end }
OEShared = { enabled = function() return true end }
SandboxVars = { RFTDOddsAndEnds = { ASThread = 4 } }
function require(name)
    if name == "TimedActions/ISBaseTimedAction" then return ISBaseTimedAction end
    if name == "OEShared" then return OEShared end
    error("unexpected require: " .. tostring(name))
end

local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(callbacks.gameStart) == "function", "registers its game-start installer")
callbacks.gameStart()

local action = { Type = "ISHandcraftAction", craftRecipe = { getName = function() error("foreign recipe fault") end } }
local realPrint, warnings = print, {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
local first = ISBaseTimedAction.adjustMaxTime(action, 100)
local second = ISBaseTimedAction.adjustMaxTime(action, 100)
print = realPrint

check(first == 100 and second == 100, "a broken recipe getter leaves only that action vanilla-speed")
check(#warnings == 1 and warnings[1]:find("recipe lookup failed", 1, true)
    and warnings[1]:find("foreign recipe fault", 1, true),
    "a broken recipe getter emits one bounded diagnostic")

print(string.format("ASScale: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
