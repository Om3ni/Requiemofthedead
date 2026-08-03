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
--   { key=, kind="bool"|"int"|"enum", label=, ... }      a dial
--     bool                       -> ON/OFF pill
--     enum  numValues=, values={} -> pill, click cycles
--     int   min=, max=, step=     -> [-] [ number ] [+], plus mouse wheel
--   optional on any dial:
--     help  = "paragraph"   the ? popout body. No help, no ? glyph.
--     unit  = "tiles"       suffix on the number
--     zero  = "off"         what 0 MEANS, when it does not mean zero
--     live  = false         marks the dial as needing a restart
--     note  = "..."         appended to the help body
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

if isServer() then return end

require "ISUI/ISPanel"

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
local baseFH
local function baseline()
    if not baseFH then
        baseFH = 12
        pcall(function() baseFH = getTextManager():getFontHeight(UIFont.Small) end)
        if not baseFH or baseFH < 1 then baseFH = 12 end
    end
    return baseFH
end

local function metrics()
    local fh = baseline()
    pcall(function() fh = getTextManager():getFontHeight(font()) end)
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
        padY       = math.max(2, math.floor((fh + 12 - fh) / 2) - 3),
    }
end

-- ---------------------------------------------------------------------------
-- Hotspot. One invisible panel over the whole form catches every interaction;
-- rows are drawn chrome, not widgets, so there is nothing else to hit-test.
--
-- Does NOT chain to the base class. ISPanel has no onMouseUp or onMouseWheel
-- of its own, so calling one would nil-call - the trap ISScrollingListBox
-- already sprang on this codebase once.
-- ---------------------------------------------------------------------------
local Hotspot = ISPanel:derive("DFFormHotspot")

function Hotspot:onMouseUp(x, y)
    if self.form then self.form:click(self:getX() + x, self:getY() + y) end
end

function Hotspot:onMouseWheel(del)
    if self.form then return self.form:wheel(self:getMouseX(), self:getMouseY(), del) end
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
        rects   = {},
        rect    = nil,
        height  = 0,
    }
    return setmetatable(f, { __index = DFForm })
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
end

-- Total vertical space the schema needs. Callers use it to decide whether to
-- warn about truncation or to size their own window.
function DFForm:contentHeight()
    local m = metrics()
    local total = 6
    for i = 1, #self.schema do
        local e = self.schema[i]
        if e.group then total = total + m.groupGap + m.headH + m.ruleGap + m.headBottom
        else total = total + m.rowH end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Value formatting
-- ---------------------------------------------------------------------------
function DFForm:display(e)
    local v = self.get(e.key)
    if e.kind == "bool" then return (v == true) and "ON" or "OFF" end
    if e.kind == "enum" then
        local names = e.values or {}
        return names[tonumber(v) or 1] or tostring(v)
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

    self.rects = {}
    local x = r.x + m.gutter
    local w = r.w - m.gutter - DFKit.metrics.pad
    local y = r.y + 6

    for i = 1, #self.schema do
        local e = self.schema[i]

        if e.group then
            y = y + m.groupGap
            local label = string.upper(e.group)
            el:drawText(label, x, y, c.textDim.r, c.textDim.g, c.textDim.b, 0.95, fo)
            y = y + m.headH
            -- The rule runs the FULL width beneath the header rather than
            -- trailing off after the text. A section divider that stops where
            -- the word stops reads as decoration; one that spans the column
            -- reads as a boundary, which is what it is.
            el:drawRect(x, y + m.ruleGap - 3, w, 1, 0.45, c.line.r, c.line.g, c.line.b)
            y = y + m.ruleGap + m.headBottom

        else
            local live   = e.live ~= false
            local rowY   = y
            local hasHelp = type(e.help) == "string" and e.help ~= ""

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

            self.rects[#self.rects + 1] = rect
            y = y + m.rowH
        end

        -- Ran out of room. Say so: a settings list that quietly stops short
        -- reads as "these are all the options", which is the one thing a
        -- tuning surface must never imply.
        if y > r.y + r.h - m.rowH and i < #self.schema then
            local hidden = 0
            for j = i + 1, #self.schema do
                if self.schema[j].key then hidden = hidden + 1 end
            end
            if hidden > 0 then
                el:drawText(string.format("+%d more - make the panel taller", hidden),
                    x, r.y + r.h - 15, c.warn.r, c.warn.g, c.warn.b, 0.9, fo)
            end
            break
        end
    end

    self.height = y - r.y
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

    elseif e.kind == "int" then
        local stepBy = e.step or 1
        local n = tonumber(self.get(e.key)) or (e.min or 0)
        if rc.minusX and ax >= rc.minusX and ax < rc.minusX + rc.stepW then
            self.set(e.key, clamp(e, n - stepBy))
        elseif rc.plusX and ax >= rc.plusX and ax < rc.plusX + rc.stepW then
            self.set(e.key, clamp(e, n + stepBy))
        end
        -- A click on the number box itself does nothing on purpose. It is a
        -- readout; making it jump to a value derived from where the pixel
        -- landed is exactly the imprecision the stepper replaced.
    end
end

-- Wheel over the number box. This is what keeps a 0-1000 dial usable without
-- reintroducing a drag: coarse travel costs a flick, and every stop is still
-- exactly on a step boundary.
function DFForm:wheel(ax, ay, del)
    if not self.enabled() or not self.set then return false end
    local rc = self:rowAt(ax, ay)
    if not rc or rc.e.kind ~= "int" or not rc.boxX then return false end
    if ax < rc.boxX or ax >= rc.boxX + rc.boxW then return false end

    local e = rc.e
    local n = tonumber(self.get(e.key)) or (e.min or 0)
    -- del is +1 down / -1 up in PZ; wheeling UP should raise the number.
    self.set(e.key, clamp(e, n - (del > 0 and 1 or -1) * (e.step or 1)))
    return true
end
