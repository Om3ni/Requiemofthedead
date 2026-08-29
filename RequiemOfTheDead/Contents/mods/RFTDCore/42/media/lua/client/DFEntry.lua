-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFEntry - the family's type-a-value popout (client only).
--
-- WHY A POPOUT AND NOT A BOX IN THE ROW. DFForm rows are DRAWN chrome, not
-- widgets: one invisible hotspot catches every interaction and the rows are
-- rectangles painted each frame. That is what lets the form scroll, clip and
-- reflow at any font without owning a widget tree. A text field is the one
-- control that cannot be drawn, because typing needs a real UITextBox2 with
-- keyboard focus.
--
-- Putting that widget INSIDE the form would break the two properties the form
-- exists to have. Child widgets are not affected by the stencil DFScroll sets,
-- so an entry box scrolled out of view keeps drawing over whatever is above it
-- and stays clickable while invisible; and the form would have to create,
-- destroy and reposition one widget per text row on every layout, at which
-- point it is a widget tree with a drawing loop bolted on.
--
-- So the row stays drawn - it shows the value and reads as a control - and the
-- typing happens here, in one window, over the top. One widget exists at a time
-- no matter how many text fields a schema declares.
--
-- IT IS ALSO THE HONEST PLACE FOR VALIDATION. A value that the consumer will
-- silently ignore ("Remove" where only "remove" is honoured) is the failure
-- mode a free text box invites, and a row has no room to say why. A window has
-- room: the rule is stated under the box, the message appears as you type, and
-- Save refuses rather than storing something inert. A caller supplies
-- validate() and gets all of that.
--
-- SINGLETON, same reasoning as DFHelp: a second one replaces the first. Two
-- half-typed values in two windows over the same form is a way to lose an edit,
-- not a feature.
--
-- NO ESCAPE-TO-CANCEL, deliberately rather than by omission. Key events reach
-- the element holding keyboard focus, and that is the text box - so a panel
-- level key handler here would either not fire or fight the box for input.
-- Cancel and the X are both one click away and neither can be got wrong.
--
-- ---------------------------------------------------------------------------
-- SUGGESTIONS, opt-in via opts.suggest.
--
-- A field whose valid values are a registry - an item type, a trait id - is not
-- free prose, and asking someone to type "Base.Nails" exactly is asking them to
-- remember a spelling the game never shows them. Dragonfly's Add Item field
-- solved that in 2026-08 with a list that narrows as you type; the LOGIC of it
-- is now DFItemQuery in Core, and the LIST is here, so the next field that
-- needs one declares a function instead of re-inlining a dropdown.
--
-- POLLED, NOT EVENT-DRIVEN. UITextBox2 has no text-changed callback of any
-- kind - the engine's own consumers poll it - so prerender compares the current
-- text against the last text it saw and re-queries only on a change. That is
-- one string compare per frame and one registry scan per keystroke.
--
-- THE BAND IS RESERVED WHETHER OR NOT IT HAS ROWS. A window that grew as
-- matches appeared would move Save out from under a click that was already on
-- its way down - the same reason the validation message has a line reserved for
-- it. An empty band says why it is empty instead.
--
-- PICKING FILLS THE BOX, IT DOES NOT COMMIT. The value is still yours to edit
-- afterwards, and Save still runs validate() over whatever ends up there - so a
-- suggestion is a shortcut, never an authority. UITextBox2.SetText writes
-- internalText and moves the caret to the end without touching focus
-- (UITextBox2.java:651-665), which is what makes that safe mid-typing.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

DFEntry = ISPanel:derive("DFEntry")

-- Survives a hot reload of this file, exactly as DFHelp's does: a window
-- referenced only from the class global becomes unclosable the moment the
-- global is replaced.
DFEntryState = DFEntryState or { instance = nil }

local PAD = 12

-- How many suggestions the band holds. Eight is what Dragonfly's Add Item field
-- has offered since it shipped; a list long enough to need scrolling is a list
-- being read instead of a query being narrowed.
local SUGGEST_ROWS = 8

local function fontBody()  return DFKit.font.small or UIFont.Small end
local function fontTitle() return DFKit.font.label or UIFont.Small end

-- TextManager is an eager singleton and resolves an absent font enum to its
-- default font (LuaManager.java:6930-6933; TextManager.java:119-129). The
-- measurement calls are direct; the layout floors below remain for a bad
-- numeric result, not an exception path.
local function lineH()
    local fh = getTextManager():getFontHeight(fontBody())
    return math.max(14, fh + 2)
end

local function titleH()
    local fh = getTextManager():getFontHeight(fontTitle())
    return math.max(24, fh + 12)
end

local function entryH()
    local fh = getTextManager():getFontHeight(fontBody())
    return math.max(DFKit.metrics.btnH, fh + 10)
end

local function tw(s)
    return getTextManager():MeasureStringX(fontBody(), s or "")
end

-- ---------------------------------------------------------------------------
-- Suggestions - the pure half
-- ---------------------------------------------------------------------------

-- What a suggest() answer has to look like before it is drawn. Providers hand
-- back whatever their registry gave them, so a row is accepted as a bare string
-- or as { value, label }, and anything without a usable value is dropped rather
-- than drawn - a row with no value is a click that puts "nil" in the box.
function DFEntry.normalize(rows)
    local out = {}
    if type(rows) ~= "table" then return out end
    for i = 1, #rows do
        local r     = rows[i]
        local value = (type(r) == "table") and r.value or r
        if type(value) == "string" and value ~= "" then
            local label = (type(r) == "table" and r.label) or value
            out[#out + 1] = { value = value, label = tostring(label) }
            if #out >= SUGGEST_ROWS then break end
        end
    end
    return out
end

-- Which suggestion a click at window y landed on, or nil. Split out because it
-- is the piece that fails SILENTLY when it is wrong: an off-by-one here puts
-- the neighbouring item in the box, and the list it came from looked correct.
--
-- `top` is the window's rowsY, set once at open time and used by the drawing,
-- the hover and this - one number, because three copies of it is how a hit test
-- drifts three pixels from what is on screen and nobody can see why.
--
-- Above the band needs no test of its own: y < top makes the quotient negative,
-- floor takes it to -1 or lower, and the i < 1 arm below already answers nil.
function DFEntry.rowAt(y, top, rowH, count)
    if not top or not rowH or rowH <= 0 or (count or 0) <= 0 then return nil end
    local i = math.floor((y - top) / rowH) + 1
    if i < 1 or i > count then return nil end
    return i
end

-- One row's text. The label alone when they are the same string, both when they
-- are not: "Nails" is what an admin is looking for and "Base.Nails" is what has
-- to end up in the field, and showing only one of them means either they cannot
-- find it or they cannot tell two modules' versions apart.
function DFEntry.rowText(row)
    if type(row) ~= "table" then return "" end
    local label, value = tostring(row.label or ""), tostring(row.value or "")
    if label == "" or label == value then return value end
    return label .. "  -  " .. value
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

function DFEntry:new(x, y, w, h, opts)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background    = false
    o.moveWithMouse = false
    o.opts          = opts or {}
    o.titleText     = o.opts.title or "Edit value"
    o.dragging      = false
    o.dragDX, o.dragDY = 0, 0
    o.problem       = nil       -- current validation message, or nil
    return o
end

function DFEntry:createChildren()
    ISPanel.createChildren(self)

    local eh = entryH()
    local ey = self.entryY or (titleH() + PAD)

    local box = ISTextEntryBox:new(tostring(self.opts.value or ""),
        PAD, ey, self.width - PAD * 2, eh)
    box.font   = fontBody()
    box.valign = "middle"
    box:initialise()
    box:instantiate()
    -- setMaxTextLength before any text arrives, so a caller's cap applies to
    -- the seeded value too rather than only to what is typed after it.
    -- Build 42.20's setters operate on the instantiated local widget: max
    -- length is a field write, placeholder is nil-safe, and focus is local
    -- state (UITextBox2.java:542-545, 673-675, 739-741).
    if self.opts.maxLen then box:setMaxTextLength(self.opts.maxLen) end
    if self.opts.placeholder then
        box:setPlaceholderText(self.opts.placeholder)
    end
    box:setText(tostring(self.opts.value or ""))
    self:addChild(box)
    self.entry = box
    box:focus()

    -- Enter commits. ISTextEntryBox:onCommandEntered is the engine's own hook
    -- for it (ISTextEntryBox.lua:16, assigned this way by ISMPEditAccount), and
    -- it is handed the BOX as self - so this closure ignores its argument and
    -- reads the window from the upvalue instead.
    local win = self
    box.onCommandEntered = function() win:commit() end

    local bw   = 86
    local by   = self.height - PAD - DFKit.metrics.btnH
    self.saveBtn = DFKit.button(self, self.width - PAD - bw, by, bw,
        self.opts.saveLabel or "Save", self, DFEntry.onSave, "primary")
    DFKit.button(self, self.width - PAD - bw * 2 - DFKit.metrics.gap, by, bw,
        "Cancel", self, DFEntry.onCancel, "action")
end

function DFEntry:onSave()   self:commit() end
function DFEntry:onCancel() DFEntry.close() end

-- Re-query only when the text actually changed. UITextBox2 has no text-changed
-- callback, so this is polled from prerender - the comparison is what keeps a
-- registry scan on the keystroke rather than on the frame.
--
-- NO pcall AROUND suggest(), unlike validate() a few lines down, and the
-- difference is worth stating because it looks inconsistent. A validate() that
-- throws leaves someone unable to Save and with nothing on screen explaining
-- why - a trapped state the guard exists to prevent. A suggest() that throws is
-- our own code failing, in a suite where every provider ships with this file;
-- it throws inside UIManager's per-element catch, gets logged at throw time,
-- and is fixed. Swallowing it would show an empty list, which is indistinguish-
-- able from "nothing matches" and would be found by nobody.
function DFEntry:refreshSuggestions()
    if type(self.opts.suggest) ~= "function" then return end
    local s = self:text()
    if s == self.lastQuery then return end
    self.lastQuery   = s
    self.picked      = nil
    self.hoverRow    = nil
    self.suggestions = DFEntry.normalize(self.opts.suggest(s))
end

-- A pick fills the box. It does not commit, and it does not bypass validate():
-- Save still runs the caller's rule over whatever is in the field, so a stale
-- provider offering something the rule refuses is caught like anything typed.
function DFEntry:pick(value)
    if not self.entry or type(value) ~= "string" then return end
    -- SetText writes internalText and moves the caret to the end without
    -- touching keyboard focus (UITextBox2.java:651-665), so this is safe while
    -- someone is mid-word.
    self.entry:setText(value)
    -- Collapsed afterwards: the list is now describing what is already in the
    -- box. lastQuery matches, so the poll above leaves it alone until typing
    -- resumes, and `picked` is what stops the empty band claiming that the
    -- value just chosen matches nothing.
    self.lastQuery   = value
    self.picked      = value
    self.suggestions = {}
    self.hoverRow    = nil
end

-- The current text, whatever the engine will actually hand the consumer.
function DFEntry:text()
    local s = ""
    if self.entry then
        -- Both UITextBox2 getters are direct field returns in the supported
        -- engine; internalText is the editable value consumers must receive.
        -- UITextBox2.java:314-320
        s = self.entry:getInternalText()
    end
    return tostring(s or "")
end

-- Run the caller's rule. No rule means anything is acceptable, which is the
-- right default for free prose like a zone subtitle.
function DFEntry:check(s)
    if type(self.opts.validate) ~= "function" then return true, nil end
    local ok, good, msg = pcall(self.opts.validate, s)
    if not ok then return true, nil end      -- a broken rule must not lock the box
    if good then return true, nil end
    return false, msg or "Not a value this setting accepts."
end

function DFEntry:commit()
    local s = self:text()
    local ok, msg = self:check(s)
    if not ok then
        self.problem = msg
        return
    end
    local fn = self.opts.onCommit
    -- Closed BEFORE the callback: the callback usually rebuilds the surface
    -- underneath, and a window still on the UIManager while its host is being
    -- torn down is how an orphan ends up painting over the new one.
    DFEntry.close()
    -- foreign callback: the caller's onCommit must not orphan the dialog flow
    if fn then pcall(fn, s) end
end

function DFEntry:prerender()
    local c  = DFKit.col
    local a  = DFKit.alpha
    local w, h = self.width, self.height

    self:drawRect(0, 0, w, h, math.min(0.95, (a.window or 0.6) + 0.3),
        c.bg.r, c.bg.g, c.bg.b)
    self:drawRectBorder(0, 0, w, h, 0.7, c.accent.r, c.accent.g, c.accent.b)

    local fTitle, fBody = fontTitle(), fontBody()
    local th, lh = titleH(), lineH()

    self:drawRect(0, 0, w, th, 0.5, c.panel.r, c.panel.g, c.panel.b)
    local ty = math.floor((th - lh) / 2) + 1
    self:drawText(self.titleText, PAD, ty, c.text.r, c.text.g, c.text.b, 1, fTitle)

    local closeHot = self.hoverClose
    self:drawText("X", w - 18, ty,
        closeHot and c.accent.r or c.textDim.r,
        closeHot and c.accent.g or c.textDim.g,
        closeHot and c.accent.b or c.textDim.b, 1, fTitle)
    self:drawRect(0, th, w, 1, 0.4, c.line.r, c.line.g, c.line.b)

    -- Validate every frame rather than on keystroke: it is a string compare
    -- against a short rule, and doing it here means the message tracks the box
    -- without this file having to own an onTextChange hook as well.
    local s = self:text()
    local ok, msg = self:check(s)
    self.problem = (not ok) and msg or nil

    -- Suggestions, in the band reserved for them at open time. DRAWN, not
    -- widgets, for the reason at the top of this file: one text box exists here
    -- and nothing else in the window wants keyboard focus.
    if (self.suggestH or 0) > 0 then
        self:refreshSuggestions()
        local rows, sy = self.suggestions or {}, self.suggestY
        self:drawRect(PAD, sy, w - PAD * 2, self.suggestH, 0.35,
            c.panel.r, c.panel.g, c.panel.b)
        self:drawRectBorder(PAD, sy, w - PAD * 2, self.suggestH, 0.35,
            c.line.r, c.line.g, c.line.b)

        if #rows == 0 then
            -- Three different silences, and they are not interchangeable:
            -- nothing typed, nothing found, and one already chosen.
            local line
            if self.picked and s == self.picked then
                line = "Picked.  Keep typing to search again."
            elseif s == "" then
                line = "Start typing to search."
            else
                line = "Nothing matches '" .. s .. "'."
            end
            self:drawText(DFKit.fitText(line, fBody, w - PAD * 2 - 12),
                PAD + 6, self.rowsY, c.textDim.r, c.textDim.g, c.textDim.b, 0.9, fBody)
        else
            for i = 1, #rows do
                local ry = self.rowsY + (i - 1) * lh
                if i == self.hoverRow then
                    self:drawRect(PAD + 1, ry - 1, w - PAD * 2 - 2, lh, 0.55,
                        c.accentDim.r, c.accentDim.g, c.accentDim.b)
                end
                local tc = (i == self.hoverRow) and c.text or c.textDim
                self:drawText(
                    DFKit.fitText(DFEntry.rowText(rows[i]), fBody, w - PAD * 2 - 12),
                    PAD + 6, ry, tc.r, tc.g, tc.b, 1, fBody)
            end
        end
    end

    -- The rule, and then whatever is currently wrong with the text. The rule
    -- stays visible while the message comes and goes, because a message alone
    -- tells you that you are wrong and not what right looks like.
    local y = self.bodyY or (self.entryY + entryH() + 6)
    for _, ln in ipairs(self.ruleLines or {}) do
        self:drawText(ln, PAD, y, c.textDim.r, c.textDim.g, c.textDim.b, 0.9, fBody)
        y = y + lh
    end
    if self.problem then
        self:drawText(DFKit.fitText(self.problem, fBody, w - PAD * 2), PAD, y,
            c.warn.r, c.warn.g, c.warn.b, 1, fBody)
    end

    -- Save is disabled while the value would be refused, so the button agrees
    -- with the message instead of being a click that silently does nothing.
    if self.saveBtn then self.saveBtn:setEnable(self.problem == nil) end
end

function DFEntry:onMouseMove(dx, dy)
    local x, y = self:getMouseX(), self:getMouseY()
    self.hoverClose = (y < titleH() and x > self.width - 26)
    self.hoverRow = ((self.suggestH or 0) > 0)
        and DFEntry.rowAt(y, self.rowsY, lineH(), #(self.suggestions or {}))
        or nil
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFEntry:onMouseMoveOutside(dx, dy)
    self.hoverClose = false
    self.hoverRow   = nil
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFEntry:onMouseDown(x, y)
    if y < titleH() then
        if x > self.width - 26 then DFEntry.close(); return end
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
        return
    end
    if (self.suggestH or 0) > 0 then
        local rows = self.suggestions or {}
        local i = DFEntry.rowAt(y, self.rowsY, lineH(), #rows)
        if i then self:pick(rows[i].value) end
    end
end

function DFEntry:onMouseUp()        self.dragging = false end
function DFEntry:onMouseUpOutside() self.dragging = false end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

function DFEntry.close()
    local w = DFEntryState.instance
    if w then
        -- Hand keyboard focus back BEFORE the window goes away. A UITextBox2
        -- that is removed while still focused keeps eating keystrokes, which
        -- reads as the game ignoring movement keys after closing a dialog -
        -- and there is then nothing on screen to click to give the focus back.
        -- Vanilla teardown is nil-safe (ISUIElement.lua:1373-1380); the
        -- instance still clears below so this dialog can be reopened.
        -- The stored entry was initialised and instantiated before assignment;
        -- vanilla unfocus directly forwards to that backing object
        -- (ISTextEntryBox.lua:150-152).
        if w.entry then w.entry:unfocus() end
        w:removeFromUIManager()
        DFEntryState.instance = nil
    end
end

-- opts:
--   title        window heading
--   value        the string to seed the box with
--   rule         one line under the box saying what a valid value looks like
--   placeholder  ghost text for an empty box
--   maxLen       hard cap, applied to the seeded value as well
--   validate(s)  -> ok, message. Absent means anything goes.
--   onCommit(s)  called with the accepted string. Not called on cancel.
--   saveLabel    override for the commit button
--   nearX/nearY  open beside a point rather than centre-screen
--   suggest(s)   -> rows, each a string or { value, label }. Present means the
--                window carries a type-ahead band; absent means it does not,
--                and every caller written before this option is unchanged.
function DFEntry.show(opts)
    opts = opts or {}
    DFEntry.close()

    local fBody = fontBody()
    local W = 420
    -- Wide enough for the rule, because a rule that wraps to three lines under
    -- a one-line box reads as the main content.
    if opts.rule then W = math.max(W, math.min(680, tw(opts.rule) + PAD * 2 + 8)) end
    -- A suggestion reads "Nails  -  Base.Nails", so the window that shows them
    -- starts wider than one that only holds a value.
    if opts.suggest then W = math.max(W, 520) end

    local ruleLines = opts.rule and DFKit.wrapText(opts.rule, fBody, W - PAD * 2) or {}

    local th, lh, eh = titleH(), lineH(), entryH()
    local entryY = th + PAD
    local suggestY = entryY + eh + 6
    -- RESERVED WHOLE, whether or not there are matches to put in it. See the
    -- header: a band that grew as results arrived would move Save out from
    -- under a click already on its way down.
    local suggestH = opts.suggest and (SUGGEST_ROWS * lh + 6) or 0
    -- One spare line under the rule, always reserved: the validation message
    -- appears and disappears as you type, and a window that resized under the
    -- cursor to make room for it would move the button out from under a click.
    local h = suggestY + suggestH + (#ruleLines + 1) * lh + PAD
              + DFKit.metrics.btnH + PAD

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x = opts.nearX and (opts.nearX + 16) or math.floor((sw - W) / 2)
    local y = opts.nearY and (opts.nearY - 20) or math.floor((sh - h) / 2)
    if x + W > sw - 8 then x = math.max(8, (opts.nearX or sw) - W - 16) end
    if y + h > sh - 8 then y = math.max(8, sh - h - 8) end
    if x < 8 then x = 8 end
    if y < 8 then y = 8 end

    local win = DFEntry:new(x, y, W, h, opts)
    win.ruleLines = ruleLines
    win.entryY    = entryY
    win.suggestY  = suggestY
    win.suggestH  = suggestH
    -- Where row one starts, written ONCE. The drawing, the hover and the click
    -- all read this; a literal offset repeated at each of them is a hit test
    -- that drifts from the list on screen the first time one of the three is
    -- adjusted, and the list keeps looking right while it does.
    win.rowsY     = suggestY + 3
    win.bodyY     = suggestY + suggestH
    -- Seeded so a window opened on an EXISTING value starts collapsed. Querying
    -- the seed would list the one item already in the box, under a heading
    -- inviting a choice that has been made.
    win.suggestions = {}
    win.lastQuery   = tostring(opts.value or "")
    win.picked      = (win.lastQuery ~= "") and win.lastQuery or nil
    win:initialise()
    win:instantiate()
    win:addToUIManager()
    DFEntryState.instance = win
    return win
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
