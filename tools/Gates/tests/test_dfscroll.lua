-- test_dfscroll.lua - the family's shared scroll primitive.
--
-- WHY THIS EXISTS: two drawn panes (the Janitor dial form, the vehicle parts
-- grid) grew their own scrolling days apart and had already diverged on thumb
-- size, wheel distance and whether clicking the bare track jumps. DFScroll is
-- the single implementation both now call, so this is the one place that
-- behaviour is pinned - and a change here is a change to every scrolling
-- surface in the suite, which is exactly why it needs a test of its own rather
-- than being covered incidentally through one caller.
--
-- WHAT IT PINS:
--   * measure() returns a GUTTER, not a boolean: 0 when the content fits, so a
--     short pane keeps its full width and grows no bar.
--   * content exactly equal to the pane height does NOT scroll. Off-by-one here
--     hangs a scrollbar on a window built to fit its own contents, which is a
--     real bug this repo has already shipped once.
--   * clamping at both ends, and re-clamping when the pane grows or the content
--     shrinks under a scrolled view.
--   * shows()/screenY() agree: anything shows() rejects is off-pane, so a
--     caller that only draws (and only records hit rects) when shows() is true
--     cannot leave a clickable ghost behind.
--   * thumb travel maps to offset both ways, and a drag preserves the grab
--     point rather than snapping the thumb to the cursor's centre.
--   * release() reports whether a drag was in progress - that is what lets a
--     caller suppress the click that would otherwise fire on mouse-up.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfscroll.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFScroll.lua"

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

isServer = function() return false end
local function col(r, g, b) return { r = r, g = g, b = b } end
DFKit = { col = { bg = col(0,0,0), accent = col(0,.7,1) } }

local stencilSet, stencilClear, rects = 0, 0, 0
local EL = {
    drawRect         = function() rects = rects + 1 end,
    setStencilRect   = function() stencilSet = stencilSet + 1 end,
    clearStencilRect = function() stencilClear = stencilClear + 1 end,
}

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

local RECT = { x = 100, y = 50, w = 300, h = 200 }

-- ---------------------------------------------------------------------------
-- 1. measure(): the gutter is earned, not assumed
-- ---------------------------------------------------------------------------

local sc = DFScroll.new()
eq("a fresh scroller is at the top", sc.offset, 0)

eq("content shorter than the pane reserves no gutter", sc:measure(200, 120), 0)
eq("...and has no range", sc.max, 0)

-- The regression that shipped once: a pane sized to exactly its content must
-- not scroll. DFSettingsWindow sizes its body to contentHeight().
eq("content EQUAL to the pane reserves no gutter", sc:measure(200, 200), 0)
eq("...and still has no range", sc.max, 0)

eq("overflowing content reserves the bar", sc:measure(200, 500), DFScroll.BAR_W)
eq("...with range = content - pane", sc.max, 300)

-- ---------------------------------------------------------------------------
-- 2. Clamping
-- ---------------------------------------------------------------------------

sc:measure(200, 500)
eq("cannot scroll above the top", sc:scrollBy(-50), false)
eq("offset stays 0", sc.offset, 0)

ok("scrolls down", sc:scrollBy(120))
eq("lands where asked", sc.offset, 120)

eq("cannot scroll past the end", sc:scrollBy(9999), true)  -- moves to the cap
eq("offset pinned at max", sc.offset, sc.max)
eq("and again is a no-op", sc:scrollBy(10), false)

-- Pane grows under a scrolled view: the offset must come back with it.
sc:measure(400, 500)
eq("growing the pane re-clamps the offset", sc.offset, 100)
eq("...to the new range", sc.max, 100)

-- Content shrinks to fit: range and offset both collapse.
sc:measure(400, 300)
eq("content that now fits clears the range", sc.max, 0)
eq("...and returns to the top", sc.offset, 0)

-- ---------------------------------------------------------------------------
-- 3. shows() / screenY() agree
-- ---------------------------------------------------------------------------

-- A virtual y is screen space at offset zero, so a caller's cursor starts at
-- rect.y and virtual y already carries it. TOP is the first item's position.
local TOP = RECT.y

sc = DFScroll.new()
sc:measure(RECT.h, 1000)
sc.offset = 300

-- Scrolled 300 down, the item laid out 300 below the top sits at the top edge.
eq("screenY maps virtual to screen", sc:screenY(TOP + 300), RECT.y)
ok("an item at the top edge shows", sc:shows(TOP + 300, 20, RECT))
ok("an item mid-pane shows", sc:shows(TOP + 400, 20, RECT))

-- Above and below the pane: rejected. A caller that trusts this cannot leave a
-- clickable row behind where nothing was drawn.
ok("an item fully above is hidden", not sc:shows(TOP + 250, 20, RECT))
ok("an item fully below is hidden", not sc:shows(TOP + 300 + RECT.h + 5, 20, RECT))
ok("an item straddling the top still shows", sc:shows(TOP + 290, 20, RECT))
ok("an item straddling the bottom still shows", sc:shows(TOP + 300 + RECT.h - 5, 20, RECT))

-- Everything shows() accepts really does land inside the pane's span.
local bad = 0
for vy = TOP + 200, TOP + 600, 7 do
    if sc:shows(vy, 20, RECT) then
        local y = sc:screenY(vy)
        if y + 20 < RECT.y or y > RECT.y + RECT.h then bad = bad + 1 end
    end
end
eq("shows() never accepts an off-pane item", bad, 0)

-- ---------------------------------------------------------------------------
-- 4. The bar, and dragging it
-- ---------------------------------------------------------------------------

sc = DFScroll.new()
sc:measure(RECT.h, 1000)
sc.offset = 0
sc:draw(EL, RECT)

local b = sc.bar
ok("a bar is drawn when it overflows", b ~= nil)
ok("thumb is shorter than the track", b and b.thumbH < b.h, b and (b.thumbH .. "/" .. b.h))
eq("bar sits on the right edge", b and (b.x + b.w), RECT.x + RECT.w)
eq("thumb starts at the top", b and b.thumbY, RECT.y)

-- A press off the bar is not the bar's business.
eq("press left of the bar is ignored", sc:press(RECT.x + 10, RECT.y + 10), false)
eq("...and starts no drag", sc:release(), false)

-- Grab the thumb 4px down from its top, drag to the bottom of the track.
eq("press on the thumb is claimed", sc:press(b.x + 2, b.thumbY + 4), true)
ok("dragging to the end reaches max", (sc:drag(RECT.y + RECT.h) and sc.offset == sc.max),
   "offset " .. tostring(sc.offset) .. " max " .. tostring(sc.max))
eq("release reports the drag", sc:release(), true)
eq("release again reports nothing", sc:release(), false)

-- The grab point is preserved: pressing the thumb and dragging by exactly zero
-- must not move the view.
sc.offset = 150
sc:draw(EL, RECT)
b = sc.bar
local before = sc.offset
sc:press(b.x + 2, b.thumbY + 6)
sc:drag(b.thumbY + 6)
eq("a zero-distance drag does not move the view", sc.offset, before)
sc:release()

-- Clicking the bare track jumps toward that end and keeps dragging.
sc.offset = 0
sc:draw(EL, RECT)
b = sc.bar
eq("press on the track is claimed", sc:press(b.x + 2, RECT.y + RECT.h - 4), true)
ok("track click jumps down", sc.offset > 0, "offset " .. sc.offset)
eq("and it is a drag, so the click is suppressed", sc:release(), true)

-- No bar, no press.
sc:measure(RECT.h, 50)
sc:draw(EL, RECT)
eq("a fitting pane draws no bar", sc.bar, nil)
eq("...and claims no press", sc:press(RECT.x + RECT.w - 2, RECT.y + 10), false)

-- ---------------------------------------------------------------------------
-- 5. Wheel and reset
-- ---------------------------------------------------------------------------

sc = DFScroll.new()
sc:measure(RECT.h, 1000)
eq("wheel down moves by WHEEL", (sc:wheel(1) and sc.offset), DFScroll.WHEEL)
eq("wheel up returns", (sc:wheel(-1) and sc.offset), 0)
eq("wheel up at the top is unhandled", sc:wheel(-1), false)

sc:wheel(1)
sc:reset()
eq("reset returns to the top", sc.offset, 0)

sc:measure(RECT.h, 50)
eq("wheel on a fitting pane is unhandled", sc:wheel(1), false)

-- ---------------------------------------------------------------------------
-- 6. clip/unclip are balanced
-- ---------------------------------------------------------------------------

stencilSet, stencilClear = 0, 0
sc:clip(EL, RECT)
sc:unclip(EL)
eq("clip is matched by unclip", stencilSet, stencilClear)
eq("and it really stencilled", stencilSet, 1)

-- ---------------------------------------------------------------------------

print(string.format("DFScroll: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
