-- RDVarsMirror fixture - the client's copy of its own variables.
--
-- WHAT IS AT RISK. The mirror is advisory by contract - the server re-derives
-- everything - so its failures are all in what it OFFERS: a flag still shown
-- after its deadline (a door lit that will not open), a deadline anchored to
-- the server's clock instead of ours (skew resurrects or kills flags at
-- random), a stale entry surviving a replace, and nil-vs-0 collapsing on a
-- counter after the server went to lengths to keep them apart.
--
-- REAL RDVarDefs: holds() promises to normalize through the same rule the
-- server matches with, and a stubbed normalize would test the stub.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RDVarsMirror: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() end

local clock = 5000000
local listener = nil
Events = { OnServerCommand = { Add = function(fn) listener = fn end } }

RDVarDefs = nil
local okD, errD = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okD, "RDVarDefs loads: " .. tostring(errD))

dofile(CORE .. "/shared/RDShared.lua")
RDShared.nowMs = function() return clock end

RDVarsMirror = nil
local ok, err = pcall(dofile, CORE .. "/client/RDVarsMirror.lua")
check(ok, "RDVarsMirror loads: " .. tostring(err))
check(listener ~= nil, "no OnServerCommand listener was registered")

-- ---- before any document ---------------------------------------------------

check(RDVarsMirror.ready() == false, "ready before anything arrived")
check(RDVarsMirror.holds("Anomaly") == false, "held a flag with no document")
check(RDVarsMirror.value("Loot") == nil, "a value existed with no document")

-- ---- the filter ------------------------------------------------------------

listener("SomeOtherMod", "VarsMine", { flags = { anomaly = 0 } })
check(RDVarsMirror.ready() == false,
    "ANOTHER MOD'S PUSH WAS SWALLOWED AS OURS - the module filter is the only "
    .. "thing keeping foreign payloads out of this cache")
listener("RFTDCore", "SomethingElse", { flags = { anomaly = 0 } })
check(RDVarsMirror.ready() == false, "another command on our token was absorbed")

-- ---- a document ------------------------------------------------------------

listener("RFTDCore", "VarsMine", {
    flags   = { anomaly = 10 * 60000, forever = 0 },
    numbers = { anomalyloot = 0, samples = 7 },
})
check(RDVarsMirror.ready() == true, "a real push did not make the mirror ready")

check(RDVarsMirror.holds("Anomaly") == true, "a live flag read as absent")
check(RDVarsMirror.holds("ANOMALY") == true,
    "HOLDS IS CASE-SENSITIVE. The server matches names case-insensitively; a "
    .. "mirror that does not answers differently from the authority it mirrors.")
check(RDVarsMirror.holds("forever") == true, "a never-expiring flag read absent")
check(RDVarsMirror.holds("elsewhere") == false, "an unheld flag read as held")
check(RDVarsMirror.holds(nil) == false, "a nil name did not answer false")

check(RDVarsMirror.value("AnomalyLoot") == 0,
    "A COUNTER AT ZERO READ AS ABSENT. Zero is a value somebody set; absent "
    .. "is never-touched - the house distinction, kept on this side too.")
check(RDVarsMirror.value("Samples") == 7, "a counter's value did not survive")
check(RDVarsMirror.value("Nowhere") == nil, "an untouched counter invented a value")

-- ---- expiry, on OUR clock --------------------------------------------------

clock = clock + 10 * 60000 - 1
check(RDVarsMirror.holds("Anomaly") == true, "a flag expired a tick early")
clock = clock + 1
check(RDVarsMirror.holds("Anomaly") == false,
    "A FLAG OUTLIVED ITS DEADLINE LOCALLY. Staleness must never extend a "
    .. "permission the server has already stopped honouring.")
check(RDVarsMirror.holds("forever") == true,
    "the passage of time took a flag that never expires")

-- ---- replace is wholesale --------------------------------------------------

listener("RFTDCore", "VarsMine", { flags = {}, numbers = { samples = 9 } })
check(RDVarsMirror.holds("forever") == false,
    "A REVOKED FLAG SURVIVED THE REPLACE. The protocol is full-document swap; "
    .. "anything merged from the old cache is a permission the server took away.")
check(RDVarsMirror.value("Samples") == 9, "the replacing document did not land")
check(RDVarsMirror.value("AnomalyLoot") == nil,
    "a counter absent from the new document lingered from the old")

-- ---- malformed payloads ----------------------------------------------------

check(RDVarsMirror.absorb(nil) == false, "a nil payload was absorbed")
check(RDVarsMirror.absorb("junk") == false, "a string payload was absorbed")
check(RDVarsMirror.value("Samples") == 9,
    "a refused payload still clobbered the cache")

-- One malformed entry must not poison its neighbours.
RDVarsMirror.absorb({
    flags   = { anomaly = "soon", [7] = 0, valid = 0, expired = -50 },
    numbers = { loot = "many", fine = 3 },
})
check(RDVarsMirror.holds("valid") == true, "a valid flag fell with its bad neighbour")
check(RDVarsMirror.holds("anomaly") == false, "a non-numeric remaining was believed")
check(RDVarsMirror.holds("expired") == false,
    "A NEGATIVE REMAINING WAS OFFERED. The server omits expired flags; one "
    .. "arriving negative is malformed and must not become a held flag.")
check(RDVarsMirror.value("fine") == 3, "a valid counter fell with its bad neighbour")
check(RDVarsMirror.value("loot") == nil, "a non-numeric value was believed")

print(string.format("RDVarsMirror: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
