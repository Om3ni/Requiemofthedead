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
-- Also runs against the legacy PZMod backport when that tree is present, since
-- the two copies are byte-identical and must stay that way.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_mmaudit.lua <repo-root>

local ROOT  = arg[1] or "."
local PZMOD = os.getenv("PZMOD_ROOT") or (ROOT .. "/../PZMod")

local TARGETS = {
    { label = "MMAudit (bundle)", required = true,
      path = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/server/Memoirs/MMAudit.lua" },
    { label = "MMAudit (legacy backport)", required = false,
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
Events = setmetatable({}, { __index = function(t, k)
    local e = { Add = function() end }; rawset(t, k, e); return e
end })

function getTimestamp() return 1785000000 end
function getGameTime()
    return { getWorldAgeHours = function() return 72.0 end }   -- day 3.0
end
function MMname(p) return type(p) == "string" and p or "?" end
function MMwarn() end
function MMlog() end

local writes = {}   -- { path = "...", line = "...", append = bool }
function getFileWriter(path, _createIfNull, append)
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

local function runSuite(MA)
    -- ---- a voluntary WRITE moves the recovery point ------------------------
    writes = {}
    MA.log("Omen", "WRITE", { snap = SNAP, itemId = 1 })
    eq("WRITE appends to events.jsonl",      wrote("Omen/events.jsonl"), true)
    eq("WRITE moves latest.json",            wrote("Omen/latest.json"),  true)
    eq("WRITE writes the _all.log timeline", wrote("_all.log"),          true)

    -- ---- an admin restore does NOT ----------------------------------------
    -- The whole fix. A restore is history, not a save.
    writes = {}
    MA.log("Omen", "RESTORE_OK", { snap = SNAP, admin = "Kriegan", xpPct = 60 })
    eq("RESTORE_OK is still recorded in events.jsonl", wrote("Omen/events.jsonl"), true)
    eq("RESTORE_OK does NOT move latest.json",         wrote("Omen/latest.json"),  false)
    eq("RESTORE_OK still hits the timeline",           wrote("_all.log"),          true)

    -- The snapshot must survive INTO events.jsonl - dropping it would lose what
    -- a restore actually applied, which is the point of keeping the record.
    local sawSnap = false
    for _, w in ipairs(writes) do
        if w.path:sub(-#"events.jsonl") == "events.jsonl" and w.line:find('"snap"', 1, true) then
            sawSnap = true
        end
    end
    eq("RESTORE_OK keeps its snapshot in events.jsonl", sawSnap, true)

    -- ---- other snapshot-bearing events are equally excluded ---------------
    writes = {}
    MA.log("Omen", "READ_RECHECK", { snap = SNAP })
    eq("READ_RECHECK does not move latest.json", wrote("Omen/latest.json"), false)

    -- ---- snapless events touch neither snapshot file ----------------------
    writes = {}
    MA.log("Omen", "WRITE_NOITEM", { itemId = 7 })
    eq("a snapless WRITE_NOITEM appends history", wrote("Omen/events.jsonl"), true)
    eq("a snapless event never moves latest.json", wrote("Omen/latest.json"), false)

    -- ---- a WRITE with no snapshot is still not a save ---------------------
    -- Belt and braces: the gate is (has snapshot AND is a WRITE), not either.
    writes = {}
    MA.log("Omen", "WRITE", { itemId = 9 })
    eq("a WRITE carrying no snapshot cannot move latest.json",
        wrote("Omen/latest.json"), false)

    -- ---- per-user separation ----------------------------------------------
    writes = {}
    MA.log("Kriegan", "WRITE", { snap = SNAP })
    eq("a second user writes its own latest.json", wrote("Kriegan/latest.json"), true)
    eq("and does not touch the first user's",      wrote("Omen/latest.json"),    false)

    -- ---- the recovery point is the LAST write, not the first --------------
    writes = {}
    MA.log("Omen", "WRITE", { snap = SNAP })
    MA.log("Omen", "RESTORE_OK", { snap = SNAP })
    MA.log("Omen", "WRITE", { snap = SNAP })
    local latestCount = 0
    for _, w in ipairs(writes) do
        if w.path:sub(-#"Omen/latest.json") == "Omen/latest.json" then latestCount = latestCount + 1 end
    end
    eq("two writes and a restore move the point exactly twice", latestCount, 2)

    -- latest.json must be a TRUNCATING write - appending would grow a file the
    -- reader treats as a single JSON object.
    for _, w in ipairs(writes) do
        if w.path:sub(-#"latest.json") == "latest.json" then
            eq("latest.json is truncated, not appended", w.append, false)
            break
        end
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
            runSuite(MMAudit)
        end
    end
end

if ran == 0 then print("MMAudit: no implementation was testable"); os.exit(2) end
print(string.format("MMAudit: %d passed, %d failed (%d implementation%s)",
    pass, fail, ran, ran == 1 and "" or "s"))
os.exit(fail == 0 and 0 or 1)
