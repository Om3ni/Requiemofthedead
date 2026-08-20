-- test_mmaudit.lua - which events are allowed to move the recovery point.
--
-- Memoirs/<user>/latest.json is what MMRestore.readLatest recovers from, and it
-- is the file that answers "when did this player last save". It used to be
-- overwritten by ANY snapshot-bearing event, which meant every admin restore
-- rewrote the recovery point with itself: the snapshot inside stayed correct but
-- the envelope described the restore, so the archive reported the wrong age and
-- archiveT chained restore->restore instead of naming the write it came from.
-- Found live on 2026-07-28 with latest.json reading day 18.52 while holding a
-- snapshot written on day 3.19.
--
-- Nothing in the file layer is verifiable by reading the code - "does a restore
-- move latest.json" is a question about which of two writers got called - so
-- getFileWriter is stubbed and every write is captured by path.
--
-- Also runs against the legacy PZMod backport when that tree is present. The two
-- copies WERE byte-identical; they no longer are. 42.20 added a write-extension
-- allowlist that made getFileWriter refuse ".jsonl"/".json" outright, so the
-- bundle moved to "events.jsonl.log" / "latest.json.txt" (see RDShared.EXT_*)
-- while the archived backport keeps the pre-42.20 names. That is a deliberate
-- divergence - PZMod is frozen and its Workshop item sunsets - so the FILENAMES
-- are per-target below while the behavioural spec stays shared. Do not "resync"
-- them; the archived copy is a record of what shipped, not a live target.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_mmaudit.lua <repo-root>

local ROOT  = arg[1] or "."
local PZMOD = os.getenv("PZMOD_ROOT") or (ROOT .. "/../PZMod")

local TARGETS = {
    -- enforceExt: is this tree expected to run on 42.20? Only the bundle is.
    { label = "MMAudit (bundle)", required = true, enforceExt = true,
      events = "events.jsonl.log", latest = "latest.json.txt",
      path = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/server/Memoirs/MMAudit.lua" },
    { label = "MMAudit (legacy backport)", required = false, enforceExt = false,
      events = "events.jsonl", latest = "latest.json",
      path = PZMOD .. "/Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua" },
}

local pass, fail = 0, 0
local suite = "?"
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL [" .. suite .. "] " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

-- ---------------------------------------------------------------------------
-- Engine stubs. Writes are captured rather than performed.
-- ---------------------------------------------------------------------------

function isServer() return true end
function isClient() return false end
require = function() end

-- The bundle copy reads these at file scope. `require` is a no-op stub here, so
-- the real RDShared never loads and the global has to be supplied outright -
-- otherwise MMAudit dies with "attempt to index global 'RDShared'". Values must
-- track RDShared.lua; the per-target filenames above encode the same strings, so
-- a drift between them shows up as a failed assertion rather than silence.
RDShared = {
    EXT_STREAM        = ".jsonl.log",
    EXT_DOC           = ".json.txt",
    EXT_STREAM_LEGACY = ".jsonl",
    EXT_DOC_LEGACY    = ".json",
}
Events = setmetatable({}, { __index = function(t, k)
    local e = { Add = function() end }; rawset(t, k, e); return e
end })

function getTimestamp() return 1785000000 end
function getGameTime()
    return { getWorldAgeHours = function() return 72.0 end }   -- day 3.0
end
function MMname(p) return type(p) == "string" and p or "?" end
local warnings = {}
function MMwarn(message) warnings[#warnings + 1] = tostring(message) end
function MMlog() end

local perkNone, perkMax = {}, {}
local testPerk = {
    getType = function(self) return self end,
    getId = function() return "Carpentry" end,
}
PerkFactory = {
    PerkList = {
        size = function() return 3 end,
        get = function(_, i)
            if i == 0 then return { getType = function() return perkNone end } end
            if i == 1 then return testPerk end
            return { getType = function() return perkMax end }
        end,
    },
    Perks = { None = perkNone, MAX = perkMax },
}

local writes = {}   -- { path = "...", line = "...", append = bool }
local refusedSuffix
function getFileWriter(path, _createIfNull, append)
    if refusedSuffix and path:sub(-#refusedSuffix) == refusedSuffix then return nil end
    return {
        write = function(_, s) writes[#writes + 1] = { path = path, line = s, append = append } end,
        close = function() end,
    }
end

local function pathsWritten()
    local out = {}
    for _, w in ipairs(writes) do out[#out + 1] = w.path end
    return out
end

local function wrote(suffix)
    for _, w in ipairs(writes) do
        if w.path:sub(-#suffix) == suffix then return true end
    end
    return false
end

local SNAP = { perks = { Blacksmith = 16275 }, traits = { "handy" },
               recipes = { "Forge" }, profession = "unemployed", writtenAt = 1784000000 }

-- ---------------------------------------------------------------------------
-- The spec
-- ---------------------------------------------------------------------------

-- EV/LA are the target's history and recovery-point basenames. They differ across
-- the 42.20 rename (see TARGETS), so the spec below asserts on them rather than on
-- literals - the behaviour under test is which writer fires, never what it is called.
local function runSuite(MA, EV, LA, enforceExt)
    -- ---- a voluntary WRITE moves the recovery point ------------------------
    writes = {}
    local result = MA.log("Omen", "WRITE", { snap = SNAP, itemId = 1 })
    eq("WRITE appends to " .. EV,            wrote("Omen/" .. EV), true)
    eq("WRITE moves " .. LA,                 wrote("Omen/" .. LA), true)
    eq("WRITE writes the _all.log timeline", wrote("_all.log"),    true)
    if enforceExt then
        eq("WRITE reports a healthy history sink", result.history, true)
        eq("WRITE reports a healthy recovery sink", result.recovery, true)
        eq("WRITE reports a healthy timeline sink", result.timeline, true)
    end

    -- ---- an admin restore does NOT ----------------------------------------
    -- The whole fix. A restore is history, not a save.
    writes = {}
    MA.log("Omen", "RESTORE_OK", { snap = SNAP, admin = "Kriegan", xpPct = 60 })
    eq("RESTORE_OK is still recorded in " .. EV, wrote("Omen/" .. EV), true)
    eq("RESTORE_OK does NOT move " .. LA,        wrote("Omen/" .. LA), false)
    eq("RESTORE_OK still hits the timeline",     wrote("_all.log"),    true)

    -- The snapshot must survive INTO the history file - dropping it would lose
    -- what a restore actually applied, which is the point of keeping the record.
    local sawSnap = false
    for _, w in ipairs(writes) do
        if w.path:sub(-#EV) == EV and w.line:find('"snap"', 1, true) then
            sawSnap = true
        end
    end
    eq("RESTORE_OK keeps its snapshot in " .. EV, sawSnap, true)

    -- ---- other snapshot-bearing events are equally excluded ---------------
    writes = {}
    MA.log("Omen", "READ_RECHECK", { snap = SNAP })
    eq("READ_RECHECK does not move " .. LA, wrote("Omen/" .. LA), false)

    -- ---- snapless events touch neither snapshot file ----------------------
    writes = {}
    MA.log("Omen", "WRITE_NOITEM", { itemId = 7 })
    eq("a snapless WRITE_NOITEM appends history",  wrote("Omen/" .. EV), true)
    eq("a snapless event never moves " .. LA,      wrote("Omen/" .. LA), false)

    -- ---- a WRITE with no snapshot is still not a save ---------------------
    -- Belt and braces: the gate is (has snapshot AND is a WRITE), not either.
    writes = {}
    MA.log("Omen", "WRITE", { itemId = 9 })
    eq("a WRITE carrying no snapshot cannot move " .. LA,
        wrote("Omen/" .. LA), false)

    -- ---- per-user separation ----------------------------------------------
    writes = {}
    MA.log("Kriegan", "WRITE", { snap = SNAP })
    eq("a second user writes its own " .. LA, wrote("Kriegan/" .. LA), true)
    eq("and does not touch the first user's",  wrote("Omen/" .. LA),    false)

    -- ---- the recovery point is the LAST write, not the first --------------
    writes = {}
    MA.log("Omen", "WRITE", { snap = SNAP })
    MA.log("Omen", "RESTORE_OK", { snap = SNAP })
    MA.log("Omen", "WRITE", { snap = SNAP })
    local latestCount = 0
    for _, w in ipairs(writes) do
        if w.path:sub(-#("Omen/" .. LA)) == "Omen/" .. LA then latestCount = latestCount + 1 end
    end
    eq("two writes and a restore move the point exactly twice", latestCount, 2)

    -- The recovery point must be a TRUNCATING write - appending would grow a
    -- file the reader treats as a single JSON object.
    for _, w in ipairs(writes) do
        if w.path:sub(-#LA) == LA then
            eq(LA .. " is truncated, not appended", w.append, false)
            break
        end
    end

    -- The rename is only safe if the engine would actually accept these names:
    -- every captured path must end in an allowlisted extension, or 42.20's
    -- getFileWriter hands back nil and the whole file layer goes quiet again.
    -- Live targets only. The archived backport genuinely fails this - it predates
    -- the allowlist and is not being fixed - and asserting against a frozen tree
    -- would just paint the suite red for a fact already recorded in the header.
    if enforceExt then
        local allowed = { ini = true, cfg = true, txt = true, log = true }
        local badExt
        for _, w in ipairs(writes) do
            local ext = w.path:match("%.([^%.]+)$")
            if not (ext and allowed[ext]) then badExt = w.path; break end
        end
        eq("every write target has an engine-allowed extension", badExt, nil)

        -- A refused canonical recovery writer is a visible secondary-sink
        -- failure. History and timeline still land, no flat path is invented,
        -- and repeated failures increment the counter without flooding warnings.
        writes, warnings = {}, {}
        refusedSuffix = "Omen/" .. LA
        local before = MA.writeFailures()
        local refused = MA.log("Omen", "WRITE", { snap = SNAP, itemId = 10 })
        eq("refused recovery leaves history available", refused.history, true)
        eq("refused recovery reports false", refused.recovery, false)
        eq("refused recovery leaves timeline available", refused.timeline, true)
        eq("refused recovery increments the visible counter", MA.writeFailures(), before + 1)
        eq("refused recovery emits one diagnostic", #warnings, 1)
        eq("refused recovery never writes a flat fallback", wrote("Omen." .. LA), false)

        MA.log("Omen", "WRITE", { snap = SNAP, itemId = 11 })
        eq("a repeated refusal still increments the counter", MA.writeFailures(), before + 2)
        eq("a repeated refusal does not flood diagnostics", #warnings, 1)
        refusedSuffix = nil

        -- Progression evidence is one complete observation, never two partial
        -- prefix tables. Missing XP is an explicit unavailable result.
        local samplePlayer = {
            getXp = function() return { getXP = function() return 123.5 end } end,
            getPerkLevel = function() return 3 end,
        }
        local sample = MA.sampleProgression(samplePlayer)
        eq("progression sample succeeds", sample.ok, true)
        eq("progression sample captures level", sample.levels.Carpentry, 3)
        eq("progression sample captures raw XP", sample.xp.Carpentry, 123.5)

        local unavailable = MA.sampleProgression({ getXp = function() return nil end })
        eq("missing XP refuses the sample", unavailable.ok, false)
        eq("missing XP returns no partial levels", unavailable.levels, nil)
        local fields = MA.attachProgression({}, unavailable, sample)
        eq("unavailable before-sample is named", fields.sampleBeforeError, "player XP unavailable")
        eq("complete after-sample keeps levels", fields.lvlsAfter.Carpentry, 3)
        eq("complete after-sample keeps XP", fields.postXP.Carpentry, 123.5)

        writes = {}
        local queued = MA.scheduleRecheck(samplePlayer, 12, unavailable)
        eq("unavailable baseline is not queued", queued, false)
        local saidUnavailable = false
        for _, w in ipairs(writes) do
            if w.line:find("baseline_unavailable", 1, true) then saidUnavailable = true end
        end
        eq("unavailable baseline is recorded immediately", saidUnavailable, true)
    end
end

-- ---------------------------------------------------------------------------
-- Drive every implementation
-- ---------------------------------------------------------------------------

local ran = 0
for _, t in ipairs(TARGETS) do
    local fh = io.open(t.path, "r")
    if not fh then
        if t.required then
            print("FATAL: could not find " .. t.path); os.exit(2)
        end
        print("SKIP  " .. t.label .. " - not present at " .. t.path)
    else
        fh:close()
        MMAudit = nil
        local okLoad, err = pcall(dofile, t.path)
        if not okLoad then
            print("FATAL: could not load " .. t.path)
            print("  " .. tostring(err)); os.exit(2)
        end
        if type(MMAudit) ~= "table" or type(MMAudit.log) ~= "function" then
            print("FAIL  " .. t.label .. ": MMAudit.log is not exposed")
            fail = fail + 1
        else
            suite = t.label; ran = ran + 1
            runSuite(MMAudit, t.events, t.latest, t.enforceExt)
        end
    end
end

if ran == 0 then print("MMAudit: no implementation was testable"); os.exit(2) end
print(string.format("MMAudit: %d passed, %d failed (%d implementation%s)",
    pass, fail, ran, ran == 1 and "" or "s"))
os.exit(fail == 0 and 0 or 1)
