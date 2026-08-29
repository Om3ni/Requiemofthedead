-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFForm - the family's schema-driven settings form (client only).
--
-- WHY THIS EXISTS. Two surfaces in the suite render "a list of dials with
-- labels": Reclamation's Janitor view and the deck's own preferences. They are
-- the same widget with different data, and the first version of the Janitor
-- view proved what happens otherwise - roughly two hundred lines of bespoke
-- drawing, hit-testing and value formatting that the settings window would
-- have had to grow a second, subtly different copy of. Spacing, header rules,
-- number entry and help text then drift apart per surface, and every fix has
-- to be made twice.
--
-- So: ONE renderer, driven by a schema. A caller supplies the schema and three
-- functions (read a value, write a value, is this editable) and gets the whole
-- control surface. Anything that improves here improves everywhere.
--
-- SCHEMA VOCABULARY (shared with RCTuning, which was already written this way):
--   { group = "Name" }                                  a section header
--   { key=, kind="bool"|"int"|"enum"|"choice"|"text", label=, ... }   a dial
--     bool                        -> ON/OFF pill
--     enum   numValues=, values={} -> pill, click cycles. Stores an INDEX.
--     choice values={}, labels={} -> pill, click cycles. Stores the STRING.
--     int    min=, max=, step=    -> [-] [ number ] [+]; the box is typeable
--                                    and the wheel steps it
--     text                        -> a box; click opens DFEntry to type in
--   optional on a text dial:
--     suggest = function(query)   registry-backed type-ahead in that popout.
--                                 Returns rows: a string, or { value, label }.
--   optional on any dial:
--     help  = "paragraph"   the ? popout body. No help, no ? glyph.
--     unit  = "tiles"       suffix on the number
--     zero  = "off"         what 0 MEANS, when it does not mean zero
--     live  = false         marks the dial as needing a restart
--     note  = "..."         appended to the help body
--   optional on a text dial:
--     empty = "(not set)"   what an empty value reads as, dimmed
--     rule  = "..."         one line in the popout saying what is valid
--     validate(s) -> ok,msg refuses a commit and says why
--     maxLen, placeholder   passed through to the popout
--
-- CHOICE EXISTS BECAUSE ENUM STORES AN INDEX. That is right for a sandbox dial
-- whose options are positional, and wrong for a field whose VALUE is the word -
-- Limes' `zeds` is stored, persisted and read as "none"/"remove", and a store
-- holding 2 where the consumer looks for "remove" is a silent no-op. So the two
-- coexist rather than one being reworked into the other: existing enum callers
-- (RCTuning) are untouched, and a field that owns its strings says so.
--
-- AND A CLOSED SET IS NOT A TEXT BOX. `zeds` was going to be text on the
-- grounds that its type is string, which would have let an admin type "Remove"
-- and get silence - LMZeds honours exactly two words. Text is for prose nobody
-- validates (a zone's title); choice is for a set somebody does.
--
-- NUMBERS ARE TYPED, NOT DRAGGED. The first version used slider tracks and
-- they were unusable for fine values - a 116px track spanning 0-1000 puts nine
-- tiles under every pixel, so no amount of care lands on a round number. A
-- stepper is exact by construction. The mouse wheel over the box covers the
-- long hauls, so precision costs nothing in speed.
--
-- WHY CLICK AND NOT DRAG, still. Each change is a command to a server and
-- RDRate caps a player at 20/second; a dragged control emits one per frame and
-- would spend the whole budget communicating a single number. Discrete
-- interactions are one packet each.
--
-- SPACING IS A TOKEN, NOT A GUESS. Group gaps, header rules and row heights
-- are constants here precisely so every surface breathes identically, and so
-- "the text is too close together" is one edit rather than a survey.
--
-- IT SCROLLS, via DFScroll. A schema is as long as it is, and the host rect is
-- whatever the window happens to leave - the two have no reason to agree, and on
-- the Janitor view they did not: the form drew until it ran out of room,
-- stopped, and printed "+N more - make the panel taller". That warning was
-- honest about the truncation and useless about it, because there was no taller
-- to make and no way to reach the dials underneath.
--
-- The scrolling itself is NOT implemented here. DFScroll owns the offset, the
-- bar, the thumb drag and the wheel distance, and every drawn scrolling surface
-- in the family uses it - so the form and the vehicle parts grid cannot drift
-- apart on thumb size or whether clicking the track jumps.
--
-- The wheel still belongs to the number box when the cursor is over one. That
-- is the older contract and the more specific one - coarse travel on a 0-1000
-- dial is why the stepper is usable at all - so scrolling only takes the wheel
-- everywhere it is not already spoken for.

if isServer() then return end

require "ISUI/ISPanel"
require "DFScroll"
require "DFEntry"

DFForm = DFForm or {}

local function font() return DFKit.font.small or UIFont.Small end
local function tw(s)  return getTextManager():MeasureStringX(font(), s or "") end

-- ---------------------------------------------------------------------------
-- METRICS ARE MEASURED, NOT CONSTANT.
--
-- Text size is a client preference (DFPrefs), so any geometry expressed as a
-- fixed pixel count is only correct at the one font it was tuned against. Set
-- the scale to Large and fixed rows clip their own text, fixed boxes overflow,
-- and fixed columns collide - which is exactly what happened the first time
-- this shipped.
--
-- So every number below derives from the CURRENT font's height, against a
-- baseline that is itself measured rather than assumed (UIFont.Small, whatever
-- that happens to be on this install). Vertical rhythm scales with the glyph;
-- horizontal control widths scale with it too, and anything holding text is
-- additionally measured against the actual string before it is drawn.
--
-- The ratios here are the design - a row is its glyph plus breathing room, a
-- group gap is most of a row - so changing the font changes the size of the
-- form without changing how it reads.
-- ---------------------------------------------------------------------------
-- TextManager is eagerly initialized and substitutes its default font for an
-- unavailable enum (LuaManager.java:6930-6933; TextManager.java:119-129), so
-- these are deterministic measurements. The numeric fallback only handles an
-- unusable returned height.
local baseFH
local function baseline()
    if not baseFH then
        baseFH = getTextManager():getFontHeight(UIFont.Small)
        if not baseFH or baseFH < 1 then baseFH = 12 end
    end
    return baseFH
end

local function metrics()
    local fh = getTextManager():getFontHeight(font())
    if not fh or fh < 1 then fh = baseline() end
    local s = fh / baseline()
    if s < 1 then s = 1 end
    return {
        fh         = fh,
        rowH       = fh + 12,                    -- one dial: glyph + breathing room
        groupGap   = math.floor(fh * 1.6),       -- blank space ABOVE a group header
        headH      = fh + 4,                     -- the header text itself
        ruleGap    = math.max(4, math.floor(fh * 0.4)),
        headBottom = math.floor(fh * 0.75),      -- rule -> first row
        gutter     = math.floor(10 * s),         -- left gutter, holds the overridden tick
        stepW      = fh + 8,                     -- the - and + buttons
        boxW       = math.floor(104 * s),        -- the number box
        pillW      = math.floor(56 * s),         -- minimum pill width
        helpW      = fh + 4,                     -- the ? glyph column
        helpLineH  = fh + 1,                     -- one line of INLINE help
        padY       = math.max(2, math.floor((fh + 12 - fh) / 2) - 3),
    }
end

-- Breathing room under the last row, so it clears the bottom edge instead of
-- sitting flush against it. Counted INSIDE contentHeight(), because that is
-- what callers size themselves against: DFSettingsWindow makes its body
-- exactly contentHeight() tall, and a pad living outside that number would put
-- the window 6px into scroll range and hang a scrollbar on a form that fits.
local BOT_PAD = 6

-- Shared, never mutated: helpLines returns this for the common "no help" case,
-- and it is read sixty times a second per row. Allocating a fresh table there
-- would be the form's largest per-frame cost by a wide margin.
local EMPTY = {}

-- ---------------------------------------------------------------------------
-- Hotspot. One invisible panel over the whole form catches every interaction;
-- rows are drawn chrome, not widgets, so there is nothing else to hit-test.
--
-- COORDINATE SPACE. The form's rects are all in the HOST PANEL's space, because
-- that is what DFForm:draw is handed. Everything arriving here is in the
-- hotspot's own space, so it is offset by the hotspot origin on the way in.
-- onMouseWheel used to skip that step and pass getMouseX/Y through raw, which
-- happened to work only while a form sat at x=0 - the Janitor view's does not,
-- so wheeling a number box there adjusted whichever dial was that many pixels
-- to the left, or none.
--
-- ISPanel DOES define onMouseUp/onMouseDown/onMouseMove (it drives
-- moveWithMouse), so chaining them is safe and keeps the default behaviour for
-- anything this does not claim. It has no onMouseWheel - that one must not
-- chain, which is the trap ISScrollingListBox already sprang on this codebase.
-- ---------------------------------------------------------------------------
local Hotspot = ISPanel:derive("DFFormHotspot")

function Hotspot:onMouseDown(x, y)
    -- Claim the press only when it lands on the scrollbar; capture so the drag
    -- survives the cursor leaving the form, exactly as ISScrollBar does.
    if self.form and self.form:barDown(self:getX() + x, self:getY() + y) then
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function Hotspot:onMouseMove(dx, dy)
    if self.form and self.form:barDrag(self:getY() + self:getMouseY()) then return end
    return ISPanel.onMouseMove(self, dx, dy)
end

function Hotspot:onMouseMoveOutside(dx, dy)
    if self.form and self.form:barDrag(self:getY() + self:getMouseY()) then return end
    return ISPanel.onMouseMoveOutside(self, dx, dy)
end

function Hotspot:onMouseUp(x, y)
    self:setCapture(false)
    if not self.form then return end
    -- Releasing a scrollbar drag is not a click on whatever row is now under
    -- the cursor - the rows moved while the thumb was moving.
    if self.form:barUp() then return end
    self.form:click(self:getX() + x, self:getY() + y)
end

function Hotspot:onMouseUpOutside(x, y)
    self:setCapture(false)
    if self.form then self.form:barUp() end
    return ISPanel.onMouseUpOutside(self, x, y)
end

function Hotspot:onMouseWheel(del)
    if self.form then
        return self.form:wheel(self:getX() + self:getMouseX(),
                               self:getY() + self:getMouseY(), del)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- opts:
--   schema   (required) array, see vocabulary above
--   get(key) (required) current value
--   set(key, value)     called on change; omit for a read-only form
--   moved(key)          true when the value differs from its underlying default
--   enabled()           false disables every control (and dims the form)
--   title               used as the ? window's heading prefix
function DFForm.new(opts)
    local f = {
        schema  = opts.schema or {},
        get     = opts.get or function() return nil end,
        set     = opts.set,
        moved   = opts.moved,
        enabled = opts.enabled or function() return true end,
        title   = opts.title or "Setting",
        -- INLINE HELP, opt-in. Default false, so every existing caller keeps
        -- the ? popout exactly as it was. See helpLines() for what it costs and
        -- why it is a per-form choice rather than a global.
        inlineHelp = opts.inlineHelp == true,
        helpClamp  = opts.helpClamp or 3,
        rects   = {},
        rect    = nil,
        height  = 0,
        scroll  = DFScroll.new(),
    }
    return setmetatable(f, { __index = DFForm })
end

-- ---------------------------------------------------------------------------
-- FILTERING A SCHEMA. Case-insensitive substring over the option's key and its
-- label, and a section header survives only when something under it did - an
-- empty heading reads as an option that went missing rather than one that did
-- not match.
--
-- It lives HERE, on the module that owns what a schema IS, rather than on
-- either surface that filters one. The server view had it first, for 144 flat
-- options with category metadata for 61 of them; the sandbox view needs the
-- same thing across nine mod pages, and a second copy is exactly what
-- check-helpers exists to refuse.
--
-- MATCHING DELIBERATELY EXCLUDES THE HELP TEXT. Every sandbox tooltip is a
-- sentence, so "zombie" would match half the registry through prose that
-- happens to mention zombies, and the admin would be reading a filtered list
-- that is not obviously filtered by anything. The key and the label are what
-- somebody is actually typing at.
--
-- Returns the schema UNCHANGED for an empty query - the same table, not a copy,
-- because the caller assigns it straight onto a form and an identical copy per
-- keystroke is allocation for nothing.
function DFForm.filterSchema(schema, query)
    query = tostring(query or ""):lower()
    if query == "" then return schema end

    local hit = {}
    for _, e in ipairs(schema or {}) do
        if e.group then
            hit[#hit + 1] = e
        else
            local hay = ((e.key or "") .. " " .. (e.label or "")):lower()
            -- Plain find: a query is typed text, and "(" or "%" in it would be
            -- a pattern error rather than a search that finds nothing.
            if hay:find(query, 1, true) then hit[#hit + 1] = e end
        end
    end

    local kept = {}
    for i = 1, #hit do
        local e = hit[i]
        if e.group then
            local nxt = hit[i + 1]
            if nxt and not nxt.group then kept[#kept + 1] = e end
        else
            kept[#kept + 1] = e
        end
    end
    return kept
end

-- How many DIALS a schema holds, headers excluded. The number a "12 of 40
-- shown" line is built from, and the reason it is here rather than counted at
-- each call site is that #schema is the wrong answer by however many section
-- headers the layout added.
function DFForm.countRows(schema)
    local n = 0
    for _, e in ipairs(schema or {}) do
        if e.key then n = n + 1 end
    end
    return n
end

function DFForm:attach(panel)
    local hs = Hotspot:new(0, 0, 10, 10)
    hs.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    hs.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
    hs.form = self
    hs:initialise()
    hs:instantiate()
    panel:addChild(hs)
    self.hotspot = hs
    return { hs }
end

function DFForm:layout(x, y, w, h)
    self.rect = { x = x, y = y, w = w, h = h }
    if self.hotspot then
        self.hotspot:setX(x); self.hotspot:setY(y)
        self.hotspot:setWidth(w); self.hotspot:setHeight(h)
    end
    -- Measured here as well as in draw: a panel that just got taller can leave
    -- the view scrolled past the end, and the wheel has to know its range
    -- before the first frame is drawn.
    --
    -- The `or` is for hot reload. reloadLuaFile re-runs this file into the same
    -- DFForm table, so live instances pick up the new methods while keeping the
    -- fields they were built with - and one built before scrolling existed has
    -- no self.scroll at all, which would fault rather than simply not scroll.
    self.scroll = self.scroll or DFScroll.new()
    -- Recorded here as well as in draw so the FIRST measure is right: with
    -- inline help on, row height depends on the wrap width, and a nil width
    -- would measure every row as if it had no help - leaving the form scrolled
    -- against a range it is about to grow out of before a frame is drawn.
    self._wrapW = w - metrics().gutter - DFKit.metrics.pad
    self.scroll:measure(h, self:contentHeight(self._wrapW))
end

-- ---------------------------------------------------------------------------
-- INLINE HELP
--
-- The ? popout is right for a form of a dozen dials an admin already knows. It
-- is wrong for one reflecting a mod's whole sandbox page, where the reader is
-- scanning forty options they have never seen and the question "what does this
-- one do" is the ONLY question. Forty hovers is not an answer.
--
-- So a form can ask for the help text under the row instead. Off by default:
-- every existing caller keeps the popout, and nothing about their geometry
-- moves. Measured across the suite's own sandbox tooltips - median 207
-- characters, 72% under 300, p90 461 - a three-line clamp shows about 87% of
-- them whole, which is why helpClamp defaults to 3 rather than to unlimited.
--
-- WRAPPING IS CACHED because draw() runs sixty times a second and wrapText
-- measures every word. The cache is keyed on the wrap width AND the font
-- height: text scale is a client preference (DFPrefs), so a font change must
-- re-wrap or the rows keep the old line count and the hit rects drift away
-- from what is drawn.
-- ---------------------------------------------------------------------------
function DFForm:helpLines(e, w)
    if not self.inlineHelp then return EMPTY end
    if type(e.help) ~= "string" or e.help == "" then return EMPTY end

    local m = metrics()
    local c = self._helpCache
    if not c or c.w ~= w or c.fh ~= m.fh then
        c = { w = w, fh = m.fh, byKey = {} }
        self._helpCache = c
    end
    local key = e.key or e.label or tostring(e)
    local hit = c.byKey[key]
    if hit then return hit end

    local lines = DFKit.wrapText(e.help, font(), w) or EMPTY
    if #lines > self.helpClamp then
        local cut = {}
        for i = 1, self.helpClamp do cut[i] = lines[i] end
        -- The ellipsis is the honest half: a clamped paragraph that ends
        -- mid-sentence with no mark reads as the whole text.
        cut[self.helpClamp] = cut[self.helpClamp] .. " ..."
        lines = cut
    end
    c.byKey[key] = lines
    return lines
end

-- What one dial occupies, help included. Everything that walks the schema uses
-- this - content height, the visibility test, the cursor advance and the hit
-- rect - because the moment two of them disagree the form draws one row and
-- hit-tests another.
function DFForm:rowSpan(e, w)
    local m = metrics()
    return m.rowH + #self:helpLines(e, w) * m.helpLineH
end

-- Total vertical space the form needs, bottom padding included. Give a form
-- this much height and it will not scroll; give it less and the difference is
-- exactly its scroll range.
--
-- `w` is the TEXT column width, needed only when inline help is on - wrapping
-- depends on it, so the height does too. draw() records the width it used, so
-- a caller asking without one gets the answer for the last frame drawn, which
-- is what DFSettingsWindow's size-to-content needs.
function DFForm:contentHeight(w)
    local m = metrics()
    w = w or self._wrapW
    local total = 6
    for i = 1, #self.schema do
        local e = self.schema[i]
        if e.group then total = total + m.groupGap + m.headH + m.ruleGap + m.headBottom
        else total = total + self:rowSpan(e, w) end
    end
    return total + BOT_PAD
end

-- ---------------------------------------------------------------------------
-- Value formatting
-- ---------------------------------------------------------------------------
-- Where a choice's current value sits in its own list, or nil when the stored
-- string is not one of them. Nil is a real answer and not an error: a store
-- written by an older build, or by hand, can hold anything, and the row has to
-- be able to show it rather than silently present it as the first option.
local function choiceIndex(e, v)
    local vals = e.values or {}
    for i = 1, #vals do
        if vals[i] == v then return i end
    end
    return nil
end

function DFForm:display(e)
    local v = self.get(e.key)
    if e.kind == "bool" then return (v == true) and "ON" or "OFF" end
    if e.kind == "enum" then
        local names = e.values or {}
        return names[tonumber(v) or 1] or tostring(v)
    end
    if e.kind == "choice" then
        local s = (v == nil) and "" or tostring(v)
        local i = choiceIndex(e, s)
        if i then
            local labels = e.labels or {}
            return labels[i] or (s ~= "" and s or "-")
        end
        -- Off-list. Show it verbatim and mark it, because the alternative is a
        -- pill that reads as a normal setting while nothing honours the value.
        return s == "" and "-" or (s .. " (?)")
    end
    if e.kind == "text" then
        local s = (v == nil) and "" or tostring(v)
        if s == "" then return e.empty or "(not set)" end
        return s
    end
    local n = tonumber(v) or 0
    -- "0 days" and "off" are different statements, and only one of them is
    -- true. Rendering the number would be a lie the admin discovers by
    -- experiment, so a dial that declares a zero meaning gets to say it.
    if n == 0 and e.zero then return e.zero end
    if e.unit then return string.format("%d %s", n, e.unit) end
    return tostring(n)
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------
-- Truncate to fit. The label is the ONE piece of text on a row whose length
-- this file does not control - a schema can carry any string, and at a larger
-- font a label that fitted before now runs under the controls. Clipping is
-- what keeps the row a row; the full text is always one "?" away.
local function clip(s, maxW)
    s = tostring(s or "")
    if maxW <= 0 then return "" end
    if tw(s) <= maxW then return s end
    while #s > 1 and tw(s .. "\226\128\166") > maxW do
        s = string.sub(s, 1, #s - 1)
    end
    return s .. "\226\128\166"
end

function DFForm:draw(el)
    local r = self.rect
    if not r then return end
    local c  = DFKit.col
    local fo = font()
    local on = self.enabled()
    local m  = metrics()

    -- Vertical centring, computed once: text sits on the row's midline and the
    -- control boxes are the glyph plus a fixed margin, so both stay centred at
    -- any font instead of drifting off a hard-coded offset.
    local ctlH = m.fh + 6
    local textDY = math.floor((m.rowH - m.fh) / 2)
    local ctlDY  = math.floor((m.rowH - ctlH) / 2)

    -- Scroll geometry, remeasured every frame: the schema is fixed but the
    -- rect is not, and neither is the font. The gutter is 0 when the schema
    -- fits, so a short form still uses the full rect.
    --
    -- The width has to be known BEFORE contentHeight when inline help is on,
    -- because wrapping decides how tall every row is. The gutter is measured
    -- from the height, and the height depends on the width, which depends on
    -- the gutter - so the loop is broken by measuring once against the
    -- no-gutter width and letting the bar claim its column afterwards. Worst
    -- case a form within one bar-width of fitting gets a bar it did not
    -- strictly need; the alternative is iterating to a fixed point every frame.
    self._wrapW = r.w - m.gutter - DFKit.metrics.pad
    local content = self:contentHeight(self._wrapW)
    self.scroll = self.scroll or DFScroll.new()   -- see layout(): hot reload
    local sc = self.scroll
    local gutter = sc:measure(r.h, content)

    self.rects = {}
    local x = r.x + m.gutter
    local w = r.w - m.gutter - DFKit.metrics.pad - gutter
    local y = r.y + 6                 -- VIRTUAL cursor; sc:screenY maps it down

    sc:clip(el, r)

    for i = 1, #self.schema do
        local e = self.schema[i]

        if e.group then
            y = y + m.groupGap
            -- Visibility gates the DRAWING only; y advances identically either
            -- way, or the scroll range would stop matching contentHeight().
            if sc:shows(y, m.headH + m.ruleGap, r) then
                local hy = sc:screenY(y)
                local label = string.upper(e.group)
                el:drawText(label, x, hy, c.textDim.r, c.textDim.g, c.textDim.b, 0.95, fo)
                -- The rule runs the FULL width beneath the header rather than
                -- trailing off after the text. A section divider that stops
                -- where the word stops reads as decoration; one that spans the
                -- column reads as a boundary, which is what it is.
                el:drawRect(x, hy + m.headH + m.ruleGap - 3, w, 1, 0.45,
                    c.line.r, c.line.g, c.line.b)
            end
            y = y + m.headH + m.ruleGap + m.headBottom

        elseif sc:shows(y, self:rowSpan(e, self._wrapW), r) then
            local live   = e.live ~= false
            local rowY   = sc:screenY(y)   -- SCREEN space from here down, so the
                                           -- hit rects below are what was drawn
            local helpLn = self:helpLines(e, self._wrapW)
            -- The ? is redundant once the text is on the page, and keeping both
            -- would put a glyph on every row that opens a window saying what is
            -- already six pixels below it.
            local hasHelp = #helpLn == 0
                        and type(e.help) == "string" and e.help ~= ""

            -- Overridden marker, in the gutter.
            if self.moved and self.moved(e.key) then
                el:drawRect(r.x + 2, rowY + ctlDY, 2, ctlH, 0.9,
                    c.accent.r, c.accent.g, c.accent.b)
            end

            local right = x + w
            local rect = { e = e, y = rowY, h = m.rowH }

            -- ? column, hard right.
            if hasHelp then
                local hx = right - m.helpW
                el:drawText("?", hx + 4, rowY + textDY,
                    c.accent.r, c.accent.g, c.accent.b, 0.9, fo)
                rect.helpX, rect.helpW = hx, m.helpW
                right = hx - 6
            end

            if e.kind == "int" then
                local txt = self:display(e)
                -- The box grows to its contents rather than cropping them:
                -- "250 real days" is longer than "3", and a fixed box would
                -- clip the very value the control exists to show.
                local boxW = math.max(m.boxW, tw(txt) + 16)
                local bx   = right - m.stepW
                local boxX = bx - boxW - 4
                local mx   = boxX - m.stepW - 4

                local function stepBtn(sx, glyph)
                    el:drawRect(sx, rowY + ctlDY, m.stepW, ctlH, 0.7,
                        c.panel.r, c.panel.g, c.panel.b)
                    el:drawRectBorder(sx, rowY + ctlDY, m.stepW, ctlH, 0.5,
                        c.line.r, c.line.g, c.line.b)
                    el:drawText(glyph, sx + math.floor((m.stepW - tw(glyph)) / 2),
                        rowY + textDY,
                        on and c.text.r or c.textDim.r,
                        on and c.text.g or c.textDim.g,
                        on and c.text.b or c.textDim.b, 1, fo)
                end
                stepBtn(mx, "-")
                stepBtn(bx, "+")

                el:drawRect(boxX, rowY + ctlDY, boxW, ctlH, 0.6, c.bg.r, c.bg.g, c.bg.b)
                el:drawRectBorder(boxX, rowY + ctlDY, boxW, ctlH, 0.5,
                    c.line.r, c.line.g, c.line.b)
                el:drawText(txt, boxX + math.floor((boxW - tw(txt)) / 2), rowY + textDY,
                    c.text.r, c.text.g, c.text.b, 1, fo)

                rect.minusX, rect.plusX, rect.boxX = mx, bx, boxX
                rect.stepW, rect.boxW = m.stepW, boxW
                right = mx - 8

            elseif e.kind == "text" then
                local raw     = self.get(e.key)
                local isEmpty = (raw == nil or tostring(raw) == "")
                local txt     = self:display(e)

                -- A FIXED SHARE OF THE ROW, not grown to its contents. The int
                -- box grows because "250 real days" is still a value you must
                -- read in full; a text field holds a sentence, and a box that
                -- grew to fit one would push the label out of existence and
                -- then overflow anyway. Clipped here, complete in the popout.
                local boxW = math.max(m.pillW,
                    math.min(math.floor((right - x) * 0.55), m.boxW * 2))
                local boxX = right - boxW

                el:drawRect(boxX, rowY + ctlDY, boxW, ctlH, 0.6, c.bg.r, c.bg.g, c.bg.b)
                el:drawRectBorder(boxX, rowY + ctlDY, boxW, ctlH, 0.5,
                    c.line.r, c.line.g, c.line.b)
                -- Left-aligned, unlike every other control here: this is prose,
                -- and prose centred in a box reads as a caption rather than as
                -- a field you can type in.
                local tcol = isEmpty and c.textDim or c.text
                el:drawText(clip(txt, boxW - 10), boxX + 5, rowY + textDY,
                    tcol.r, tcol.g, tcol.b, 1, fo)

                rect.textX, rect.textW = boxX, boxW
                right = boxX - 8

            else
                local txt = self:display(e)
                local pw  = math.max(m.pillW, tw(txt) + 18)
                local px  = right - pw
                local isOn
                if e.kind == "bool" then isOn = (self.get(e.key) == true) end

                -- Three-state fill, built with an if rather than an and/or
                -- chain: `bool and false or nil` collapses to nil and would
                -- render every OFF switch in the enum's neutral colour, losing
                -- the off state entirely.
                local fill
                if isOn == true then fill = c.accentDim
                elseif isOn == false then fill = c.bg
                else fill = c.panel end

                el:drawRect(px, rowY + ctlDY, pw, ctlH, 0.85, fill.r, fill.g, fill.b)
                local edge = (isOn == true) and c.accent or c.line
                el:drawRectBorder(px, rowY + ctlDY, pw, ctlH, 0.6, edge.r, edge.g, edge.b)
                el:drawText(txt, px + math.floor((pw - tw(txt)) / 2), rowY + textDY,
                    c.text.r, c.text.g, c.text.b, 1, fo)

                rect.pillX, rect.pillW = px, pw
                right = px - 8

                -- A control that silently does nothing until reboot is worse
                -- than no control, so this marker is not optional chrome.
                if not live then
                    local mk = "restart"
                    el:drawText(mk, px - tw(mk) - 10, rowY + textDY,
                        c.warn.r, c.warn.g, c.warn.b, 0.9, fo)
                    right = px - tw(mk) - 18
                end
            end

            -- Label LAST, clipped to whatever the controls left. Drawing it
            -- first (as this did) meant a long label at a large font ran
            -- straight under the number box with nothing to stop it.
            local labCol = (live and on) and c.text or c.textDim
            el:drawText(clip(e.label or e.key, right - x), x, rowY + textDY,
                labCol.r, labCol.g, labCol.b, 1, fo)

            -- Inline help, under the dial. The hit rect above stays ROW-tall on
            -- purpose: clicking a description must not toggle the setting it
            -- describes, which is what a full-span rect would do.
            local hy = rowY + m.rowH - 2
            for li = 1, #helpLn do
                el:drawText(helpLn[li], x + 2, hy,
                    c.textDim.r * 0.92, c.textDim.g * 0.92, c.textDim.b * 0.92, 1, fo)
                hy = hy + m.helpLineH
            end

            self.rects[#self.rects + 1] = rect
            y = y + self:rowSpan(e, self._wrapW)

        else
            -- Scrolled out of sight: no drawing and no hit rect - a row that
            -- cannot be seen must not be clickable - but the cursor still has
            -- to step over it or everything below would shift up.
            y = y + self:rowSpan(e, self._wrapW)
        end
    end

    sc:unclip(el)

    -- The bar, outside the stencil and last, so it sits above the rows rather
    -- than being clipped by the same rect they are. Its presence is also the
    -- honest signal that there is more here than fits: this replaced a
    -- "+N more - make the panel taller" line, which named the problem
    -- accurately and left the admin no way to act on it.
    sc:draw(el, r, c)

    self.height = content
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------
local function clamp(e, n)
    local lo, hi = e.min or 0, e.max or 100
    if n < lo then n = lo elseif n > hi then n = hi end
    return n
end

function DFForm:rowAt(ax, ay)
    for i = 1, #self.rects do
        local rc = self.rects[i]
        if ay >= rc.y and ay < rc.y + rc.h then return rc end
    end
    return nil
end

function DFForm:click(ax, ay)
    local rc = self:rowAt(ax, ay)
    if not rc then return end
    local e = rc.e

    -- Help is readable even when the form is disabled: a non-admin looking at
    -- a locked panel still deserves to know what the settings mean.
    if rc.helpX and ax >= rc.helpX and ax < rc.helpX + rc.helpW then
        local body = e.help or ""
        if e.note and e.note ~= "" then body = body .. "\n\n" .. e.note end
        if e.live == false then
            body = body .. "\n\nThis setting only takes effect after a restart."
        end
        DFHelp.show(e.label or e.key, body, getMouseX(), getMouseY())
        return
    end

    if not self.enabled() or not self.set then return end

    if e.kind == "bool" then
        self.set(e.key, not (self.get(e.key) == true))

    elseif e.kind == "enum" then
        local n = (tonumber(self.get(e.key)) or 1) + 1
        if n > (e.numValues or 1) then n = 1 end
        self.set(e.key, n)

    elseif e.kind == "choice" then
        local vals = e.values or {}
        if #vals > 0 then
            local cur = self.get(e.key)
            cur = (cur == nil) and "" or tostring(cur)
            local i = choiceIndex(e, cur)
            -- An off-list value cycles to the FIRST option rather than being
            -- treated as position zero. The click is the admin correcting a
            -- value nothing honours, so it should land somewhere valid.
            self.set(e.key, i and vals[(i % #vals) + 1] or vals[1])
        end

    elseif e.kind == "text" then
        if rc.textX and ax >= rc.textX and ax < rc.textX + rc.textW then
            local cur = self.get(e.key)
            -- `set` is captured rather than called through self inside the
            -- callback: the popout outlives this click, and by the time it
            -- commits the host may have rebuilt the form around a new object.
            local setter = self.set
            DFEntry.show{
                title       = e.label or e.key,
                value       = (cur == nil) and "" or tostring(cur),
                rule        = e.rule,
                validate    = e.validate,
                maxLen      = e.maxLen,
                placeholder = e.placeholder,
                -- A row whose valid values are a registry declares how to
                -- search it and gets the type-ahead band; one that holds prose
                -- declares nothing and is unchanged. See DFEntry's header.
                suggest     = e.suggest,
                nearX       = getMouseX(),
                nearY       = getMouseY(),
                onCommit    = function(s) setter(e.key, s) end,
            }
        end

    elseif e.kind == "int" then
        local stepBy = e.step or 1
        local n = tonumber(self.get(e.key)) or (e.min or 0)
        if rc.minusX and ax >= rc.minusX and ax < rc.minusX + rc.stepW then
            self.set(e.key, clamp(e, n - stepBy))
        elseif rc.plusX and ax >= rc.plusX and ax < rc.plusX + rc.stepW then
            self.set(e.key, clamp(e, n + stepBy))
        elseif rc.boxX and ax >= rc.boxX and ax < rc.boxX + rc.boxW then
            -- THE BOX IS NOW TYPEABLE. It used to be a deliberate readout, on
            -- the reasoning that a value derived from where the pixel landed is
            -- exactly the imprecision the stepper replaced. That reasoning is
            -- about DRAGGING and still holds - typing is the opposite of it.
            -- The stepper is for nudging, and it is the only way in: a dial
            -- whose range runs to 36525 (the kit cooldown in days) is a
            -- thousand clicks from where an admin wants it, and the wheel only
            -- shortens that (owner, 2026-08-24).
            --
            -- Reuses the text kind's popout rather than growing a second entry
            -- path, so validation, the rule line and the singleton rule are the
            -- ones DFEntry already owns. The schema declares nothing new; every
            -- int row in the suite gains this at once.
            local lo, hi  = e.min or 0, e.max or 100
            local loS     = string.format("%d", lo)
            local hiS     = string.format("%d", hi)
            -- `set` is captured, not reached through self: the popout outlives
            -- this click and the host may rebuild the form before it commits.
            local setter  = self.set
            DFEntry.show{
                title = e.label or e.key,
                value = string.format("%d", n),
                rule  = "Whole number, " .. loS .. " to " .. hiS .. ".",
                validate = function(str)
                    local v = tonumber(str)
                    if not v or v ~= math.floor(v) then
                        return false, "Whole numbers only."
                    end
                    if v < lo or v > hi then
                        return false, loS .. " to " .. hiS .. "."
                    end
                    return true
                end,
                -- Room for the longest bound plus a sign. Not a validation
                -- rule - validate() owns that - just a stop on typing digits
                -- that could never be in range.
                maxLen   = math.max(#loS, #hiS) + 1,
                nearX    = getMouseX(),
                nearY    = getMouseY(),
                -- clamp() runs again even though validate() passed: the two
                -- are reached by different routes and only this one is on the
                -- path that writes.
                onCommit = function(str)
                    setter(e.key, clamp(e, tonumber(str) or lo))
                end,
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Scrolling - delegated wholesale to DFScroll. These thin wrappers exist only
-- so the Hotspot has something to call without knowing the form keeps its
-- scroller in a field.
-- ---------------------------------------------------------------------------
function DFForm:barDown(ax, ay) return self.scroll and self.scroll:press(ax, ay) or false end
function DFForm:barDrag(ay)     return self.scroll and self.scroll:drag(ay) or false end
function DFForm:barUp()         return self.scroll and self.scroll:release() or false end

-- The wheel has two jobs and the specific one wins. Over a number box it is
-- the dial's own coarse-travel control - what keeps a 0-1000 setting usable
-- without reintroducing a drag, every stop still exactly on a step boundary.
-- Anywhere else in the form it scrolls.
function DFForm:wheel(ax, ay, del)
    local rc = self:rowAt(ax, ay)
    if rc and rc.e.kind == "int" and rc.boxX
        and ax >= rc.boxX and ax < rc.boxX + rc.boxW
        and self.enabled() and self.set then
        local e = rc.e
        local n = tonumber(self.get(e.key)) or (e.min or 0)
        -- del is +1 down / -1 up in PZ; wheeling UP should raise the number.
        self.set(e.key, clamp(e, n - (del > 0 and 1 or -1) * (e.step or 1)))
        return true
    end

    -- Distance comes from DFScroll, so a notch travels the same here as in the
    -- vehicle parts grid.
    return self.scroll and self.scroll:wheel(del) or false
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
