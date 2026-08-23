-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFLayoutEditor - arranging one page: drag to reorder, add your own headers.
--
-- ---------------------------------------------------------------------------
-- WHY A SEPARATE WINDOW rather than making the settings form draggable. The
-- form's rows ARE controls - a click on a boolean toggles it, a click on a
-- stepper steps it - and a drag is a click that moved. Overloading the two on
-- the same row means every mis-drag writes a server option, which is the worst
-- possible cost for a mis-gesture on this particular surface. The arranger
-- shows names only, has no dials at all, and nothing it does reaches a sandbox
-- or server value.
--
-- ---------------------------------------------------------------------------
-- THE WORKING LIST IS THE WIRE SHAPE. It is DFOverlay.flatten's output - a flat
-- sequence of option-name strings and { h = title } tables - edited in place and
-- sent as-is. There is no editor-shaped model that has to be converted at both
-- ends, because a conversion pair is two places for an option to get lost and
-- the whole subject of this feature is options not getting lost.
--
-- It is seeded from the SHAPED page, not from the stored layout, and that
-- matters: the shaped page is what the admin is looking at, including any
-- option that fell through because the layout predates it. Opening the arranger
-- and saving without touching anything therefore turns "three options are not
-- placed" into a layout that places them where they already appeared. That is
-- the intended way to adopt a new option, and it is one click.
--
-- ---------------------------------------------------------------------------
-- AN OPTION CANNOT BE REMOVED HERE. Remove is a header-only verb, and asking to
-- remove an option is answered with a sentence rather than being greyed out in
-- silence - "why can I not do this" deserves the reason, not the absence of a
-- button.
--
-- The model already cannot hide an option: DFOverlay.apply emits every reflected
-- option whether the layout mentions it or not. This is the second half of the
-- same rule, at the gesture rather than at the data, and both are deliberate.
-- Without the model rule a stale layout would hide options silently; without
-- this rule an admin would spend a minute trying to hide one and conclude the
-- panel was broken when it reappeared.
--
-- ---------------------------------------------------------------------------
-- THE HOLD lives here too, and only here. When RDConfigStore is holding a
-- layout file - it outlived the world after a wipe, or it will not decode - the
-- panel is drawing reflected order while a real layout sits unread on disk. Both
-- views say so in their footer; the two buttons that resolve it are in this one
-- window rather than in each view, because the hold is a property of the whole
-- document and duplicating the pair would be two copies of the same decision.

if isServer() then return end

require "DFKit"
require "DFConfirm"
require "DFOverlay"
require "Admin/DFLayout"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextBox"
require "ISUI/ISButton"

DFLayoutEditor = DFLayoutEditor or {}

local FONT  = DFKit.font.small
local PAD   = 8
local WIN_W = 460
local WIN_H = 540

-- ---------------------------------------------------------------------------
-- The working list. PURE - no widget, no engine - because this is the half that
-- can be tested, and every one of these operations is a way to lose a row.
-- ---------------------------------------------------------------------------

local function isHeader(e) return type(e) == "table" and e.h ~= nil end

-- name -> display label, for drawing. The list itself holds names because names
-- are what the server stores; a label is presentation and would go stale the
-- moment a translation changed.
function DFLayoutEditor.labelsOf(page)
    local out = {}
    if type(page) ~= "table" then return out end
    for _, sec in ipairs(page.sections or {}) do
        for _, opt in ipairs(sec.options or {}) do
            if opt.name then out[opt.name] = opt.label or opt.short or opt.name end
        end
    end
    return out
end

-- Move one row. Returns the row's new index, or nil when the move was refused;
-- a refused move is a no-op rather than a clamp, because clamping a drag that
-- ended off the list would silently drop the row at the end.
function DFLayoutEditor.move(work, from, to)
    if type(work) ~= "table" then return nil end
    if type(from) ~= "number" or type(to) ~= "number" then return nil end
    if from < 1 or from > #work or to < 1 or to > #work or from == to then return nil end
    local e = table.remove(work, from)
    table.insert(work, to, e)
    return to
end

function DFLayoutEditor.insertHeader(work, at, title)
    local clean = DFOverlay.sanitize({ { h = tostring(title or "") } })
    if #clean == 0 then return nil, "A header needs a name." end
    if #work >= DFOverlay.MAX_ENTRIES then
        return nil, "This page is already at the maximum number of rows."
    end
    local i = (type(at) == "number" and at >= 1 and at <= #work) and at or (#work + 1)
    table.insert(work, i, clean[1])
    return i
end

-- Headers only. See the note in the header: the refusal is a sentence, because
-- the reason is not obvious and the alternative - a greyed button - teaches
-- nothing.
function DFLayoutEditor.removeAt(work, i)
    local e = work and work[i]
    if e == nil then return false, "Select a row first." end
    if not isHeader(e) then
        return false, "Options cannot be removed from a layout - a settings "
            .. "panel that hides a live option is worse than one that has none. "
            .. "Move it instead, or put it under a header of its own."
    end
    table.remove(work, i)
    return true
end

function DFLayoutEditor.rename(work, i, title)
    local e = work and work[i]
    if not isHeader(e) then return false, "Only a header can be renamed." end
    local clean = DFOverlay.sanitize({ { h = tostring(title or "") } })
    if #clean == 0 then return false, "A header needs a name." end
    e.h = clean[1].h
    return true
end

-- ---------------------------------------------------------------------------
-- The list widget
-- ---------------------------------------------------------------------------

local Rows = ISScrollingListBox:derive("DFLayoutRows")

function Rows:doDrawItem(y, item, alt)
    local e = item.item
    local h = item.height

    if self.selected == item.index then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, h - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.10, 1, 1, 1)
    end

    -- The drop marker. Drawn at the TOP of the row the pointer is over, which
    -- is where the row being dragged will land - a highlight on the row itself
    -- would not say whether it goes above or below.
    if self.dragFrom and self.dragTo == item.index then
        local a = DFKit.col.accent
        self:drawRect(0, y, self.width, 2, 1, a.r, a.g, a.b)
    end

    if isHeader(e) then
        local a = DFKit.col.accent
        self:drawRect(6, y + h / 2, 10, 1, 0.8, a.r, a.g, a.b)
        self:drawText(DFKit.fitText(e.h, FONT, self.width - 30),
                      22, y + 3, a.r, a.g, a.b, 1, FONT)
    else
        local c = DFKit.col.text
        local label = (self.labels and self.labels[e]) or e
        self:drawText(DFKit.fitText(label, FONT, self.width - 24),
                      22, y + 3, c.r, c.g, c.b, 1, FONT)
    end
    return y + h
end

function Rows:onMouseDown(x, y)
    local i = self:rowAt(x, y)
    if i < 1 or i > #self.items then return end
    self.selected = i
    self.dragFrom = i
    self.dragTo   = i
    if self.onSelectRow then self:onSelectRow(i) end
end

function Rows:onMouseMove(dx, dy)
    ISScrollingListBox.onMouseMove(self, dx, dy)
    if not self.dragFrom then return end
    local i = self:rowAt(self:getMouseX(), self:getMouseY())
    if i >= 1 and i <= #self.items then self.dragTo = i end
end

function Rows:onMouseUp(x, y)
    -- Through to the base FIRST: its whole body is `vscroll.scrolling = false`,
    -- and skipping it leaves a scrollbar drag latched on for the rest of the
    -- window's life (ISScrollingListBox.lua:135-139).
    ISScrollingListBox.onMouseUp(self, x, y)
    local from, to = self.dragFrom, self.dragTo
    self.dragFrom, self.dragTo = nil, nil
    if not from or not to then return end
    if self.onReorder then self:onReorder(from, to) end
end

-- Releasing off the list CANCELS rather than dropping at the last row the
-- pointer crossed. A drag that left the window is a drag the admin abandoned,
-- and guessing at an intent they did not express is how a row ends up somewhere
-- nobody chose.
function Rows:onMouseUpOutside(x, y)
    ISScrollingListBox.onMouseUpOutside(self, x, y)
    self.dragFrom, self.dragTo = nil, nil
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local Editor = ISCollapsableWindow:derive("DFLayoutEditor")
local OPEN = nil

function Editor:refill()
    local box = self.rows
    box.labels = self.labels
    DFKit.refillList(box, function(b)
        for _, e in ipairs(self.work) do
            local i = b:addItem(isHeader(e) and e.h or e, e)
            i.height = DFKit.rowHeight()
        end
    end)
end

function Editor:say(text, bad)
    self.status = text
    self.statusBad = bad and true or false
end

function Editor:createChildren()
    ISCollapsableWindow.createChildren(self)

    local topY = self:titleBarHeight() + PAD
    local btnH = DFKit.metrics.btnH
    local footH = btnH * 2 + PAD * 3
    local listH = self.height - topY - footH - PAD

    local box = Rows:new(PAD, topY, self.width - PAD * 2, listH)
    box.itemheight = DFKit.rowHeight()
    box.drawBorder = true
    DFKit.well(box)
    box:initialise(); box:instantiate()
    self:addChild(box)
    self.rows = box

    local ed = self
    function box:onReorder(from, to)
        if DFLayoutEditor.move(ed.work, from, to) then
            ed.dirty = true
            ed:refill()
            ed.rows.selected = to
            ed:say("Moved.")
        end
    end
    function box:onSelectRow() ed:say(nil) end

    local y1 = topY + listH + PAD
    local y2 = y1 + btnH + PAD
    local x  = PAD

    local function mk(row, w, label, fn, kind, tip)
        local b = DFKit.button(self, x, row, w, label, self, fn, kind,
                               tip and { tooltip = tip } or nil)
        x = x + w + 6
        return b
    end

    mk(y1, 92, "Add header", function() self:promptHeader() end, nil,
       "Insert a section heading above the selected row. Headings are yours - "
       .. "they replace whatever sections the mod itself declared.")
    mk(y1, 72, "Rename", function() self:promptRename() end, nil,
       "Rename the selected heading.")
    mk(y1, 72, "Remove", function() self:removeSelected() end, nil,
       "Remove the selected heading. Options cannot be removed.")
    mk(y1, 46, "Up",   function() self:nudge(-1) end)
    mk(y1, 46, "Down", function() self:nudge(1) end)

    x = PAD
    self.resetBtn = mk(y2, 92, "Reset", function() self:reset() end, nil,
       "Discard this page's layout entirely and go back to the order the mod "
       .. "itself declares.")

    -- The two hold buttons. Built always and hidden when there is nothing held,
    -- rather than built conditionally: a window that grows widgets on a state
    -- change is a window that has to be rebuilt to lose them again.
    self.takeBtn = mk(y2, 108, "Recover file", function()
        DFLayout.recover(true); self:close()
    end, nil, "Load the layout file left on disk by the previous world.")
    self.dropBtn = mk(y2, 108, "Discard file", function()
        DFLayout.recover(false); self:close()
    end, nil, "Abandon the layout file on disk. The next save overwrites it.")

    -- Right-aligned, laid out right to left so Save sits at the edge.
    local sx = self.width - PAD
    for _, spec in ipairs({ { 72, "Save",  function() self:save() end, "action" },
                            { 72, "Close", function() self:close() end, nil } }) do
        sx = sx - spec[1]
        DFKit.button(self, sx, y2, spec[1], spec[2], self, spec[3], spec[4])
        sx = sx - 6
    end

    self.footY = y1 - 2
    self:refill()
end

function Editor:selectedIndex()
    local i = self.rows and self.rows.selected
    if type(i) ~= "number" or i < 1 or i > #self.work then return nil end
    return i
end

function Editor:nudge(delta)
    local i = self:selectedIndex()
    if not i then return self:say("Select a row first.", true) end
    local to = DFLayoutEditor.move(self.work, i, i + delta)
    if not to then return end
    self.dirty = true
    self:refill()
    self.rows.selected = to
    self.rows:ensureVisible(to)
end

function Editor:removeSelected()
    local i = self:selectedIndex()
    local ok, why = DFLayoutEditor.removeAt(self.work, i)
    if not ok then return self:say(why, true) end
    self.dirty = true
    self:refill()
    self:say("Heading removed.")
end

function Editor:promptHeader()
    local at = self:selectedIndex()
    local ed = self
    local modal
    modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 60, 300, 120,
        "Heading:", "", nil, function(_, btn)
            if btn.internal ~= "OK" or not (modal and modal.entry) then return end
            local i, why = DFLayoutEditor.insertHeader(ed.work, at, modal.entry:getText())
            if not i then return ed:say(why, true) end
            ed.dirty = true
            ed:refill()
            ed.rows.selected = i
            ed:say("Heading added.")
        end, getPlayer() and getPlayer():getPlayerNum() or 0)
    modal:initialise(); modal:addToUIManager()
end

function Editor:promptRename()
    local i = self:selectedIndex()
    local e = i and self.work[i]
    if not isHeader(e) then return self:say("Select a heading to rename.", true) end
    local ed = self
    local modal
    modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 60, 300, 120,
        "Heading:", e.h, nil, function(_, btn)
            if btn.internal ~= "OK" or not (modal and modal.entry) then return end
            local ok, why = DFLayoutEditor.rename(ed.work, i, modal.entry:getText())
            if not ok then return ed:say(why, true) end
            ed.dirty = true
            ed:refill()
        end, getPlayer() and getPlayer():getPlayerNum() or 0)
    modal:initialise(); modal:addToUIManager()
end

function Editor:save()
    DFLayout.save(self.key, self.work)
    self:close()
end

-- Reset is a real loss - somebody's arrangement, gone for everyone - so it
-- asks. DFConfirm.ask is the family's always-confirm shape for a single
-- irreversible act.
function Editor:reset()
    local ed = self
    DFConfirm.ask("Discard the saved layout for this page? Every admin goes "
        .. "back to the order the mod declares.", function()
        DFLayout.save(ed.key, {})
        ed:close()
    end)
end

function Editor:prerender()
    ISCollapsableWindow.prerender(self)

    local held = DFLayout.held(self.key)
    if self.takeBtn then
        self.takeBtn:setVisible(held ~= nil)
        self.dropBtn:setVisible(held ~= nil)
        self.resetBtn:setVisible(held == nil)
    end

    local text, col
    if held then
        text = held == "corrupt"
            and "The layout file will not decode. Recover is not possible; "
             .. "discard it to start writing again."
            or "A layout file from a previous world is on disk, unread."
        col = DFKit.col.accent
        if held == "corrupt" and self.takeBtn then self.takeBtn:setVisible(false) end
    elseif self.status then
        text = self.status
        col = self.statusBad and DFKit.col.accent or DFKit.col.textDim
    else
        local n = 0
        for _, e in ipairs(self.work) do if not isHeader(e) then n = n + 1 end end
        text = n .. " option(s), " .. (#self.work - n) .. " heading(s)"
            .. (self.dirty and " - not saved" or "")
        col = self.dirty and DFKit.col.accent or DFKit.col.textDim
    end
    self:drawText(DFKit.fitText(text, FONT, self.width - PAD * 2),
                  PAD, self.footY, col.r, col.g, col.b, 1, FONT)
end

function Editor:close()
    OPEN = nil
    self:removeFromUIManager()
end

-- ---------------------------------------------------------------------------
-- Entry point. `page` is the SHAPED page - what the view is drawing - so the
-- editor opens on exactly what the admin can see.
-- ---------------------------------------------------------------------------
function DFLayoutEditor.open(key, page)
    if not DFOverlay.validKey(key) then return nil end
    if not page or (page.count or 0) == 0 then return nil end
    if OPEN then OPEN:close() end

    local win = Editor:new(getCore():getScreenWidth() / 2 - WIN_W / 2,
                           getCore():getScreenHeight() / 2 - WIN_H / 2, WIN_W, WIN_H)
    win.key    = key
    win.work   = DFOverlay.flatten(page)
    win.labels = DFLayoutEditor.labelsOf(page)
    win.dirty  = false
    win:setTitle("Arrange - " .. tostring(page.label or key))
    win:setResizable(false)
    win:initialise()
    win:instantiate()
    win:addToUIManager()
    OPEN = win
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
