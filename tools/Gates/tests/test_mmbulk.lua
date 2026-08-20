-- test_mmbulk.lua - MMRestore.runMany aggregation: the bulk memoir restore.
--
-- WHAT THIS DOES AND DOES NOT COVER. It does NOT test restoring a character -
-- that needs IsoPlayer, the archive files and the snapshot codec. It tests the
-- BATCH layer that was added on top of the (unchanged) per-target
-- MMRestore.run: dedup, ordering, the batch cap, per-target fault containment,
-- and the summary string. That layer is pure bookkeeping over a stubbed run(),
-- so it is exactly the part that can be proven here instead of on a live server
-- during an event.
--
-- THE HEADLINE ASSERTION is "each target is restored from THEIR own archive".
-- The batch layer cannot verify archive contents, but it can verify the thing
-- that makes it true: run() is invoked once per selected name, with THAT name,
-- in order, and no ambient state is shared between iterations. If a refactor
-- ever hoists a target lookup out of the loop, the ordering assertions below
-- break.
--
-- Light stubs: MMRestore.lua guards on isServer() and requires two Memoir files
-- at load, none of which the batch layer touches. run() itself is replaced with
-- a scripted double.
--
-- Runs against the bundle AND the legacy PZMod backport, which carry an
-- identical copy of this code - same rationale as test_rdselect.lua. Override the
-- legacy location with PZMOD_ROOT; absent, that suite skips.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_mmbulk.lua <repo-root>

local ROOT  = arg[1] or "."
local PZMOD = os.getenv("PZMOD_ROOT") or (ROOT .. "/../PZMod")

local TARGETS = {
    {
        label    = "MMRestore (bundle)",
        path     = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/server/Memoirs/MMRestore.lua",
        required = true,
    },
    {
        label    = "MMRestore (legacy backport)",
        path     = PZMOD .. "/Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua",
        required = false,
    },
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
-- Engine stubs. Only what MMRestore.lua reaches at LOAD time.
-- ---------------------------------------------------------------------------

function isServer() return true end
function isClient() return false end
require = function() end            -- MMSvShared / MMSnapshotCodec: unused by the batch layer
Events  = { OnServerStarted = { Add = function() end } }
Capability = { CanModifyPlayerStatsInThePlayerStatsUI = "cap" }

local warned = {}
function MMwarn(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    warned[#warned + 1] = table.concat(parts, " ")
end

local ADMIN = { getUsername = function() return "AdminOmen" end }

-- ---------------------------------------------------------------------------
-- The spec
-- ---------------------------------------------------------------------------

local function runSuite(MR)
    -- Scripted double for the per-target restore. `calls` records the exact
    -- sequence of names it was handed, which is the property that matters.
    local calls, scripted
    local function arm(script)
        calls, scripted, warned = {}, script or {}, {}
        MR.run = function(admin, name)
            calls[#calls + 1] = name
            local r = scripted[name]
            if r == "throw" then error("simulated engine fault") end
            if r ~= nil then return r end
            return { ok = true, message = "Restored " .. tostring(name) }
        end
    end

    -- ---- the headline: per-target fan-out, in order -----------------------
    arm()
    local res = MR.runMany(ADMIN, { "alice", "bob", "carl", "dee", "eve" })
    eq("run() called once per selected target", #calls, 5)
    eq("each call got ITS OWN name, in display order",
        table.concat(calls, ","), "alice,bob,carl,dee,eve")
    eq("all-success is ok", res.ok, true)
    eq("all-success summary", res.message, "Restored 5 of 5.")

    -- ---- the XP% dial ----------------------------------------------------
    -- Clamping lives on the SERVER because the dial is a free-text client field,
    -- so the wire value is attacker-controlled. Absent must mean 100, or every
    -- pre-dial caller and every older client would silently restore at 0%.
    local frac = MR.restoreFraction
    eq("absent percent defaults to 100",           select(2, frac(nil)),   100)
    eq("absent percent is a full fraction",        select(1, frac(nil)),   1.0)
    eq("100 is a full fraction",                   select(1, frac(100)),   1.0)
    eq("60 becomes 0.6",                           select(1, frac(60)),    0.6)
    eq("0 is honoured, not treated as absent",     select(2, frac(0)),     0)
    eq("0 yields a zero fraction",                 select(1, frac(0)),     0.0)
    eq("above 100 clamps down",                    select(2, frac(500)),   100)
    eq("below 0 clamps up",                        select(2, frac(-1)),    0)
    eq("garbage falls back to 100, never to 0",    select(2, frac("abc")), 100)
    eq("a numeric string is accepted",             select(2, frac("60")),  60)
    eq("fractional input rounds to an integer",    select(2, frac(59.6)),  60)

    -- The dial has to reach EVERY target in a batch, not just the first.
    local seenPct = {}
    calls, warned = {}, {}
    MR.run = function(admin, name, pct)
        calls[#calls + 1] = name
        seenPct[name] = pct
        return { ok = true, message = "Restored " .. tostring(name) }
    end
    res = MR.runMany(ADMIN, { "alice", "bob", "carl" }, 60)
    eq("the dial reaches the first target",  seenPct.alice, 60)
    eq("the dial reaches the last target",   seenPct.carl,  60)
    eq("a non-100 dial is surfaced in the summary", res.message,
        "Restored 3 of 3 - 60% of earned XP.")

    -- At 100 the summary must stay clean - no noise on the common path.
    arm()
    res = MR.runMany(ADMIN, { "alice", "bob" }, 100)
    eq("a 100% dial adds nothing to the summary", res.message, "Restored 2 of 2.")

    -- Single-target still delegates, and still carries the dial.
    local gotPct = nil
    calls = {}
    MR.run = function(admin, name, pct)
        calls[#calls + 1] = name; gotPct = pct
        return { ok = true, message = "Restored " .. tostring(name) }
    end
    MR.runMany(ADMIN, { "alice" }, 40)
    eq("the single-target path carries the dial too", gotPct, 40)

    -- ---- duplicates ------------------------------------------------------
    -- A name listed twice would restore, then trip its own once-per-life gate
    -- on the second pass and report a failure that is really just the dupe.
    arm()
    res = MR.runMany(ADMIN, { "alice", "bob", "alice", "bob", "carl" })
    eq("duplicates collapse", table.concat(calls, ","), "alice,bob,carl")
    eq("dedup preserves first-seen order", res.message, "Restored 3 of 3.")

    -- ---- single target delegates -----------------------------------------
    -- Every ordinary single-select click lands here; its richer message must be
    -- passed through untouched rather than replaced by a batch summary.
    arm()
    res = MR.runMany(ADMIN, { "alice" })
    eq("single target calls run once", #calls, 1)
    eq("single target passes the run() result straight through",
        res.message, "Restored alice")

    -- Blank entries are dropped before the count is taken, so this is still the
    -- single-target path.
    arm()
    res = MR.runMany(ADMIN, { "", "alice" })
    eq("blank names are dropped", table.concat(calls, ","), "alice")
    eq("dropping a blank still delegates as single", res.message, "Restored alice")

    -- ---- partial failure is the NORMAL case ------------------------------
    arm({ bob = { ok = false, reason = "bob must be online to restore." } })
    res = MR.runMany(ADMIN, { "alice", "bob" })
    eq("partial batch still attempts every target", #calls, 2)
    eq("partial batch is reported as ok", res.ok, true)
    eq("partial batch names the skip count",
        res.message, "Restored 1 of 2 - 1 skipped - see Console tab.")

    -- Nothing landed: must NOT read as success, or the admin sees a cheerful
    -- green "Restored 0 of 2".
    arm({
        alice = { ok = false, reason = "already recalled this life." },
        bob   = { ok = false, reason = "bob must be online to restore." },
    })
    res = MR.runMany(ADMIN, { "alice", "bob" })
    eq("a batch where nothing landed is a failure", res.ok, false)
    eq("total-failure summary", res.reason,
        "Restored 0 of 2 - 2 skipped - see Console tab.")

    -- ---- one fault must not abandon the batch ----------------------------
    arm({ alice = "throw" })
    res = MR.runMany(ADMIN, { "alice", "bob", "carl" })
    eq("a throwing target does not stop the rest", table.concat(calls, ","),
        "alice,bob,carl")
    eq("the throw is counted as a skip", res.message,
        "Restored 2 of 3 - 1 skipped - see Console tab.")
    eq("the throw was logged loudly", #warned > 0, true)

    -- ---- the batch cap ---------------------------------------------------
    -- Silent truncation would read as "the other 3 failed" rather than "never
    -- attempted", so the cap has to be named in the summary.
    local many = {}
    for i = 1, 13 do many[i] = "p" .. i end
    arm()
    res = MR.runMany(ADMIN, many)
    eq("the cap bounds how many restores actually run", #calls, 10)
    eq("the cap keeps the FIRST selected, in order",
        table.concat(calls, ","), "p1,p2,p3,p4,p5,p6,p7,p8,p9,p10")
    eq("overflow is reported, not swallowed", res.message,
        "Restored 10 of 10 - 3 over the 10 cap - see Console tab.")

    -- ---- degenerate input ------------------------------------------------
    arm()
    res = MR.runMany(ADMIN, {})
    eq("empty selection refuses", res.ok, false)
    eq("empty selection says so", res.reason, "No targets selected.")
    eq("empty selection restores nobody", #calls, 0)

    arm()
    res = MR.runMany(ADMIN, nil)
    eq("nil selection refuses", res.ok, false)
    eq("nil selection restores nobody", #calls, 0)

    arm()
    res = MR.runMany(ADMIN, "alice")
    eq("a bare string is not a selection", res.ok, false)
    eq("a bare string restores nobody", #calls, 0)

    -- ---- per-target reporting reaches the audit channel ------------------
    -- The reply is one HaloText line and cannot carry N reasons; the Console tab
    -- is where an admin finds out WHY someone was skipped.
    local audited = {}
    DFCore = { audit = function(action, player, extra)
        audited[#audited + 1] = tostring(action) .. "|" .. tostring(extra)
    end }
    arm({ bob = { ok = false, reason = "bob is dead" } })
    MR.runMany(ADMIN, { "alice", "bob" })
    eq("one audit line per target", #audited, 2)
    eq("the successful target is audited as restored",
        audited[1], "memoirRestore|target=alice (restored)")
    eq("the skipped target is audited WITH the reason",
        audited[2], "memoirRestore|target=bob (skipped: bob is dead)")

    -- Over-cap targets are audited too, distinctly from a failure.
    audited = {}
    arm()
    MR.runMany(ADMIN, many)
    eq("every target is accounted for, attempted or not", #audited, 13)
    eq("the 13th is audited as not attempted",
        audited[13], "memoirRestore|target=p13 (skipped: not attempted, batch cap 10)")
    DFCore = nil
end

-- ---------------------------------------------------------------------------
-- Drive every implementation through it
-- ---------------------------------------------------------------------------

local ran = 0
for _, t in ipairs(TARGETS) do
    local fh = io.open(t.path, "r")
    if not fh then
        if t.required then
            print("FATAL: could not find " .. t.path)
            os.exit(2)
        end
        print("SKIP  " .. t.label .. " - not present at " .. t.path)
    else
        fh:close()
        -- Clear first: MMRestore.lua does `MMRestore = MMRestore or {}`, so a
        -- failed load would otherwise silently re-test the previous copy.
        MMRestore = nil
        local okLoad, err = pcall(dofile, t.path)
        if not okLoad then
            print("FATAL: could not load " .. t.path)
            print("  " .. tostring(err))
            os.exit(2)
        end
        if type(MMRestore) ~= "table" or type(MMRestore.runMany) ~= "function" then
            print("FAIL  " .. t.label .. ": MMRestore.runMany is not exposed")
            fail = fail + 1
        else
            suite = t.label
            ran = ran + 1
            runSuite(MMRestore)
        end
    end
end

if ran == 0 then
    print("MMBulk: no implementation was testable")
    os.exit(2)
end

print(string.format("MMBulk: %d passed, %d failed (%d implementation%s)",
    pass, fail, ran, ran == 1 and "" or "s"))
os.exit(fail == 0 and 0 or 1)
