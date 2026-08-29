-- RDConfigStore fixture - Core's durable server-owned config.
--
-- WHY THIS EXISTS: every failure this module has is SILENT by nature. A mirror
-- that stopped writing, a boot that quietly emptied a store, an import that
-- loaded the wrong document - none of them raise, and all of them present as
-- "the admin panel is empty" days later, on a live server, with no way back.
-- So the assertions here are mostly about what must NOT happen.
--
-- REAL RDJson, NOT A STUB, and that is deliberate. The round-trip property this
-- module rests on is encode-then-decode, so stubbing either half would test the
-- stub. It also carries a live lesson: test_mmrestore and test_mmbulk both
-- stubbed `require` and therefore silently stopped loading the real decoder
-- when it moved into Core (2026-08-22). Fixtures that stand in for a module
-- must implement the surface; where the module IS the thing under test, load it.
--
-- The clock is ours on purpose. RDShared.nowMs is getTimestampMs - wall clock,
-- explicitly not monotonic - and a controllable clock is the only way to assert
-- that an NTP step backwards does not stall the flush budget forever.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local SOURCE = CORE .. "/server/RDConfigStore.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RDConfigStore: " .. message) end
end

-- pairs(), not next(). This fixture runs REAL Lua 5.1, where `next` exists, so
-- using it here would work - but a fixture is where people go to read the
-- idiom, and Kahlua registers no global `next` (CLAUDE.md sect. 3). Modelling
-- the wrong shape in a test is how it ends up in a module.
local function isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

-- ---- engine stubs -------------------------------------------------------

function isServer() return true end

-- Captured console. Several assertions below are about the store SAYING
-- something - a silent failure is the defect, so the message is the behaviour.
local log = {}
print = function(s) log[#log + 1] = tostring(s) end
local function logged(pattern)
    for _, line in ipairs(log) do if line:find(pattern, 1, true) then return true end end
    return false
end
local function clearLog() log = {} end

-- Virtual filesystem: path -> content string, plus a write counter per path so
-- "the file was not touched" is directly assertable rather than inferred.
local fs, writes = {}, {}

-- A nil path is a FIXTURE ERROR, not a nil return, and the distinction is the
-- whole reason this stub is not lenient. getFileReader(null, true) passes
-- Kahlua's argument check unharmed - a Lua nil arrives as Java null and
-- LuaJavaInvoker only fails a conversion when the value was non-nil
-- (LuaJavaInvoker.java:90-93) - and then runs the body, where
-- GlobalObject.hasRelativePath dereferences it (LuaManager.java:4896, :6922-6927).
-- That is a Java BODY throw: MethodCaller swallows it and stack-traces it
-- (MethodCaller.java:33-56), so Lua reads nil and a server console gets a Java
-- trace at every boot. A stub that quietly returned nil would model the return
-- value correctly and the observable consequence not at all, which is how a
-- store reaching for a document it does not have would pass a green suite.
function getFileReader(path, _)
    if path == nil then
        error("engine call with a nil path - the store reached for a document "
            .. "it does not have; in game this is a logged Java stack trace")
    end
    local content = fs[path]
    if content == nil then return nil end
    local lines, i = {}, 1
    for line in (content .. "\n"):gmatch("(.-)\n") do lines[i] = line; i = i + 1 end
    -- Trailing empty element from the sentinel newline.
    if lines[#lines] == "" then lines[#lines] = nil end
    local pos = 0
    return {
        readLine = function() pos = pos + 1; return lines[pos] end,
        close    = function() end,
    }
end

-- Set to a path to make getFileWriter refuse it, modelling the engine's nil
-- return for a denied path (LuaManager.java:5526) - NOT a throw, which is the
-- distinction that matters and which an earlier generation of fixtures got
-- backwards across nine files.
local refuseWrite = nil

function getFileWriter(path, _, append)
    if path == nil then
        error("engine call with a nil path - see the note on getFileReader")
    end
    if refuseWrite == path then return nil end
    if not append then fs[path] = "" end
    writes[path] = (writes[path] or 0) + 1
    return {
        write = function(_, s) fs[path] = (fs[path] or "") .. s end,
        close = function() end,
    }
end

-- ModData, with a settable backing map so a world wipe is expressible.
local modDataMap = {}
ModData = {
    getOrCreate = function(tag)
        modDataMap[tag] = modDataMap[tag] or {}
        return modDataMap[tag]
    end,
}

-- Events: capture the sweep so it can be fired on demand.
local sweep
Events = { EveryTenMinutes = { Add = function(fn) sweep = fn end } }

-- The clock.
local clock = 1000
-- The REAL RDShared, not a hand-rolled stub - anything Core adds to it
-- otherwise silently under-serves this fixture (the 2026-08-23 username()
-- promotion proved it). Its only file-scope call is registerMod.
require = function() return true end
dofile(CORE .. "/shared/RDShared.lua")
dofile(CORE .. "/shared/RDFile.lua")
RDShared.nowMs = function() return clock end

-- Real RDJson.
require = function() return true end
dofile(CORE .. "/shared/RDJson.lua")
check(type(RDJson.encode) == "function" and type(RDJson.decode) == "function",
    "the real RDJson did not load - the round-trip assertions below would be vacuous")

RDConfigStore = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(sweep ~= nil, "no EveryTenMinutes sweep was registered")

local DEFS  = "RFTD/t-defs.json.txt"
local STATE = "RFTD/t-state.json.txt"

local function newStore(key)
    return RDConfigStore.new{
        modKey = key or "TEST", defsFile = DEFS, stateFile = STATE,
        flushMs = 30000, label = "TEST",
    }
end

-- Reloading the module is the point, not a flourish. RDConfigStore keeps a
-- module-level list of every store built this session so flushAll and the sweep
-- can reach them - correct in production, where each store is constructed once
-- at file scope, and cross-contamination here, where a dozen stores share two
-- paths. Without the reload an earlier block's DEFERRED state write lands on
-- this block's file the moment a sweep expires the budget, and the failure
-- reads as "the sweep did not flush" when the sweep flushed twice.
local function reset()
    fs, writes, modDataMap = {}, {}, {}
    refuseWrite = nil
    clock = 1000
    clearLog()
    dofile(SOURCE)          -- fresh store list, and re-captures `sweep`
end

-- ---- construction refuses what the engine would refuse -------------------
-- Every one of these produces a store that looks like it works and persists
-- nothing. getFileWriter returns nil for a bad extension and says nothing, so
-- the mistake would surface as data loss after a crash, not as an error.

check(not pcall(RDConfigStore.new, { defsFile = DEFS, stateFile = STATE }),
    "a store with no modKey was accepted")
-- stateFile is OPTIONAL - a defs-only store is a real shape (the admin layout
-- overlay is all definition). A TYPO in it is not: reading a non-string as
-- "absent" would build a defs-only store the consumer never asked for and then
-- lose every state write it made, silently, which is this module's whole
-- subject.
check(pcall(RDConfigStore.new, { modKey = "X", defsFile = DEFS }),
    "a defs-only store was refused")
-- Asserted on the MESSAGE, not merely on the throw. The extension check
-- refuses a number too, by accident, so a test that only asked "did it throw"
-- could not tell a deliberate type check from that coincidence - and the
-- coincidence gives an admin the wrong diagnosis ("getFileWriter will refuse
-- '7'") for what is a typo in a spec table.
local okNum, whyNum = pcall(RDConfigStore.new,
    { modKey = "X", defsFile = DEFS, stateFile = 7 })
check(okNum == false, "a non-string stateFile was accepted")
check(tostring(whyNum):find("string or absent", 1, true) ~= nil,
    "a typo'd stateFile was diagnosed as a bad extension rather than as a bad "
    .. "type: " .. tostring(whyNum))
check(not pcall(RDConfigStore.new,
        { modKey = "X", defsFile = DEFS, stateFile = "RFTD/a.jsonl" }),
    "a bad stateFile extension was accepted")
check(not pcall(RDConfigStore.new, { modKey = "X", defsFile = DEFS, stateFile = DEFS }),
    "defs and state were allowed to share one file - the second would overwrite the first")
check(not pcall(RDConfigStore.new,
        { modKey = "X", defsFile = "RFTD/a.jsonl", stateFile = STATE }),
    "'.jsonl' was accepted - getFileWriter refuses it and returns nil SILENTLY, "
    .. "which is the exact failure that killed every family write mid-42.20")
check(not pcall(RDConfigStore.new,
        { modKey = "X", defsFile = "RFTD/a.JSON.TXT", stateFile = STATE }),
    "an uppercase extension was accepted - the engine's check is case-sensitive")
check(pcall(RDConfigStore.new, { modKey = "X", defsFile = "RFTD/a.json", stateFile = STATE }),
    "'.json' was refused, but it IS in ALLOWED_FILE_EXTENSIONS (LuaManager.java:1045)")

-- ---- round trip ----------------------------------------------------------

reset()
local s = newStore()
s:defs().anomaly = { kind = "flag", revokers = { death = true } }
s:state().Kriegan = { anomaly = 1, loot = 5 }
s:touchDefs()
s:touchState()
check(fs[DEFS] ~= nil and fs[STATE] ~= nil, "touch did not write both documents")

-- Simulate a restart: same files, empty ModData, then a live table that is
-- BEHIND the file (the crash case).
local defsOnDisk, stateOnDisk = fs[DEFS], fs[STATE]
reset()
fs[DEFS], fs[STATE] = defsOnDisk, stateOnDisk
local s2 = newStore()
s2:root().meta.defsMs  = 1     -- live, but older than the file
s2:root().meta.stateMs = 1
s2:boot()
check(s2:defs().anomaly ~= nil and s2:defs().anomaly.kind == "flag",
    "defs did not survive the round trip")
check(s2:defs().anomaly.revokers.death == true,
    "a nested value was lost in the round trip")
check(s2:state().Kriegan ~= nil and s2:state().Kriegan.loot == 5,
    "state did not survive the round trip")
check(logged("recovering it"),
    "a newer file was taken silently - crash recovery must announce itself")

-- ---- newer-wins is a comparison, not a preference ------------------------
-- The reverse case matters more than the forward one: if the live table always
-- lost, every clean restart would roll the world back to the last flush.

reset()
fs[DEFS] = defsOnDisk                      -- file stamped at clock 1000
local s3 = newStore()
s3:root().defs = { live = true }
s3:root().meta.defsMs = 99999              -- live is NEWER
s3:boot()
check(s3:defs().live == true,
    "an OLDER file overwrote a newer live table - every clean restart would "
    .. "roll the world back to the last flush")
check(fs[DEFS]:find("live", 1, true) ~= nil,
    "the newer live table was not mirrored out over the older file")

-- ---- a file from a previous world is never taken automatically -----------
-- getFileWriter roots at the Lua cache dir, OUTSIDE the save, so these files
-- outlive a wipe while ModData does not. Auto-loading here would hand players
-- back every grant they had already spent.

reset()
fs[DEFS], fs[STATE] = defsOnDisk, stateOnDisk
local s4 = newStore()                       -- no meta at all: fresh or wiped
s4:boot()
check(isEmpty(s4:defs()),
    "a previous world's defs were loaded into a fresh world automatically")
check(isEmpty(s4:state()),
    "a previous world's STATE was loaded automatically - players would get back "
    .. "one-time grants they had already consumed")
check(logged("previous world"), "the refusal was not explained on the console")

-- ...and the file must still be there afterwards, or the advice to import it
-- is a trap. This is what the "foreign" hold buys.
check(fs[DEFS] == defsOnDisk, "boot overwrote the previous world's defs file")
s4:defs().fresh = true
s4:touchDefs()
check(fs[DEFS] == defsOnDisk,
    "the first touchDefs CLOBBERED the file the admin was just told to import")
check(logged("held (foreign)"), "the held write was not reported")

-- Both doors out of a hold, and neither is reachable by accident.
check(s4:importDefs(), "import of a held file failed")
check(s4:defs().anomaly ~= nil, "import did not take the file")
s4:defs().after = true
s4:touchDefs()
check(fs[DEFS] ~= defsOnDisk, "the hold was not released by a successful import")

reset()
fs[DEFS] = defsOnDisk
local s5 = newStore()
s5:boot()
check(s5:discard("defs"), "discard of a held document failed")
s5:defs().mine = true
s5:touchDefs()
check(fs[DEFS] ~= defsOnDisk, "discard did not release the hold")
check(not s5:discard("defs"), "discard succeeded on a document that is not held")

-- ---- importing one document leaves the other alone ----------------------

reset()
local s6 = newStore()
s6:defs().a = 1
s6:state().b = 2
s6:touchDefs(); s6:touchState()
local keptDefs = fs[DEFS]
s6:defs().a = 99
s6:state().b = 99
s6:touchDefs(); s6:touchState()
fs[DEFS] = keptDefs                         -- an admin restores only the defs file
check(s6:importDefs(), "importDefs failed")
check(s6:defs().a == 1, "importDefs did not replace defs")
check(s6:state().b == 99,
    "importDefs also reverted STATE - the two documents must import independently")

-- ---- the envelope refuses the wrong file --------------------------------
-- The one mistake this design invites is an admin reaching for whichever file
-- is in front of them after a wipe. Taking state as defs would put per-player
-- progress where definitions belong.

reset()
local s7 = newStore()
s7:defs().a = 1
s7:state().b = 2
s7:touchDefs(); s7:touchState()
fs[DEFS] = fs[STATE]                        -- state file offered as defs
local okImport, why = s7:importDefs()
check(not okImport, "a STATE file was accepted by importDefs")
check(tostring(why):find("wrong file", 1, true) ~= nil,
    "the refusal did not say what was wrong: " .. tostring(why))

-- ---- corrupt input fails LOUDLY and destroys nothing ---------------------

for _, bad in ipairs({
    { name = "truncated",  make = function(good) return good:sub(1, #good - 12) end },
    { name = "empty",      make = function() return "" end },
    { name = "whitespace", make = function() return "   \n  " end },
    { name = "not JSON",   make = function() return "<html>404</html>" end },
    { name = "a JSON array", make = function() return "[1,2,3]" end },
}) do
    reset()
    local s8 = newStore()
    s8:defs().good = true
    s8:touchDefs()
    local good = fs[DEFS]
    fs[DEFS] = bad.make(good)
    local corrupted = fs[DEFS]

    -- A restart with a live table present and the file damaged.
    modDataMap = {}
    local s9 = newStore()
    s9:root().defs = { survivor = true }
    s9:root().meta.defsMs = 500
    clearLog()
    s9:boot()

    check(s9:defs().survivor == true,
        bad.name .. ": the live table was replaced by an empty one - a corrupt "
        .. "file must never present as a wipe")
    check(logged("CRITICAL"),
        bad.name .. ": nothing was said. Silence is the failure mode here")
    check(fs[DEFS] == corrupted,
        bad.name .. ": boot OVERWROTE the unreadable file, destroying the only "
        .. "copy a human could have repaired")

    -- ...and it stays not-overwritten under ordinary use.
    s9:defs().more = true
    s9:touchDefs()
    check(fs[DEFS] == corrupted, bad.name .. ": a later write overwrote the held file")
end

-- A format from a future build is refused, not guessed at.
reset()
fs[DEFS] = RDJson.encode{ format = 99, kind = "defs", key = "TEST",
                          savedMs = 5, data = { x = 1 } }
local s10 = newStore()
s10:root().meta.defsMs = 1
s10:boot()
check(isEmpty(s10:defs()) and logged("CRITICAL"),
    "an unknown envelope format was loaded instead of refused")

-- ---- the flush budget ----------------------------------------------------

reset()
local s11 = newStore()
s11:state().x = 1
s11:touchState()
check(writes[STATE] == 1, "the first state write did not happen immediately")
s11:state().x = 2
s11:touchState()
check(writes[STATE] == 1, "state was written twice inside one flush budget")
clock = clock + 30000
s11:state().x = 3
s11:touchState()
check(writes[STATE] == 2, "the flush budget did not expire")

-- Defs ignore the budget: rare, precious, and the half an admin wants back.
local before = writes[DEFS] or 0
s11:touchDefs(); s11:touchDefs()
check((writes[DEFS] or 0) == before + 2, "defs were batched - they must write immediately")

-- The sweep catches what the budget deferred, which is what bounds staleness
-- for a store that goes quiet right after a change.
reset()
local s12 = newStore()
s12:state().x = 1
s12:touchState()                 -- writes now
s12:state().x = 2
s12:touchState()                 -- deferred
check(writes[STATE] == 1, "precondition: the second write should have been deferred")
sweep()
check(writes[STATE] == 1, "the sweep wrote inside the budget")
clock = clock + 30000
sweep()
check(writes[STATE] == 2, "the sweep did not flush a deferred write after the budget")

-- getTimestampMs is wall clock and NOT monotonic. A naive now-last>=budget
-- stalls forever on a backwards NTP step, so negative elapsed means "due now":
-- one extra file write is cheaper than losing every change until reboot.
reset()
local s13 = newStore()
s13:state().x = 1
s13:touchState()
clock = clock - 60000            -- the clock steps backwards
s13:state().x = 2
s13:touchState()
check(writes[STATE] == 2,
    "a BACKWARDS clock step stalled the flush budget - every later change would "
    .. "sit unmirrored until the next reboot")

-- ---- a refused writer is reported, never assumed to have worked ----------
-- The pre-42.20 bug in one line: `if w then` with no else, so a refused write
-- looked exactly like a successful one and RDLog went on returning true.

reset()
local s14 = newStore()
refuseWrite = DEFS
s14:defs().a = 1
local wrote = s14:touchDefs()
check(wrote == false, "a refused write reported success")
check(logged("CRITICAL"), "a refused write said nothing")
check(s14:report().refused == 1, "the refused write was not counted")

-- ---- flushAll and idempotent boot ---------------------------------------

reset()
local s15 = newStore("A")
s15:state().x = 1
s15:touchState()
s15:state().x = 2
s15:touchState()                 -- deferred
RDConfigStore.flushAll()
check(writes[STATE] == 2, "flushAll did not write a deferred document")

reset()
local s16 = newStore()
s16:defs().a = 1
s16:root().meta.defsMs = 10
s16:boot()
local after = writes[DEFS]
s16:boot()
check(writes[DEFS] == after, "boot is not idempotent - the second call wrote again")

-- ---- the defs-only store -------------------------------------------------
-- One document, because the consumer genuinely has one. The risks are the two
-- ways this could go wrong quietly: a loop that still walks a literal
-- {defs,state} pair and touches a nil filename, and a state call that appears
-- to work while persisting nothing.

reset()
local s17 = RDConfigStore.new{ modKey = "SOLO", defsFile = DEFS, label = "TEST" }
s17:defs().layout = { "A", "B" }
check(s17:touchDefs() == true, "a defs-only store could not write its one document")
check(fs[DEFS] ~= nil, "the defs document was not mirrored")
check(fs[STATE] == nil,
    "a defs-only store wrote a state file anyway - an empty document on disk "
    .. "exists only to be explained, and after a wipe it trips the foreign "
    .. "hold and asks an admin to decide about nothing")

-- boot() walks the store's OWN document list. If it still walked a literal
-- pair it would call getFileWriter(nil) here, which returns nil and reports a
-- CRITICAL refusal about a file the consumer never asked for.
clearLog()
reset()
local s18 = RDConfigStore.new{ modKey = "SOLO", defsFile = DEFS, label = "TEST" }
s18:defs().layout = { "A" }
s18:root().meta.defsMs = 10
local okBoot, bootErr = pcall(function() s18:boot() end)
check(okBoot,
    "boot on a defs-only store reached for its absent state document: "
    .. tostring(bootErr))
check(not logged("CRITICAL"), "boot reported a refusal about a file nobody asked for")
check(writes[DEFS] == 1, "boot did not mirror the live defs table")
check(writes[STATE] == nil, "boot touched a state file that does not exist")
RDConfigStore.flushAll()
check(writes[STATE] == nil, "flushAll touched a state file that does not exist")

-- Reaching for the absent document is a PROGRAMMING error and throws. It does
-- not return an empty table: a live table that is never mirrored looks exactly
-- like a store that works.
check(not pcall(function() return s18:state() end),
    "state() on a defs-only store handed back a table nothing will ever persist")
check(not pcall(function() return s18:touchState() end),
    "touchState() on a defs-only store reported success")
local okImp, whyImp = s18:import("state")
check(okImp == false, "import('state') on a defs-only store did not refuse")
check(tostring(whyImp):find("state", 1, true) ~= nil,
    "the refusal did not name the document: " .. tostring(whyImp))
check(s18:import("nonsense") == false, "an unknown document name was imported")
check(s18:discard("state") == false, "discard('state') on a defs-only store did not refuse")
-- defs still works on the same store, so the refusals above are about the
-- missing document and not about the store having given up.
check(s18:touchDefs() == true, "the defs document stopped working")

realPrint = realPrint
print = realPrint
realPrint(string.format("RDConfigStore: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
