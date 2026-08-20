-- test_rdselect.lua - multi-row selection semantics for the data tabs.
--
-- ZERO STUBS. RDSelect takes the modifier state as arguments rather than reading
-- isKeyDown() itself, and carries no isServer() guard because it touches no
-- engine global at all - so this loads it exactly as the game does. Only RDJson
-- shares that property. That was the point of the design: selection behaviour is
-- fiddly (anchors, range direction, replace-vs-toggle) and it is exactly the kind
-- of logic that is miserable to verify by clicking around in-game and trivial to
-- verify here.
--
-- TWO IMPLEMENTATIONS, ONE SPEC. The legacy Dragonfly Workshop item predates
-- Core and cannot require RDSelect, so it ships a verbatim backport as
-- shared/DFSelect.lua. Both are run through the SAME assertions below, because
-- the same admins use both builds and muscle memory does not care which server
-- they are on. A behaviour change to one that is not made to the other fails
-- here rather than during an event.
--
-- The legacy tree lives in a SEPARATE repo, so it is optional: a clone without
-- PZMod alongside skips that suite with a notice instead of failing. Override the
-- location with PZMOD_ROOT if it lives somewhere else.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdselect.lua <repo-root>

local ROOT  = arg[1] or "."
local PZMOD = os.getenv("PZMOD_ROOT") or (ROOT .. "/../PZMod")

local TARGETS = {
    {
        label    = "RDSelect",
        global   = "RDSelect",
        path     = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDSelect.lua",
        required = true,
    },
    {
        label    = "DFSelect (legacy backport)",
        global   = "DFSelect",
        path     = PZMOD .. "/Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFSelect.lua",
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

-- Compare a selection against an expected id list, in display order.
local function sel(name, s, ordered, want)
    local got = table.concat(s:list(ordered), ",")
    eq(name, got, table.concat(want, ","))
end

local ROWS = { "a", "b", "c", "d", "e", "f" }

-- ---------------------------------------------------------------------------
-- The spec. Runs identically against every implementation.
-- ---------------------------------------------------------------------------

local function runSuite(S)
    -- -----------------------------------------------------------------------
    -- Plain click
    -- -----------------------------------------------------------------------

    local s = S.new()
    eq("starts empty", s:isEmpty(), true)
    eq("empty count", s:count(), 0)

    s:click("c", ROWS, false, false)
    sel("plain click selects one", s, ROWS, { "c" })
    eq("plain click sets the anchor", s.anchor, "c")

    s:click("e", ROWS, false, false)
    sel("plain click replaces", s, ROWS, { "e" })

    -- -----------------------------------------------------------------------
    -- Ctrl toggle - the behaviour Necro already had and must not lose
    -- -----------------------------------------------------------------------

    s = S.new()
    s:click("b", ROWS, false, false)
    s:click("d", ROWS, true, false)
    s:click("f", ROWS, true, false)
    sel("ctrl adds scattered rows", s, ROWS, { "b", "d", "f" })

    s:click("d", ROWS, true, false)
    sel("ctrl on a selected row removes it", s, ROWS, { "b", "f" })
    eq("ctrl still moves the anchor", s.anchor, "d")

    s:click("a", ROWS, false, false)
    sel("plain click resets a multi-selection", s, ROWS, { "a" })

    -- -----------------------------------------------------------------------
    -- Shift range
    -- -----------------------------------------------------------------------

    s = S.new()
    s:click("b", ROWS, false, false)
    s:click("e", ROWS, false, true)
    sel("shift selects the span", s, ROWS, { "b", "c", "d", "e" })

    -- Backwards: clicking ABOVE the anchor must produce the same span.
    s = S.new()
    s:click("e", ROWS, false, false)
    s:click("b", ROWS, false, true)
    sel("shift works upwards too", s, ROWS, { "b", "c", "d", "e" })

    -- The anchor behaviour that separates this from a naive implementation: a
    -- second shift-click re-extends from the ORIGINAL anchor instead of creeping
    -- from the last clicked row.
    s = S.new()
    s:click("b", ROWS, false, false)
    s:click("e", ROWS, false, true)
    s:click("c", ROWS, false, true)
    sel("second shift re-extends from the anchor", s, ROWS, { "b", "c" })
    eq("anchor survives a range", s.anchor, "b")

    -- A range REPLACES rather than adds - additive ranges are how a destructive
    -- action ends up applying to rows the admin never looked at. Note the span
    -- runs from "f", not "a": ctrl+click moved the anchor there (asserted above),
    -- so the range is f..c. What this pins is that "a" - selected before the
    -- shift - is GONE afterwards.
    s = S.new()
    s:click("a", ROWS, false, false)
    s:click("f", ROWS, true, false)
    s:click("c", ROWS, false, true)
    sel("range replaces, does not accumulate", s, ROWS, { "c", "d", "e", "f" })
    eq("the pre-range selection is discarded", s:has("a"), false)

    -- Shift with no anchor at all must still select something.
    s = S.new()
    s:click("d", ROWS, false, true)
    sel("shift with no anchor acts as a plain click", s, ROWS, { "d" })

    -- Anchor filtered out of the list: degrade to a plain click, never a no-op.
    s = S.new()
    s:click("a", ROWS, false, false)
    s:click("d", { "c", "d", "e" }, false, true)
    sel("orphaned anchor degrades to plain click", s, { "c", "d", "e" }, { "d" })

    -- -----------------------------------------------------------------------
    -- Display order and pruning
    -- -----------------------------------------------------------------------

    s = S.new()
    s:click("f", ROWS, false, false)
    s:click("a", ROWS, true, false)
    s:click("c", ROWS, true, false)
    sel("list() returns display order, not hash order", s, ROWS, { "a", "c", "f" })

    -- After a refresh or filter change, a selection can point at rows that are no
    -- longer shown. A bulk action must not silently apply to fewer rows than the
    -- admin can see, so pruning reports what it dropped.
    s = S.new()
    s:click("a", ROWS, false, false)
    s:click("c", ROWS, true, false)
    s:click("e", ROWS, true, false)
    eq("prune reports the drop count", s:prune({ "a", "c" }), 1)
    sel("prune keeps what survives", s, { "a", "c" }, { "a", "c" })

    s = S.new()
    s:click("e", ROWS, false, false)
    s:prune({ "a", "b" })
    eq("prune clears an orphaned anchor", s.anchor, nil)
    eq("prune emptied the selection", s:isEmpty(), true)

    -- list(ordered) is also the "visible only" filter the players tab relies on
    -- for its bulk actions: a selected row the filter is hiding must NOT be
    -- returned, so a bulk action can never reach someone off screen. count()
    -- still sees it, which is how the tab reports "N more hidden by the filter".
    s = S.new()
    s:click("a", ROWS, false, false)
    s:click("e", ROWS, true, false)
    sel("list() omits rows absent from the display order", s, { "a", "b", "c" }, { "a" })
    eq("count() still sees the hidden row", s:count(), 2)

    -- -----------------------------------------------------------------------
    -- Degenerate input
    -- -----------------------------------------------------------------------

    s = S.new()
    eq("nil id is ignored", s:click(nil, ROWS, false, false), false)
    eq("nil id leaves it empty", s:isEmpty(), true)

    s = S.new()
    s:click("b", nil, false, false)
    sel("no ordered list still allows plain click", s, nil, { "b" })

    s:only("z")
    eq("only() replaces wholesale", s:count(), 1)
    eq("only() sets the anchor", s.anchor, "z")

    s:clear()
    eq("clear empties", s:isEmpty(), true)
    eq("clear drops the anchor", s.anchor, nil)

    -- Numeric ids (vehicle ids, zombie online-ids) must work as well as strings.
    local NUMS = { 101, 102, 103, 104 }
    s = S.new()
    s:click(101, NUMS, false, false)
    s:click(103, NUMS, false, true)
    eq("numeric ids range correctly", table.concat(s:list(NUMS), ","), "101,102,103")

    -- Two independent selections must not share state - the tabs each own one.
    local a, b = S.new(), S.new()
    a:click("a", ROWS, false, false)
    b:click("f", ROWS, false, false)
    sel("instances are independent (first)",  a, ROWS, { "a" })
    sel("instances are independent (second)", b, ROWS, { "f" })
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
        -- Clear the global first so a load failure cannot silently re-test the
        -- previous implementation and report a false pass.
        _G[t.global] = nil
        local okLoad, err = pcall(dofile, t.path)
        if not okLoad then
            print("FATAL: could not load " .. t.path)
            print("  " .. tostring(err))
            os.exit(2)
        end
        local S = _G[t.global]
        if type(S) ~= "table" or type(S.new) ~= "function" then
            print("FAIL  " .. t.label .. " is not exposed by " .. t.path)
            fail = fail + 1
        else
            suite = t.label
            ran = ran + 1
            runSuite(S)
        end
    end
end

if ran == 0 then
    print("RDSelect: no implementation was testable")
    os.exit(2)
end

print(string.format("RDSelect: %d passed, %d failed (%d implementation%s)",
    pass, fail, ran, ran == 1 and "" or "s"))
os.exit(fail == 0 and 0 or 1)
