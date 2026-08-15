-- SPDX-License-Identifier: GPL-3.0-or-later
-- WSJournal - the Workshop's Journal sub-tab (client): the whole loaded
-- recipe catalogue as a field guide.
--
-- THE PITCH (owner, 2026-08-13): "recipes you own show up as white, recipes
-- you don't show up as grey. White recipes show what you need to have to
-- craft, grey ones show what you need to do to GET them. That would really
-- help new players a TON." So every row answers one of two questions:
--   WHITE (known)  - what does crafting it take? Required skills in the
--                    detail pane, full ingredient list one click away in the
--                    Craft pane (vanilla's own renderer - never duplicated
--                    here).
--   GREY (unknown) - how do I learn it? Teaching literature (green when a
--                    copy is in your inventory), auto-learn skill thresholds
--                    against your current levels, research, spawn grants.
--
-- Delineated + searchable: filter by category, by text (recipe or output
-- item name), and by known/unknown. The Workshop's routing can also pin the
-- Journal to one item's recipes (the grey half of a Gear/vehicle-part click);
-- the pin is a labelled chip with Show All as the way out.
--
-- Known-ness and carried-ness are evaluated at populate time and refreshed
-- by any filter change or Refresh press - reading a magazine flips its rows
-- white on the next repaint, not the next session (WSIndex caches
-- scripts, never player state).

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "DFKit"
require "Workshop/WSIndex"

WSJournal = WSJournal or {}
local V = WSJournal

local PAD = 8
local ALL_CATS = "All categories"
local KNOWN_OPTS = { "All recipes", "Known only", "Unknown only" }

local function fS() return DFKit.font.small or UIFont.Small end
local function fh() return getTextManager():getFontHeight(fS()) end

-- ---------------------------------------------------------------------------
-- Filtering + population
-- ---------------------------------------------------------------------------

-- Pin the catalogue to an explicit recipe set (the routing door).
-- names = array of recipe names; label = what the chip says.
function V.setPin(names, label)
    -- counted, NOT next(): B42's Kahlua registers no global `next`, so
    -- `next(set) ~= nil` throws "Object tried to call nil" - which it did,
    -- live, on the first Journal-routed click (2026-08-08).
    local set, n = {}, 0
    for _, nm in ipairs(names or {}) do set[nm] = true; n = n + 1 end
    V.pin = (n > 0) and { set = set, label = tostring(label or "?") } or nil
    V.populate()
end

function V.clearPin()
    V.pin = nil
    V.populate()
end

local function matchesSearch(rec, needle)
    if needle == "" then return true end
    if string.find(string.lower(tostring(rec.disp)), needle, 1, true) then return true end
    for _, d in ipairs(rec.outputDisp) do
        if string.find(string.lower(tostring(d)), needle, 1, true) then return true end
    end
    return false
end

function V.populate()
    local player = getPlayer()
    if not player or not V.list then return end

    local needle = string.lower((V.search and V.search:getText()) or "")
    needle = needle:gsub("^%s+", ""):gsub("%s+$", "")
    local cat = V.catSel or ALL_CATS
    local kf  = V.knownSel or 1

    local rows = {}
    for _, rec in ipairs(WSIndex.all()) do
        if (not V.pin or V.pin.set[rec.name])
            and (cat == ALL_CATS or rec.cat == cat)
            and matchesSearch(rec, needle) then
            local known = WSIndex.known(player, rec)
            if kf == 1 or (kf == 2 and known) or (kf == 3 and not known) then
                rows[#rows + 1] = { rec = rec, known = known }
            end
        end
    end
    V.shown = #rows
    DFKit.refillList(V.list, function(box)
        for _, row in ipairs(rows) do box:addItem(row.rec.disp, row) end
    end)
end

-- ---------------------------------------------------------------------------
-- Row + detail drawing
-- ---------------------------------------------------------------------------
local function drawRow(self, y, item, alt)
    local row = item.item
    local h = self.itemheight
    local C = DFKit.col
    local w = self:getWidth()
    if alt then self:drawRect(0, y, w, h, 0.06, 1, 1, 1) end
    if self.selected == item.index then
        self:drawRect(0, y, w, h, 0.12, C.accent.r, C.accent.g, C.accent.b)
    end
    local catW = 150
    if row.known then
        self:drawText(DFKit.fitText(row.rec.disp, self.font, w - catW - 20),
            8, y + 3, 1, 1, 1, 1, self.font)
    else
        self:drawText(DFKit.fitText(row.rec.disp, self.font, w - catW - 20),
            8, y + 3, 0.45, 0.45, 0.45, 1, self.font)
    end
    self:drawText(row.rec.cat, w - catW, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 0.8, self.font)
    return y + h
end

-- The detail pane's line list for a selection. Each line = { text, colKey }.
local function detailLines(player, rec, known)
    local lines = {}
    local function add(t, c) lines[#lines + 1] = { text = t, col = c } end

    if known then
        add("You know this recipe.", "ok")
        if rec.reqSkills and #rec.reqSkills > 0 then
            for _, s in ipairs(rec.reqSkills) do
                local txt, met = WSIndex.skillLine(player, s)
                add("Needs skill: " .. txt, met == false and "warn" or "text")
            end
        end
        add("Open it in Craft for the full ingredient list.", "textDim")
        return lines
    end

    add("You do not know this recipe yet. Ways to get it:", "warn")
    local inv = player:getInventory()
    for _, t in ipairs(rec.taughtBy) do
        local carried = (inv ~= nil and t.type ~= nil and inv:containsTypeRecurse(t.type)) == true
        add("  Read: " .. t.disp .. (carried and "  (in your inventory!)" or ""),
            carried and "ok" or "text")
    end
    if rec.autoAny and #rec.autoAny > 0 then
        for _, s in ipairs(rec.autoAny) do
            local txt = WSIndex.skillLine(player, s)
            add("  Learned free at ANY of: " .. txt, "text")
        end
    end
    if rec.autoAll and #rec.autoAll > 0 then
        for _, s in ipairs(rec.autoAll) do
            local txt = WSIndex.skillLine(player, s)
            add("  Learned free at ALL of: " .. txt, "text")
        end
    end
    if rec.research then
        add("  Research: dismantle one at a workbench (skill level "
            .. tostring(rec.research) .. ")", "text")
    end
    for _, g in ipairs(rec.grantedBy) do
        add("  Granted at creation by: " .. g, "textDim")
    end
    if #rec.taughtBy == 0 and #(rec.autoAny or {}) == 0 and #(rec.autoAll or {}) == 0
        and not rec.research and #rec.grantedBy == 0 then
        add("  No learning path is declared - it may be admin- or event-granted.", "textDim")
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------
local Root = ISPanel:derive("WSJournalRoot")

function Root:prerender()
    ISPanel.prerender(self)
    local C = DFKit.col
    local f, lh = fS(), fh()

    -- Filter changes are detected by polling here rather than wiring each
    -- widget's change callback - one code path, and a hot-reloaded panel
    -- cannot strand a stale closure inside a combo.
    local needle = (V.search and V.search:getText()) or ""
    -- getOptionText is nil-safe on an out-of-range selected index
    local cat = (V.catCombo and V.catCombo:getOptionText(V.catCombo.selected)) or ALL_CATS
    local kf = V.knownCombo and V.knownCombo.selected or 1
    if needle ~= V.lastSearch or cat ~= V.catSel or kf ~= V.knownSel then
        V.lastSearch, V.catSel, V.knownSel = needle, cat, kf
        V.populate()
    end

    -- pin chip + result count
    local ty = V.filterH - lh - 4
    if V.pin then
        DFKit.drawChip(self, PAD, ty - 2, "Showing recipes for: " .. V.pin.label, "accent")
    end
    self:drawText(tostring(V.shown or 0) .. " recipe(s)",
        self.width - 110, ty, C.textDim.r, C.textDim.g, C.textDim.b, 1, f)

    -- detail pane
    local dy = self.height - V.detailH
    self:drawRect(0, dy, self.width, 1, 0.45, C.line.r, C.line.g, C.line.b)
    local sel = V.list and V.list.items and V.list.items[V.list.selected]
    if sel then
        local player = getPlayer()
        local row = sel.item
        self:drawText(row.rec.disp, PAD, dy + 4,
            row.known and 1 or 0.6, row.known and 1 or 0.6, row.known and 1 or 0.6, 1, f)
        if player then
            local ly = dy + 4 + lh + 3
            for _, line in ipairs(detailLines(player, row.rec, row.known)) do
                local c = C[line.col] or C.text
                self:drawText(DFKit.fitText(line.text, f, self.width - PAD * 2 - 120),
                    PAD, ly, c.r, c.g, c.b, 1, f)
                ly = ly + lh + 2
                if ly > self.height - lh then break end
            end
        end
        if V.btnCraft then V.btnCraft:setVisible(row.known == true) end
    else
        DFKit.drawEmpty(self, 0, dy, self.width, V.detailH, "Select a recipe.")
        if V.btnCraft then V.btnCraft:setVisible(false) end
    end
end

function V.create(parent, w, h)
    V.root = Root:new(0, 0, w, h)
    V.root.background = false
    V.root:initialise()
    V.root:instantiate()
    parent:addChild(V.root)

    V.search = ISTextEntryBox:new("", 0, 0, 200, fh() + 8)
    V.search:initialise()
    V.search:instantiate()
    V.root:addChild(V.search)

    V.catCombo = ISComboBox:new(0, 0, 190, fh() + 8, nil, nil)
    V.catCombo:initialise()
    V.catCombo:addOption(ALL_CATS)
    WSIndex.build()
    for _, c in ipairs(WSIndex.cats or {}) do V.catCombo:addOption(c) end
    -- The vanilla combo starts at selected = 0 ("nothing"); an unselected
    -- known-filter would read as index 0 and match no branch, blanking the
    -- whole catalogue on first open.
    V.catCombo.selected = 1
    V.root:addChild(V.catCombo)

    V.knownCombo = ISComboBox:new(0, 0, 140, fh() + 8, nil, nil)
    V.knownCombo:initialise()
    for _, o in ipairs(KNOWN_OPTS) do V.knownCombo:addOption(o) end
    V.knownCombo.selected = 1
    V.root:addChild(V.knownCombo)

    V.btnAll = DFKit.button(V.root, 0, 0, 80, "Show all", V, function() V.clearPin() end)

    V.list = ISScrollingListBox:new(0, 0, w, h)
    V.list:initialise()
    V.list.font = fS()
    V.list.itemheight = fh() + 6
    V.list.drawBorder = true
    V.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    V.list.doDrawItem = drawRow
    V.root:addChild(V.list)

    V.btnCraft = DFKit.button(V.root, 0, 0, 110, "Open in Craft", V, function()
        local sel = V.list.items and V.list.items[V.list.selected]
        if sel and sel.item.known and WSTab and WSTab.openCraft then
            -- guarded: a Workshop door (see WSTab's header) - a routing bug
            -- costs one console line, never a stack trace out of a click
            pcall(WSTab.openCraft, { sel.item.rec }, sel.item.rec.disp)
        end
    end, "primary")
    V.btnCraft:setVisible(false)

    V.lastSearch, V.catSel, V.knownSel = "", ALL_CATS, 1
    V.layout(w, h)
end

function V.layout(w, h)
    local lh = fh()
    local rowH = lh + 10
    V.filterH = rowH + lh + 10
    V.detailH = lh * 8 + 14
    V.root:setWidth(w); V.root:setHeight(h)

    V.search:setX(PAD); V.search:setY(2); V.search:setWidth(200)
    V.catCombo:setX(PAD * 2 + 200); V.catCombo:setY(2)
    V.knownCombo:setX(PAD * 3 + 390); V.knownCombo:setY(2)
    V.btnAll:setX(w - V.btnAll:getWidth() - PAD); V.btnAll:setY(2)

    DFKit.sizeList(V.list, 0, V.filterH, w, h - V.filterH - V.detailH - 2)
    V.btnCraft:setX(w - V.btnCraft:getWidth() - PAD)
    V.btnCraft:setY(h - V.detailH + 4)
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
