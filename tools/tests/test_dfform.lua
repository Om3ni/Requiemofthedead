-- test_dfform.lua - DFForm's scroll behaviour and hit-testing.
--
-- WHY THIS EXISTS: the Janitor view's dials ran off the bottom of their rect
-- and the form simply stopped drawing, printing "+N more - make the panel
-- taller". There was no taller to make, so the settings past the fold were
-- unreachable - visible in the schema, absent from the screen. DFForm is the
-- shared renderer behind both that view and the deck's settings window, so the
-- fix lives here and so does its proof.
--
-- WHAT IT PINS:
--   * THE BUG: with a schema longer than its rect, the LAST entry is reachable.
--     Scroll to the end and it has a hit rect, which is the whole complaint.
--   * a schema that fits produces no scrollbar and no scroll range - the bar is
--     not permanent chrome.
--   * rows scrolled out of view get NO hit rect. Drawing and clicking must
--     agree; a row you cannot see must not be a row you can click.
--   * the wheel's two jobs, and which one wins. Over a number box it is still
--     the dial's coarse-travel control (the older, more specific contract);
--     anywhere else it scrolls.
--   * thumb drag maps cursor travel to scroll and reports itself as a drag, so
--     releasing the thumb is not also a click on whatever row slid under it.
--   * setStencilRect is balanced by clearStencilRect on every path. An unpaired
--     stencil clips the rest of the host panel, which reads as unrelated UI
--     "disappearing" - the exact symptom this file was fixing.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfform.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFForm.lua"

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

-- ---------------------------------------------------------------------------
-- Engine + DFKit stubs
-- ---------------------------------------------------------------------------

require = function() end
isServer = function() return false end

local FH = 12
getTextManager = function()
    return {
        MeasureStringX = function(self, f, s) return #tostring(s or "") * 6 end,
        getFontHeight  = function(self, f) return FH end,
    }
end
UIFont = { Small = "small" }
getMouseX = function() return 0 end
getMouseY = function() return 0 end

local function col(r, g, b) return { r = r, g = g, b = b } end
DFKit = {
    font    = { small = "small" },
    metrics = { pad = 8, gap = 6, btnH = 20 },
    alpha   = { inset = 0.3 },
    col = {
        text = col(1,1,1), textDim = col(.6,.6,.6), line = col(.3,.3,.3),
        accent = col(0,.7,1), accentDim = col(0,.4,.6),
        bg = col(0,0,0), panel = col(.2,.2,.2), warn = col(1,.6,0),
    },
}
DFHelp = { show = function() end }

-- ISPanel: only what DFForm touches. The Hotspot chains to these for anything
-- it does not claim, so they must exist and must be harmless.
ISPanel = {}
function ISPanel:derive(name)
    local t = {}
    setmetatable(t, { __index = self })
    t.derive = ISPanel.derive
    return t
end
function ISPanel:onMouseDown(x, y) return false end
function ISPanel:onMouseMove(dx, dy) end
function ISPanel:onMouseMoveOutside(dx, dy) end
function ISPanel:onMouseUpOutside(x, y) end

local stencilSet, stencilClear = 0, 0
local EL = {
    drawText        = function() end,
    drawRect        = function() end,
    drawRectBorder  = function() end,
    setStencilRect  = function() stencilSet = stencilSet + 1 end,
    clearStencilRect = function() stencilClear = stencilClear + 1 end,
}

local SCROLL = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFScroll.lua"
-- DFForm delegates its scrolling to DFScroll and `require` is stubbed out, so
-- the primitive has to be loaded by hand first.
local okScroll, scrollErr = pcall(dofile, SCROLL)
if not okScroll then
    print("FATAL: could not load " .. SCROLL)
    print("  " .. tostring(scrollErr))
    os.exit(2)
end

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local function buildSchema(nInts, nBools)
    local s = { { group = "Numbers" } }
    for i = 1, nInts do
        s[#s + 1] = { key = "int" .. i, kind = "int", label = "Int " .. i,
                      min = 0, max = 1000, step = 5, help = "help" }
    end
    s[#s + 1] = { group = "Switches" }
    for i = 1, nBools do
        s[#s + 1] = { key = "bool" .. i, kind = "bool", label = "Bool " .. i }
    end
    return s
end

local values = {}
local function newForm(schema)
    values = {}
    for _, e in ipairs(schema) do
        if e.key then values[e.key] = (e.kind == "bool") and false or 100 end
    end
    return DFForm.new{
        schema  = schema,
        title   = "Test",
        get     = function(k) return values[k] end,
        set     = function(k, v) values[k] = v end,
        enabled = function() return true end,
    }
end

local RX, RY, RW, RH = 40, 25, 400, 200

local function rectFor(form, key)
    for _, rc in ipairs(form.rects) do
        if rc.e and rc.e.key == key then return rc end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1. A schema that fits gets no scrollbar and no range.
-- ---------------------------------------------------------------------------

local short = buildSchema(2, 1)
local f = newForm(short)
f:layout(RX, RY, RW, RH)
f:draw(EL)

eq("short schema has no scroll range", f.scroll.max, 0)
eq("short schema draws no bar", f.scroll.bar, nil)
eq("short schema wheel does not scroll", f.scroll:scrollBy(50), false)
ok("every short-schema row is hit-testable",
   rectFor(f, "int1") and rectFor(f, "int2") and rectFor(f, "bool1"),
   "rects = " .. #f.rects)

-- A form given EXACTLY contentHeight() must not scroll. DFSettingsWindow sizes
-- its body to that number, so any padding counted outside it would hang a
-- scrollbar on a window built to fit its own contents.
local exact = newForm(buildSchema(3, 3))
exact:layout(RX, RY, RW, exact:contentHeight())
exact:draw(EL)
eq("a form sized to contentHeight has no scroll range", exact.scroll.max, 0)
eq("a form sized to contentHeight draws no bar", exact.scroll.bar, nil)
ok("and its last row is still hit-testable", rectFor(exact, "bool3") ~= nil)

-- ---------------------------------------------------------------------------
-- 2. A schema that overflows gets a range and a bar.
-- ---------------------------------------------------------------------------

local long = buildSchema(12, 12)
f = newForm(long)
f:layout(RX, RY, RW, RH)
f:draw(EL)

local content = f:contentHeight()
ok("long schema overflows its rect", content > RH,
   "content " .. content .. " vs rect " .. RH)
ok("long schema has a scroll range", f.scroll.max > 0, "maxScroll " .. tostring(f.scroll.max))
ok("long schema draws a bar", f.scroll.bar ~= nil)
ok("thumb is shorter than its track", f.scroll.bar and f.scroll.bar.thumbH < f.scroll.bar.h,
   f.scroll.bar and (f.scroll.bar.thumbH .. " vs " .. f.scroll.bar.h))
ok("bar sits inside the rect's right edge",
   f.scroll.bar and f.scroll.bar.x + f.scroll.bar.w == RX + RW,
   f.scroll.bar and (f.scroll.bar.x + f.scroll.bar.w))

-- ---------------------------------------------------------------------------
-- 3. THE BUG. The last entry in an overflowing schema must be reachable.
-- ---------------------------------------------------------------------------

eq("last row is off-screen before scrolling", rectFor(f, "bool12"), nil)

f.scroll.offset = f.scroll.max
f:draw(EL)

ok("last row IS hit-testable once scrolled to the end", rectFor(f, "bool12") ~= nil,
   "this is the reported bug: settings past the fold were unreachable")
eq("first row is now off-screen", rectFor(f, "int1"), nil)

-- A row that cannot be seen must not be clickable. That position is not empty
-- once scrolled - a later row occupies it now - so the invariant is that every
-- registered hit rect overlaps the visible band, and that the row which slid
-- away no longer answers where it used to be.
local outside = 0
for _, rcx in ipairs(f.rects) do
    if rcx.y + rcx.h < RY or rcx.y > RY + RH then outside = outside + 1 end
end
eq("no hit rect lies outside the viewport", outside, 0)

-- The hotspot spans exactly the rect, so those are the only coordinates rowAt
-- ever sees. The top edge must stay live: a row clipped to a sliver by the
-- stencil is still the row drawn there, and must still be the row clicked.
ok("the top edge is clickable", f:rowAt(RX + 20, RY) ~= nil)

-- And the whole point of the fix: the last setting is not merely visible once
-- scrolled to, it is CLICKABLE where it is drawn. (The final few pixels of the
-- rect are BOT_PAD, deliberately no row's territory.)
local lastRc = rectFor(f, "bool12")
ok("the last row is clickable where it is drawn",
   lastRc ~= nil and f:rowAt(RX + 20, lastRc.y + 2) == lastRc,
   lastRc and ("row at y=" .. lastRc.y) or "no rect for the last row")

local stale = f:rowAt(RX + 20, RY + 6)
ok("the scrolled-away first row no longer answers at its old position",
   stale == nil or stale.e.key ~= "int1",
   "got " .. tostring(stale and stale.e.key))

-- ---------------------------------------------------------------------------
-- 4. Scroll clamping.
-- ---------------------------------------------------------------------------

f.scroll.offset = 0
eq("cannot scroll above the top", f.scroll:scrollBy(-500), false)
eq("scroll stays at zero", f.scroll.offset, 0)

f.scroll.offset = f.scroll.max
eq("cannot scroll past the end", f.scroll:scrollBy(500), false)
eq("scroll stays at max", f.scroll.offset, f.scroll.max)

f.scroll.offset = 0
ok("a wheel notch moves the view", f.scroll:scrollBy(48), true)
eq("and lands where asked", f.scroll.offset, 48)

-- ---------------------------------------------------------------------------
-- 5. The wheel's two jobs.
-- ---------------------------------------------------------------------------

f.scroll.offset = 0
f:draw(EL)

local rc = rectFor(f, "int1")
ok("an int row exposes its number box", rc and rc.boxX ~= nil)

-- Over the box: adjusts the dial, leaves the scroll alone.
local before = f.scroll.offset
values.int1 = 100
eq("wheel over the number box is handled",
   f:wheel(rc.boxX + 2, rc.y + 2, -1), true)
eq("wheel over the number box raises the value", values.int1, 105)
eq("wheel over the number box does not scroll", f.scroll.offset, before)

-- Over the label, well left of every control: scrolls, touches no value.
values.int1 = 100
eq("wheel off the controls is handled", f:wheel(RX + 2, rc.y + 2, 1), true)
ok("wheel off the controls scrolls", f.scroll.offset > before, "scroll " .. f.scroll.offset)
eq("wheel off the controls changes no value", values.int1, 100)

-- ---------------------------------------------------------------------------
-- 6. Thumb drag.
-- ---------------------------------------------------------------------------

f.scroll.offset = 0
f:draw(EL)
local b = f.scroll.bar

eq("press off the bar is not a drag", f:barDown(RX + 10, RY + 10), false)
eq("press on the thumb is claimed", f:barDown(b.x + 2, b.thumbY + 2), true)
ok("drag to the bottom scrolls to the end",
   (f:barDrag(RY + RH) and f.scroll.offset == f.scroll.max),
   "scroll " .. tostring(f.scroll.offset) .. " max " .. tostring(f.scroll.max))
eq("release reports a drag, so no row click fires", f:barUp(), true)
eq("release again is not a drag", f:barUp(), false)

-- Clicking the bare track jumps and then keeps dragging.
f.scroll.offset = 0
f:draw(EL)
b = f.scroll.bar
eq("press on the bare track is claimed", f:barDown(b.x + 2, RY + RH - 4), true)
ok("track click jumps toward that end", f.scroll.offset > 0, "scroll " .. f.scroll.offset)
f:barUp()

-- ---------------------------------------------------------------------------
-- 7. Stencil is always balanced.
-- ---------------------------------------------------------------------------

eq("every stencil set is cleared", stencilSet, stencilClear)
ok("the form actually stencilled", stencilSet > 0, "sets " .. stencilSet)

-- ---------------------------------------------------------------------------

print(string.format("DFForm scrolling: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
