-- HBPartWatch fixture - the server lanes and the untrusted intake.
--
-- WHAT IS AT RISK, in order.
--
-- 1. The INTAKE is a client-facing door (CLAUDE.md sect. 13): shape, bounds,
--    rate scope and the server-side watchlist re-check all live in
--    onClientReport, and a validator that quietly stops refusing looks exactly
--    like one that works. Assertions lean negative for that reason.
--
-- 2. The CHAIN CONTRACT: each wrapped complete() must run the original, record
--    only when the original did not refuse, survive an original that throws
--    (record with fault=true, then rethrow), and hand back the original's
--    return value untouched. Break any of those and either vanilla behaviour
--    changes or the record silently vanishes - both invisible in play.
--
-- Real HBParts (real watchlist semantics), stubbed engine and Core surfaces.

local ROOT = arg[1] or "."
local MOD = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL HBPartWatch: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
require = function() return true end
print = function() end

function instanceof(obj, cls)
    return type(obj) == "table" and obj.__class == cls
end

local started
Events = { OnServerStarted = { Add = function(fn) started = fn end } }

local records = {}
local channelArgs
RDLog = {
    channel = function(stream, modId)
        channelArgs = { stream = stream, mod = modId }
        return function(evt, subj, payload)
            records[#records + 1] = { evt = evt, subj = subj, payload = payload }
        end
    end,
}

-- Kept although the module no longer calls it: a tripwire, not a dependency.
-- If a rate check reappears in onClientReport this records it and the
-- assertion below fails, which is the point - the limiter belongs on the RDNet
-- registration now (test_hbcommands.lua). Answers true so a returning call
-- would proceed and be caught by the count rather than by a refusal.
local rateCalls = {}
RDRate = {
    allow = function(player, max, windowMs, scope)
        rateCalls[#rateCalls + 1] =
            { player = player, max = max, windowMs = windowMs, scope = scope }
        return true
    end,
}

RDEvents = { registerNamespace = function() return true end }
AnimalPartsDefinitions = { animals = {
    doewhitetailed = { head = "Base.Deer_Doe_Head", skull = "Base.DeerDoe_Skull" },
} }

-- ---- fakes ---------------------------------------------------------------

local function fakePlayer(name, x, y, z)
    return {
        getUsername = function() return name end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
    }
end

local function fakeItem(fullType, name)
    return {
        getFullType = function() return fullType end,
        getName = function() return name end,
    }
end

local function fakeSquare(x, y, z)
    return {
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
    }
end

-- ---- vanilla action tables, pre-install ----------------------------------

local corpseMode = "ok"   -- "ok" | "throw"
local originalRuns = { corpse = 0, place = 0, hang = 0, remove = 0 }

ISDropAnimalCorpseAndThen = { complete = function(self)
    originalRuns.corpse = originalRuns.corpse + 1
    if corpseMode == "throw" then error("boom-corpse") end
    return true
end }
ISDropWorldItemAction = { complete = function(self)
    originalRuns.place = originalRuns.place + 1
    return true
end }
local hangAnswer = true
ISPutAnimalOnHook = { complete = function(self)
    originalRuns.hang = originalRuns.hang + 1
    return hangAnswer
end }
ISRemoveAnimalFromHook = { complete = function(self)
    originalRuns.remove = originalRuns.remove + 1
    return true
end }

local preInstall = {
    ISDropAnimalCorpseAndThen.complete, ISDropWorldItemAction.complete,
    ISPutAnimalOnHook.complete, ISRemoveAnimalFromHook.complete,
}

-- ---- load ----------------------------------------------------------------

HBParts = nil
local ok, err = pcall(dofile, MOD .. "/shared/HBParts.lua")
check(ok, "HBParts loads: " .. tostring(err))

HBPartWatch = nil
ok, err = pcall(dofile, MOD .. "/server/HBPartWatch.lua")
check(ok, "HBPartWatch loads: " .. tostring(err))

check(channelArgs ~= nil and channelArgs.stream == "parts"
    and channelArgs.mod == "RFTDHusbandry",
    "the forensic channel is not bound to parts/RFTDHusbandry")

check(type(started) == "function", "nothing subscribed to OnServerStarted")
started()

check(ISDropAnimalCorpseAndThen.complete ~= preInstall[1], "corpse complete not wrapped")
check(ISDropWorldItemAction.complete ~= preInstall[2], "place complete not wrapped")
check(ISPutAnimalOnHook.complete ~= preInstall[3], "hang complete not wrapped")
check(ISRemoveAnimalFromHook.complete ~= preInstall[4], "remove complete not wrapped")

-- double install must not double-wrap: one action fired once = one record
local wrappedOnce = ISDropAnimalCorpseAndThen.complete
HBPartWatch.install()
check(ISDropAnimalCorpseAndThen.complete == wrappedOnce,
    "install() is not idempotent - a second OnServerStarted would double-record")

-- ---- corpse_drop ----------------------------------------------------------

local dropper = fakePlayer("Griefer", 100.7, 200.2, 0)
local r = ISDropAnimalCorpseAndThen.complete{
    character = dropper, item = fakeItem("Base.CorpseAnimal", "Dead Doe"),
}
check(r == true, "corpse chain did not hand back the original's return value")
check(originalRuns.corpse == 1, "corpse original did not run")
check(#records == 1, "corpse drop produced " .. #records .. " records, wanted 1")
local p = records[1] and records[1].payload or {}
check(records[1] and records[1].evt == "HB.PART_PLACED", "wrong event name")
check(records[1] and records[1].subj == dropper, "record not attributed to the dropper")
check(p.path == "corpse_drop", "wrong path: " .. tostring(p.path))
check(p.fullType == "Base.CorpseAnimal" and p.name == "Dead Doe",
    "corpse identity fields wrong")
check(p.x == 100 and p.y == 200 and p.z == 0,
    "coordinates not floored player position")
check(p.fault == nil, "a clean drop was stamped fault")

-- an unwatched item passes through unrecorded, original still runs
records = {}
ISDropAnimalCorpseAndThen.complete{
    character = dropper, item = fakeItem("Base.Axe", "Axe"),
}
check(originalRuns.corpse == 2, "original skipped for an unwatched item")
check(#records == 0, "an unwatched item was recorded")

-- original throws: record survives with fault=true, throw survives us
records = {}
corpseMode = "throw"
local threw, msg = pcall(ISDropAnimalCorpseAndThen.complete, {
    character = dropper, item = fakeItem("Base.CorpseAnimal", "Dead Doe"),
})
corpseMode = "ok"
check(threw == false, "the original's throw was swallowed")
check(tostring(msg):find("boom%-corpse") ~= nil,
    "the rethrown error is not the original's: " .. tostring(msg))
check(#records == 1 and records[1].payload.fault == true,
    "a faulted drop was not recorded with fault=true")

-- ---- place_item ------------------------------------------------------------

records = {}
ISDropWorldItemAction.complete{
    character = dropper, item = fakeItem("Base.Deer_Doe_Head", "Doe Head"),
    sq = fakeSquare(5000, 6000, 1),
}
p = records[1] and records[1].payload or {}
check(#records == 1 and p.path == "place_item", "placement not recorded")
check(p.fullType == "Base.Deer_Doe_Head", "placement identity wrong")
check(p.x == 5000 and p.y == 6000 and p.z == 1,
    "placement coordinates are not the TARGET square - player position would "
    .. "be wrong for a cursor that reaches into an adjacent tile")

records = {}
ISDropWorldItemAction.complete{
    character = dropper, item = fakeItem("Base.Plank", "Plank"),
    sq = fakeSquare(1, 1, 0),
}
check(#records == 0, "an unwatched placement was recorded")

-- ---- hook_hang -------------------------------------------------------------

local hook = { getSquare = function() return fakeSquare(70, 80, 0) end }

records = {}
local deadBody = { __class = "IsoDeadBody",
    getModData = function() return { AnimalType = "deer", AnimalBreed = "whitetailed" } end }
ISPutAnimalOnHook.complete{ character = dropper, hook = hook, body = deadBody }
p = records[1] and records[1].payload or {}
check(#records == 1 and p.path == "hook_hang", "hang not recorded")
check(p.animalType == "deer" and p.breed == "whitetailed", "hang animal identity wrong")
check(p.fullType == nil, "an IsoDeadBody hang carried a fullType")
check(p.x == 70 and p.y == 80, "hang coordinates are not the hook's square")

-- a REFUSED hang (contested hook returns false) changed nothing: no record
records = {}
hangAnswer = false
ISPutAnimalOnHook.complete{ character = dropper, hook = hook, body = deadBody }
hangAnswer = true
check(#records == 0,
    "a refused hang was recorded - complete() returning false means the world "
    .. "did not change")

-- the inventory-item lane carries the item's fullType alongside modData
records = {}
local corpseItem = {
    getModData = function() return { AnimalType = "cow", AnimalBreed = "angus" } end,
    getFullType = function() return "Base.CorpseAnimal" end,
}
ISPutAnimalOnHook.complete{ character = dropper, hook = hook, body = corpseItem }
p = records[1] and records[1].payload or {}
check(#records == 1 and p.fullType == "Base.CorpseAnimal",
    "an item hang lost its fullType")

-- ---- hook_remove -----------------------------------------------------------

records = {}
local hanging = { __class = "IsoAnimal",
    getTypeAndBreed = function() return "doewhitetailed" end }
ISRemoveAnimalFromHook.complete{ character = dropper, hook = hook, body = hanging }
p = records[1] and records[1].payload or {}
check(#records == 1 and p.path == "hook_remove", "unhook not recorded")
check(p.animal == "doewhitetailed", "unhook animal identity wrong")

-- ---- onClientReport: the untrusted door ------------------------------------

local reporter = fakePlayer("Reporter", 0, 0, 0)
local function report(args)
    records = {}
    HBPartWatch.onClientReport(reporter, args)
    return records
end

-- THE RATE LIMIT IS NOT THIS FILE'S ANY MORE (2026-08-25). It used to be the
-- first thing onClientReport did, because the command arrived through
-- Husbandry's own OnClientCommand chain, which had no per-command limiter.
-- The token now goes through RDNet, whose bucket is already scoped to
-- (token, command); the 4/sec lives on the registration and is pinned by
-- test_hbcommands.lua.
--
-- What is pinned HERE is the negative: this handler must not consult RDRate
-- again. Two limiters draining on one stream is the shape RDRate.allow's own
-- header warns about - the second one sees a bucket the first already spent
-- and refuses traffic nobody sent twice.
rateCalls = {}
report{ x = 10, y = 10, z = 0, items = { { fullType = "Base.Deer_Doe_Head" } } }
check(#rateCalls == 0,
    "onClientReport is rate-limiting again - RDNet already did, and two "
    .. "limiters on one command drain the same bucket twice")

-- shape refusals
check(#report(nil) == 0, "nil args accepted")
check(#report("junk") == 0, "string args accepted")
check(#report{ items = "junk", x = 1, y = 1, z = 0 } == 0, "non-table items accepted")
check(#report{ items = {} } == 0, "missing coordinates accepted")
check(#report{ x = "a", y = 1, z = 0, items = {} } == 0, "non-numeric x accepted")

-- world bounds
local head = { { fullType = "Base.Deer_Doe_Head" } }
check(#report{ x = -5, y = 10, z = 0, items = head } == 0, "negative x accepted")
check(#report{ x = 10, y = 999999, z = 0, items = head } == 0, "absurd y accepted")
check(#report{ x = 10, y = 10, z = 40, items = head } == 0, "z=40 accepted")
check(#report{ x = 10, y = 10, z = -2, items = head } == 1,
    "a basement z was refused - B42 has negative levels")

-- the watchlist is re-checked SERVER-side: junk rows drop, and they do not
-- consume the accept cap
local rows = {}
for i = 1, 5 do rows[#rows + 1] = { fullType = "Base.NotAThing" .. i } end
rows[#rows + 1] = { fullType = "Base.Deer_Doe_Head", name = "Doe Head" }
local got = report{ x = 10, y = 20, z = 0, items = rows }
check(#got == 1, "junk rows changed the accept count: " .. #got)
check(got[1] and got[1].payload.path == "item_drop"
    and got[1].payload.fullType == "Base.Deer_Doe_Head"
    and got[1].payload.x == 10 and got[1].payload.y == 20,
    "the accepted row's record is wrong")

-- cap: 25 watched rows -> 20 records, never more
rows = {}
for i = 1, 25 do rows[#rows + 1] = { fullType = "Base.Deer_Doe_Head" } end
check(#report{ x = 10, y = 10, z = 0, items = rows } == 20,
    "the per-report cap is not 20")

-- oversized strings are clamped, not refused - the fullType matched, so the
-- record is real and only the label needs bounding
local longName = string.rep("n", 200)
got = report{ x = 10, y = 10, z = 0,
    items = { { fullType = "Base.Deer_Doe_Head", name = longName } } }
check(#got == 1 and #got[1].payload.name == 80, "an oversized name was not clamped to 80")

-- non-table rows must not fault the whole report
got = report{ x = 10, y = 10, z = 0,
    items = { "junk", 42, { fullType = "Base.Deer_Doe_Head" } } }
check(#got == 1, "junk rows took the good row down with them")

print = realPrint
print(string.format("HBPartWatch: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
