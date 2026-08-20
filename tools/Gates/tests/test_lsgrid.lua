-- SPDX-License-Identifier: GPL-3.0-or-later
-- test_lsgrid.lua - Longstrider's rectangle-editing geometry.
--
-- WHY THIS EXISTS: the drag-resize handles were reported dead, and the cause was
-- not in the drag at all. LSGridOverlay:_applyHandle refused any candidate
-- rectangle over the cell cap, so a region that reached the cap - or crossed it
-- by a route that never touched a handle (the Set button, lowering Cell size, a
-- loaded file) - froze every handle it had, INCLUDING the drags that would have
-- shrunk it back under. Silently. The only escape was to delete the tour, which
-- is precisely how it was reported: "you have to delete a zone to get it to
-- resize". A live tours file showed the fingerprint - two regions pinned at
-- exactly 400 cells behind a nextId of 43.
--
-- This overlay is also the interaction model M4's zone editor is built on
-- (docs/limes-design.md §11.1), so the geometry needs pinning before it is
-- inherited rather than after.
--
-- WHAT IT PINS:
--   * an over-cap region is still fully editable - the cap gates the RUN, not
--     the drawing, and _overCap exists only to colour the warning.
--   * MIN_SPAN pushes back on the edge being dragged, never on its anchor, so
--     dragging one edge past the other stops that edge instead of towing the
--     opposite one across the map (this is how a 5068x1 region got saved).
--   * a "mid" anchor leaves its free axis alone even when that axis is already
--     degenerate - an edge handle must not silently repair the other dimension.
--   * LSTour.cellCountOf agrees with #computeCells for every shape, including
--     the ragged partial-cell edges. The O(1) count replaced the materialising
--     one in two readouts; if they ever disagree, the status line and the
--     preflight are quoting different rules.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lsgrid.lua <repo-root>

local ROOT = arg[1] or "."
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end
local function rectEq(name, got, want)
    local g = string.format("{%s,%s,%s,%s}", tostring(got[1]), tostring(got[2]),
                                             tostring(got[3]), tostring(got[4]))
    local w = string.format("{%d,%d,%d,%d}", want[1], want[2], want[3], want[4])
    eq(name, g, w)
end

-- ---------------------------------------------------------------------------
-- Environment. Both files are client-side and bail on isServer(); LSGridOverlay
-- additionally measures a font at load time. Nothing else is touched until a
-- render, which this suite does not exercise.
-- ---------------------------------------------------------------------------

isServer = function() return false end
UIFont = { Small = "Small" }
getTextManager = function()
    return {
        getFontHeight    = function() return 12 end,
        MeasureStringX   = function(_, _, s) return #tostring(s) * 6 end,
    }
end

for _, f in ipairs({ "LSTour.lua", "LSGridOverlay.lua" }) do
    local okLoad, err = pcall(dofile, DIR .. f)
    if not okLoad then
        print("FATAL: could not load " .. DIR .. f)
        print("  " .. tostring(err))
        os.exit(2)
    end
end

-- A bare overlay: LSGridOverlay:new() would go hunting for a map widget to hook,
-- and none of the geometry under test reads one.
local function overlay(cellSize, maxCells)
    local o = setmetatable({}, LSGridOverlay)
    o.cellSize = cellSize or 50
    o.maxCells = maxCells or 400
    return o
end

-- Drive one handle drag end-to-end the way the mouse path does: pick the anchor
-- by id, snapshot the original, apply a world position.
local ANCHOR_IDX = { TL = 1, TC = 2, TR = 3, ML = 4, MR = 5, BL = 6, BC = 7, BR = 8 }
local function drag(o, region, anchorId, wx, wy)
    local t = { region = { region[1], region[2], region[3], region[4] } }
    o._dragTour   = t
    o._handleIdx  = ANCHOR_IDX[anchorId]
    o._handleOrig = { region[1], region[2], region[3], region[4] }
    o:_applyHandle(wx, wy)
    return t.region
end

-- ---------------------------------------------------------------------------
-- 1. The regression: the cap must not freeze the handles
-- ---------------------------------------------------------------------------

-- 993x999 at cellSize 50 is 20x20 = 400 cells: exactly the cap, which is where
-- the live file's selected tour was sitting. One tile of growth crosses it.
local o = overlay(50, 400)
eq("at-cap region counts 400 cells", o:_cellCount({ 5939, 9483, 6932, 10482 }), 400)
eq("at cap is not over cap",         o:_overCap({ 5939, 9483, 6932, 10482 }), false)

rectEq("an at-cap region can still grow",
    drag(o, { 5939, 9483, 6932, 10482 }, "BR", 8000, 11000),
    { 5939, 9483, 8000, 11000 })

-- The other half of the trap, and the worse one: once over the cap by any route,
-- every drag was refused - so the region could not be shrunk back either.
local big = { 0, 0, 20000, 20000 }
ok("the oversized region really is over cap", o:_overCap(big))
rectEq("an over-cap region can be shrunk",
    drag(o, big, "BR", 500, 500),
    { 0, 0, 500, 500 })
ok("...and the result is back under the cap", not o:_overCap({ 0, 0, 500, 500 }))

rectEq("an over-cap region can also be grown further",
    drag(o, big, "BR", 30000, 30000),
    { 0, 0, 30000, 30000 })

-- A cap of 0 disables the check entirely (LSTours.maxCells is a number, but the
-- guard reads `> 0` and nothing should depend on which branch that takes).
eq("maxCells 0 means no cap", overlay(50, 0):_overCap(big), false)

-- ---------------------------------------------------------------------------
-- 2. MIN_SPAN pushes back on the dragged edge
-- ---------------------------------------------------------------------------

o = overlay(50, 400)
local R = { 1000, 1000, 2000, 2000 }

-- Drag the LEFT edge rightwards past the right edge. The left edge must stop
-- 10 short of the right one; the right edge must not move at all.
rectEq("left edge dragged past right stops at MIN_SPAN",
    drag(o, R, "ML", 9999, 1500), { 1990, 1000, 2000, 2000 })

-- ...and the mirror: the right edge dragged left past the left edge.
rectEq("right edge dragged past left stops at MIN_SPAN",
    drag(o, R, "MR", -9999, 1500), { 1000, 1000, 1010, 2000 })

rectEq("top edge dragged past bottom stops at MIN_SPAN",
    drag(o, R, "TC", 1500, 9999), { 1000, 1990, 2000, 2000 })

rectEq("bottom edge dragged past top stops at MIN_SPAN",
    drag(o, R, "BC", 1500, -9999), { 1000, 1000, 2000, 1010 })

-- A corner collapses on both axes at once, each pushing back on its own edge.
rectEq("TL dragged past BR collapses both axes, BR unmoved",
    drag(o, R, "TL", 9999, 9999), { 1990, 1990, 2000, 2000 })

-- Exactly MIN_SPAN is legal; one under is not.
rectEq("a drag to exactly MIN_SPAN is left alone",
    drag(o, R, "ML", 1990, 1500), { 1990, 1000, 2000, 2000 })
rectEq("a drag to MIN_SPAN-1 is pushed back",
    drag(o, R, "ML", 1991, 1500), { 1990, 1000, 2000, 2000 })

-- ---------------------------------------------------------------------------
-- 3. A "mid" anchor never touches its free axis
-- ---------------------------------------------------------------------------

-- The sliver that was found in the live file. Dragging its LEFT edge is an
-- X-axis gesture; the 1-tile Y span is not the drag's business and repairing it
-- here would move geometry the admin never grabbed.
local sliver = { 4298, 10382, 9366, 10383 }
rectEq("ML on a degenerate-Y region leaves Y untouched",
    drag(o, sliver, "ML", 5000, 10382), { 5000, 10382, 9366, 10383 })
rectEq("TC on a degenerate-X region leaves X untouched",
    drag(o, { 100, 0, 105, 900 }, "TC", 999, 400), { 100, 400, 105, 900 })

-- ---------------------------------------------------------------------------
-- 4. Coordinates are floored, and only after the clamps
-- ---------------------------------------------------------------------------

rectEq("world coords are floored",
    drag(o, R, "BR", 1500.9, 1500.9), { 1000, 1000, 1500, 1500 })

-- ---------------------------------------------------------------------------
-- 5. cellCountOf must agree with computeCells for every shape
-- ---------------------------------------------------------------------------

local SHAPES = {
    { 0, 0, 100, 100 },            -- exact multiples
    { 0, 0, 101, 101 },            -- one tile into a second cell on both axes
    { 0, 0, 99, 99 },              -- under one cell
    { 0, 0, 1, 1 },                -- degenerate
    { 5939, 9483, 6932, 10482 },   -- the live at-cap region
    { 4298, 10382, 9366, 10383 },  -- the live sliver
    { -500, -500, 500, 500 },      -- negative origin
    { 4473, 9042, 5170, 10353 },   -- the live under-cap region
}
for _, cs in ipairs({ 1, 24, 50, 150 }) do
    for i, r in ipairs(SHAPES) do
        local walked = #(LSTour.computeCells(r, cs))
        local counted = LSTour.cellCountOf(r, cs)
        eq(string.format("cellCountOf == #computeCells (shape %d, cell %d)", i, cs),
            counted, walked)
    end
end

eq("cellCountOf(nil) is 0", LSTour.cellCountOf(nil, 50), 0)
eq("countCells sums the jobs", LSTour.countCells({
    { region = { 0, 0, 100, 100 } },   -- 2x2
    { region = { 0, 0, 50, 50 } },     -- 1x1
}, 50), 5)
eq("countCells of nothing is 0", LSTour.countCells(nil, 50), 0)

-- The cap readout the overlay shows and the count the tab shows are the same
-- function; pin that they cannot drift apart.
eq("overlay cell count delegates to LSTour",
    overlay(24, 400):_cellCount({ 0, 0, 240, 240 }),
    LSTour.cellCountOf({ 0, 0, 240, 240 }, 24))

print(string.format("LSGrid: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- Dragonfly Longstrider v0.3.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
