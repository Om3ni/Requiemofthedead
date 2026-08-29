-- RDStall fixture - alert context reads the current player count directly and
-- keeps the world-backed zombie count behind the server-start gate.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/server/RDStall.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RDStall: " .. message) end
end

function isServer() return true end
local started, tick
Events = {
    OnServerStarted = { Add = function(fn) started = fn end },
    OnTick = { Add = function(fn) tick = fn end },
}
SandboxVars = { RFTDCore = { StallWatchEnabled = true, StallWatchMs = 50 } }
-- The REAL RDShared, not a hand-rolled stub - anything Core adds to it
-- otherwise silently under-serves this fixture (the 2026-08-23 username()
-- promotion proved it), and the "verbatim sbNum copy" that sat here was
-- itself the drift hazard its own comment warned about. Only the clock
-- stays fixture-owned.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")
RDShared.nowMs = function() return _G.now end
local records = {}
RDLog = { forensic = function(_, event, _, payload) records[#records + 1] = { event, payload } end }
function require(name)
    if name == "RDShared" then return RDShared end
    if name == "RDLog" then return RDLog end
    error("unexpected require: " .. tostring(name))
end
function getOnlinePlayers() return { size = function() return 3 end } end
function getCell() return { getZombieList = function() return { size = function() return 11 end } end } end

RDStall = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(started) == "function" and type(tick) == "function", "registers readiness and tick lifecycle hooks")

started()
_G.now = 1000
tick()
_G.now = 1100
tick()
check(#records == 1 and records[1][1] == "RD.STALL", "a threshold breach emits one stall record")
check(records[1][2].players == 3 and records[1][2].zombies == 11,
    "stall context reads direct player and ready world zombie counts")

print(string.format("RDStall: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
