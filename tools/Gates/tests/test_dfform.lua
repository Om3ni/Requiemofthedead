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

-- wrapText, deterministic: one line per 10 characters. The real one measures
-- glyphs; what these tests need is a known line COUNT, because every row height
-- downstream is derived from it.
DFKit.wrapText = function(text, _, maxW)
    local out = {}
    text = tostring(text or "")
    if text == "" or not maxW or maxW <= 0 then return out end
    local i = 1
    while i <= #text do
        out[#out + 1] = text:sub(i, i + 9)
        i = i + 10
    end
    return out
end

-- DFEntry is the typing popout a `text` row opens. Stubbed to RECORD rather
-- than to no-op, because what these tests are really asking is whether the row
-- hands it the right value and wires its commit back to set().
local entryShown = nil
DFEntry = {
    show = function(opts) entryShown = opts end,
    close = function() end,
}

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
-- 8. choice and text - the two string kinds.
--
-- These exist because Limes' `zeds` is a string field whose value IS the word
-- the consumer branches on. `enum` stores an index and would have written 2
-- where LMZeds looks for "remove", which stores, replicates and displays
-- perfectly while removing nothing - the kind of failure that looks like
-- working software. So: what the pill SHOWS is the label, what the store gets
-- is the string, and an off-list value is visibly off-list rather than being
-- quietly presented as the first option.
-- ---------------------------------------------------------------------------

local strVals = {}
local strSchema = {
    { key = "zeds", kind = "choice", label = "Zombie handling",
      values = { "", "none", "remove" },
      labels = { "Leave alone", "No spawns", "No spawns + sweep" } },
    { key = "title", kind = "text", label = "Announce title",
      empty = "(the zone's name)", rule = "Empty uses the zone name.", maxLen = 64 },
    { key = "bare", kind = "choice", label = "No options", values = {} },
    -- A registry-backed row. The provider is never called here - what is at
    -- risk is only whether the row hands it over, because a row that declares
    -- one and gets a plain box back is a silent loss of the whole feature.
    { key = "item", kind = "text", label = "Item type",
      suggest = function(q) return { "Base." .. tostring(q) } end },
}
local sf = DFForm.new{
    schema  = strSchema,
    title   = "Strings",
    get     = function(k) return strVals[k] end,
    set     = function(k, v) strVals[k] = v end,
    enabled = function() return true end,
}
sf:layout(RX, RY, RW, 400)
sf:draw(EL)

-- Display: the label, never the stored string.
strVals.zeds = ""
eq("blank choice reads as its label", sf:display(strSchema[1]), "Leave alone")
strVals.zeds = "remove"
eq("set choice reads as its label", sf:display(strSchema[1]), "No spawns + sweep")
strVals.zeds = "Remove"
eq("off-list value is shown and marked", sf:display(strSchema[1]), "Remove (?)")
-- nil is not the same as off-list: an unset field has simply never been touched.
strVals.zeds = nil
eq("unset choice reads as the blank label", sf:display(strSchema[1]), "Leave alone")

-- Clicking cycles the STRING, and wraps.
local zrow = rectFor(sf, "zeds")
ok("choice row is hit-testable", zrow ~= nil)
strVals.zeds = ""
sf:click(zrow.pillX + 2, zrow.y + 2)
eq("cycle stores the next string", strVals.zeds, "none")
sf:click(zrow.pillX + 2, zrow.y + 2)
eq("cycle again", strVals.zeds, "remove")
sf:click(zrow.pillX + 2, zrow.y + 2)
eq("cycle wraps back to blank", strVals.zeds, "")
-- An off-list value lands somewhere valid rather than being treated as index 0.
strVals.zeds = "Remove"
sf:click(zrow.pillX + 2, zrow.y + 2)
eq("off-list cycles to the first option", strVals.zeds, "")

-- A choice with no options must not fault, and must not invent a value.
local brow = rectFor(sf, "bare")
strVals.bare = "keep"
sf:click(brow.pillX + 2, brow.y + 2)
eq("empty choice leaves the value alone", strVals.bare, "keep")

-- Text: what an empty field reads as, and that the popout gets the real value.
strVals.title = ""
eq("empty text shows its empty label", sf:display(strSchema[2]), "(the zone's name)")
strVals.title = "The City"
eq("set text shows the value", sf:display(strSchema[2]), "The City")

local trow = rectFor(sf, "title")
ok("text row is hit-testable", trow ~= nil)
ok("text row has a box, not a pill", trow.textX ~= nil and trow.pillX == nil)

entryShown = nil
sf:click(trow.textX - 20, trow.y + 2)
eq("clicking beside the box opens nothing", entryShown, nil)

sf:click(trow.textX + 2, trow.y + 2)
ok("clicking the box opens the popout", entryShown ~= nil)
eq("popout is seeded with the current value", entryShown.value, "The City")
eq("popout carries the rule", entryShown.rule, "Empty uses the zone name.")
eq("popout carries the cap", entryShown.maxLen, 64)
eq("popout is titled with the label", entryShown.title, "Announce title")
eq("A ROW THAT DECLARES NO PROVIDER MUST NOT GET A BAND - every text field in "
   .. "the suite predates this option and holds prose", entryShown.suggest, nil)


-- The commit writes through. This is the half that would silently do nothing if
-- the callback closed over the wrong thing.
entryShown.onCommit("Muldraugh")
eq("commit writes the typed value", strVals.title, "Muldraugh")
-- ...and one that does declare a provider hands it over. This single line is
-- the whole seam between a schema and the type-ahead; without it the row still
-- opens a popout, still accepts typing, and simply never searches.
local irow = rectFor(sf, "item")
entryShown = nil
sf:click(irow.textX + 2, irow.y + 2)
ok("the item row opens the popout", entryShown ~= nil)
ok("THE PROVIDER REACHES THE POPOUT", type(entryShown.suggest) == "function")
eq("and it is the row's own", entryShown.suggest("Axe")[1], "Base.Axe")

-- A read-only form (no set) must not offer to edit at all: the popout would
-- take a value it has nowhere to put.
local ro = DFForm.new{
    schema = strSchema, title = "RO",
    get = function(k) return strVals[k] end,
    enabled = function() return true end,
}
ro:layout(RX, RY, RW, 400)
ro:draw(EL)
entryShown = nil
local rrow = rectFor(ro, "title")
ro:click(rrow.textX + 2, rrow.y + 2)
eq("a form with no set() opens no popout", entryShown, nil)

-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- INLINE HELP (added 2026-08-23 with the opt-in `inlineHelp` mode)
--
-- WHY IT NEEDS PINNING AT ALL: three separate places have to agree on how tall
-- a row is - contentHeight (the scroll range), the visibility test, and the
-- cursor advance that positions the NEXT row. The moment two of them disagree
-- the form draws one row and hit-tests another, which reads as "clicking a
-- setting toggles a different setting" and is miserable to trace.
--
-- Found by mutation: deleting the clamp and making the cursor ignore help
-- height both left every existing assertion green.
-- ---------------------------------------------------------------------------

local LONG = string.rep("x", 95)     -- 10 wrapped lines at the stub's 10/line

local function helpSchema()
    return {
        { key = "a", kind = "bool", label = "A", help = LONG },
        { key = "b", kind = "bool", label = "B", help = LONG },
    }
end

-- Off by default: every existing caller keeps the ? popout and its geometry.
local plain = DFForm.new{ schema = helpSchema(), get = function() return false end,
                          set = function() end }
eq("inlineHelp defaults off", plain.inlineHelp, false)
eq("help is not wrapped when the mode is off", #plain:helpLines(plain.schema[1], 300), 0)

local inl = DFForm.new{ schema = helpSchema(), inlineHelp = true,
                        get = function() return false end, set = function() end }

-- The clamp. Unclamped, one 460-character tooltip is taller than the pane.
eq("help is clamped to helpClamp lines", #inl:helpLines(inl.schema[1], 300), 3)
ok("the clamped line says it was cut",
   tostring(inl:helpLines(inl.schema[1], 300)[3]):sub(-4) == " ...",
   "a paragraph cut mid-sentence with no mark reads as the whole text")

local custom = DFForm.new{ schema = helpSchema(), inlineHelp = true, helpClamp = 5,
                           get = function() return false end, set = function() end }
eq("helpClamp is honoured", #custom:helpLines(custom.schema[1], 300), 5)

-- An entry with no help costs no height, or every undocumented dial grows a gap.
local none = DFForm.new{ schema = { { key = "n", kind = "bool", label = "N" } },
                         inlineHelp = true, get = function() return false end,
                         set = function() end }
eq("a dial with no help gets no help lines", #none:helpLines(none.schema[1], 300), 0)
ok("a dial with no help is exactly one row tall",
   none:rowSpan(none.schema[1], 300) < inl:rowSpan(inl.schema[1], 300))

-- rowSpan is the single source the other three read.
local span = inl:rowSpan(inl.schema[1], 300)
ok("rowSpan grows with the help block", span > plain:rowSpan(plain.schema[1], 300),
   "got " .. tostring(span))

-- contentHeight must use rowSpan, not a flat row - otherwise the scroll range
-- stops short and the last rows are unreachable, which is the original bug this
-- whole file exists for.
ok("contentHeight accounts for inline help",
   inl:contentHeight(300) > plain:contentHeight(300),
   "inline " .. tostring(inl:contentHeight(300)) .. " vs plain "
   .. tostring(plain:contentHeight(300)))

-- The cursor advance. Two rows, each with help: the second row must be drawn a
-- full rowSpan below the first, not one bare row.
inl:layout(RX, RY, RW, 800)
inl:draw(EL)
local ra, rb = rectFor(inl, "a"), rectFor(inl, "b")
ok("both help rows got hit rects", ra ~= nil and rb ~= nil)
if ra and rb then
    eq("the second row is a full rowSpan below the first",
       rb.y - ra.y, inl:rowSpan(inl.schema[1], inl._wrapW))
    ok("a hit rect covers the DIAL only, not its description",
       rb.y - ra.y > ra.h,
       "clicking a description would otherwise toggle the setting it describes")
end

-- The ? glyph is suppressed when the text is already on the page.
ok("no ? column while help is inline", ra and ra.helpX == nil)

-- The wrap cache is keyed on width AND font height. A width change must
-- re-wrap, or rows keep a stale line count and the rects drift off what is
-- drawn.
local before = #inl:helpLines(inl.schema[1], 300)
local narrow = #inl:helpLines(inl.schema[1], 40)
ok("a width change re-wraps rather than serving the cache",
   inl._helpCache.w == 40, "cache still keyed to " .. tostring(inl._helpCache.w))
eq("re-wrapping still clamps", narrow, before)

-- ---------------------------------------------------------------------------
-- FILTERING
--
-- Moved here from test_dfserverview on 2026-08-23, when the sandbox view grew
-- the same search and the rule stopped belonging to either surface. Both option
-- screens now show a filtered list, so a defect here is an admin concluding an
-- option does not exist because their search quietly dropped it.
-- ---------------------------------------------------------------------------

local SCHEMA = {
    { group = "PVP" },
    { key = "PVP",            label = "PVP" },
    { key = "PVPLogToolChat", label = "PVPLogToolChat" },
    { group = "Other" },
    { key = "Zzz",            label = "Zzz" },
}

ok("an empty query returns the schema itself, not a copy",
   DFForm.filterSchema(SCHEMA, "") == SCHEMA,
   "a copy per keystroke is allocation for nothing")
ok("a nil query is the same as an empty one",
   DFForm.filterSchema(SCHEMA, nil) == SCHEMA)

local hits = DFForm.filterSchema(SCHEMA, "pvplog")
eq("one row matched", DFForm.countRows(hits), 1)
eq("its header came with it", #hits, 2)
ok("A SECTION HEADER WITH NOTHING UNDER IT SURVIVED",
   not (hits[#hits] and hits[#hits].group),
   "an empty heading reads as an option that went missing, not one that did "
   .. "not match")

eq("the query is case-insensitive",
   #DFForm.filterSchema(SCHEMA, "PVPLOG"), #hits)
eq("matching nothing leaves no headers behind",
   #DFForm.filterSchema(SCHEMA, "zzzz"), 0)

-- The LABEL matches too, not just the key. On the sandbox pages the two differ
-- - the key is the raw option name and the label is what is drawn - so keying
-- on one alone means half the searches fail against the text on screen.
eq("the label is searched as well as the key",
   DFForm.countRows(DFForm.filterSchema(
       { { key = "SomeOpaqueName", label = "Zombie respawn" } }, "respawn")), 1)

-- A typed query is text, not a pattern. Without a plain find, a stray "(" is a
-- Lua error thrown from a keystroke rather than a search that finds nothing.
local okPat, errPat = pcall(DFForm.filterSchema, SCHEMA, "pvp(")
ok("a pattern character in the query does not throw", okPat, tostring(errPat))
eq("and it matches nothing rather than everything",
   okPat and #DFForm.filterSchema(SCHEMA, "pvp(") or -1, 0)

eq("countRows ignores section headers", DFForm.countRows(SCHEMA), 3)
eq("countRows survives nothing at all", DFForm.countRows(nil), 0)

print(string.format("DFForm scrolling: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
