-- DFTripwire fixture - the latch contract the Dragonfly sidebar badge leans on.
--
-- WHY THIS EXISTS: DFDeckButton calls alertActive/pendingCount/acknowledge
-- directly, with no pcall, because all three are total functions over their own
-- table. That is a contract, not an accident, and nothing pinned it before.
-- If a later change gives any of them real work to do - an engine call, a file
-- read, a foreign callback - these assertions fail and the badge's direct calls
-- must be reconsidered rather than silently becoming unguarded hazards.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFTripwire.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL DFTripwire: " .. message)
    end
end

-- ---- engine / suite stubs ----------------------------------------------
function isServer() return false end

local serverCommandHandlers = {}
Events = {
    OnServerCommand = { Add = function(fn) serverCommandHandlers[#serverCommandHandlers + 1] = fn end },
}

RDShared = { MODULE = "RFTDCore", registerMod = function() end }
local pushed = {}
DFLog = { push = function(row) pushed[#pushed + 1] = row end }

-- The module `require`s RDShared; stub the global loader to a no-op.
local realRequire = require
require = function(name) return true end

DFTripwire = nil
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))
check(#serverCommandHandlers == 1, "registers exactly one server-command listener")

-- ---- the three accessors are total -------------------------------------
-- Fresh latch: every accessor answers without engine state of any kind.
check(DFTripwire.alertActive() == false, "alertActive is false on a fresh latch")
check(DFTripwire.pendingCount() == 0, "pendingCount is 0 on a fresh latch")

-- acknowledge on an already-clean latch is the early-return no-op the badge
-- calls every single frame the deck is visible.
local ackOk = pcall(DFTripwire.acknowledge)
check(ackOk, "acknowledge on a clean latch does not throw")
check(DFTripwire.alertActive() == false, "acknowledge on a clean latch changes nothing")

-- Deliberately hostile internal state: the badge reaches these with whatever
-- the latch happens to hold, so they must stay total across it.
DFTripwire.pending, DFTripwire.count = nil, nil
check(DFTripwire.alertActive() == false, "a nil pending reads as no alert, not an error")
check(DFTripwire.pendingCount() == 0, "a nil count reads as 0, not an error")
check(pcall(DFTripwire.acknowledge), "acknowledge tolerates a nil latch")

-- ---- the latch actually latches ----------------------------------------
local raise = serverCommandHandlers[1]
raise("RFTDCore", "tripwire", { sev = "impossible", u = "Omen", a = "admin", t = "did a thing", code = "X1" })
check(DFTripwire.alertActive() == true, "a server-observed impossibility raises the latch")
check(DFTripwire.pendingCount() == 1, "the count follows the latch")
check(DFTripwire.lastCode == "X1", "the code is retained for the detail pane")
check(#pushed == 1 and pushed[1].level == "tripwire", "the record reaches the console at tripwire level")

raise("RFTDCore", "tripwire", { sev = "impossible", u = "Omen", code = "X1" })
check(DFTripwire.pendingCount() == 2, "a repeat trip counts rather than replaces")

-- A client-reported (non-impossible) trip logs but must NOT raise the badge.
DFTripwire.pending, DFTripwire.count = false, 0
raise("RFTDCore", "tripwire", { sev = "reported", u = "Omen", code = "Y2" })
check(DFTripwire.alertActive() == false, "a client-reported trip does not raise the latch")
check(#pushed == 3 and pushed[3].level == "warn", "but it is still logged, at warn")

-- ---- acknowledge clears, idempotently ----------------------------------
DFTripwire.pending, DFTripwire.count = true, 7
DFTripwire.acknowledge()
check(DFTripwire.alertActive() == false and DFTripwire.pendingCount() == 0, "acknowledge clears the latch")
DFTripwire.acknowledge()
check(DFTripwire.pendingCount() == 0, "acknowledge is idempotent - the badge calls it every frame")

-- ---- listener ignores traffic that is not its own ----------------------
local before = #pushed
raise("SomeOtherMod", "tripwire", { sev = "impossible", code = "Z" })
raise("RFTDCore", "somethingElse", { sev = "impossible", code = "Z" })
raise("RFTDCore", "tripwire", "not a table")
check(#pushed == before, "foreign modules, other commands, and malformed envelopes are ignored")
check(DFTripwire.alertActive() == false, "and none of them can raise the latch")

realPrint(string.format("DFTripwire: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
