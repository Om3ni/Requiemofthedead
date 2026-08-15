-- SPDX-License-Identifier: GPL-3.0-or-later
-- WSGear - the Workshop's Gear sub-tab (client): your carried kit as a
-- maintenance dashboard.
--
-- WHAT QUALIFIES (owner, 2026-08-13): things in your inventory, equipped, and
-- hotbar - never the world, never containers you are not carrying - and only
-- lines the Workshop can DO something about: the item is fixable
-- (FixingManager knows a fix for it), or a loaded recipe crafts it (a
-- replacement path), or such a recipe exists but is unlearned (a learning
-- path). Everything else is noise here and stays in the normal inventory.
--
-- Sorted worst-condition-first, because "what is about to break" is the
-- question a maintenance surface answers.
--
-- CLICK ROUTING is the tab's contract: a line with known recipes lands on
-- the Craft pane filtered to them; known none but learnable some lands on
-- the Journal filtered to those recipes (grey rows, learning paths); a
-- fix-only line has no recipe to land on and says so in its columns instead.
-- The routing itself lives in WSTab.routeItem - this view only
-- collects and draws.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "DFKit"
require "Workshop/WSIndex"

WSGear = WSGear or {}
local V = WSGear

local PAD = 8

local function fS() return DFKit.font.small or UIFont.Small end
local function fh() return getTextManager():getFontHeight(fS()) end

-- ---------------------------------------------------------------------------
-- Collection. One pass over the four carry surfaces, deduped by item id
-- (a hotbar item is also in the inventory list; worn items are not).
-- ---------------------------------------------------------------------------
local function collect(player)
    local seen, rows = {}, {}

    local function consider(item, where)
        if not item then return end
        local id = item:getID()
        if seen[id] then return end
        seen[id] = true

        local full = item:getFullType()
        -- getFixes NPEs on any loaded fixing script with no Require line
        -- (Fixing.require stays null) - the guard is load-bearing.
        local okF, f = pcall(FixingManager.getFixes, item)
        local fixes = (okF and f and f:size()) or 0
        local known, learnable = 0, 0
        for _, rec in ipairs(WSIndex.forOutput(full)) do
            if WSIndex.known(player, rec) then known = known + 1
            else learnable = learnable + 1 end
        end
        if fixes == 0 and known == 0 and learnable == 0 then return end

        local cond, condMax = nil, (item:getConditionMax() or 0)
        if condMax and condMax > 0 then
            cond = item:getCondition()
        end
        rows[#rows + 1] = {
            item = item, full = full,
            disp = item:getName() or full,
            where = where,
            cond = cond, condMax = condMax,
            fixes = fixes, known = known, learnable = learnable,
        }
    end

    local worn = player:getWornItems()
    for i = 0, (worn and worn:size() or 0) - 1 do
        consider(worn:getItemByIndex(i), "Worn")
    end
    consider(player:getPrimaryHandItem(), "Hands")
    consider(player:getSecondaryHandItem(), "Hands")
    local att = player:getAttachedItems()
    for i = 0, (att and att:size() or 0) - 1 do
        consider(att:getItemByIndex(i), "Hotbar")
    end
    local all = player:getInventory():getAllEvalRecurse(function() return true end)
    for i = 0, all:size() - 1 do consider(all:get(i), "Carried") end

    -- Worst condition first; condition-less lines (crafting targets that
    -- never wear) after, alphabetical.
    table.sort(rows, function(a, b)
        local ap = (a.cond and a.condMax > 0) and (a.cond / a.condMax) or 2
        local bp = (b.cond and b.condMax > 0) and (b.cond / b.condMax) or 2
        if ap ~= bp then return ap < bp end
        return a.disp < b.disp
    end)
    return rows
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function cols(w)
    return {
        name  = 8,
        where = w - 330,
        cond  = w - 260,
        fix   = w - 190,
        rec   = w - 130,
    }
end

local function condColour(row)
    local C = DFKit.col
    if not row.cond or row.condMax <= 0 then return C.textDim end
    local p = row.cond / row.condMax
    if p < 0.3 then return C.danger end
    if p < 0.65 then return C.warn end
    return C.ok
end

local function drawRow(self, y, item, alt)
    local row = item.item
    local h = self.itemheight
    local C = DFKit.col
    local c = cols(self:getWidth())
    if alt then self:drawRect(0, y, self:getWidth(), h, 0.06, 1, 1, 1) end
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), h, 0.12, C.accent.r, C.accent.g, C.accent.b)
    end

    self:drawText(DFKit.fitText(row.disp, self.font, c.where - c.name - 10),
        c.name, y + 3, 0.9, 0.9, 0.9, 1, self.font)
    self:drawText(row.where, c.where, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 1, self.font)

    local cc = condColour(row)
    local condStr = (row.cond and row.condMax > 0)
        and (tostring(row.cond) .. "/" .. tostring(row.condMax)) or "-"
    self:drawText(condStr, c.cond, y + 3, cc.r, cc.g, cc.b, 1, self.font)

    if row.fixes > 0 then
        self:drawText("yes", c.fix, y + 3, C.ok.r, C.ok.g, C.ok.b, 1, self.font)
    else
        self:drawText("-", c.fix, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 0.6, self.font)
    end

    if row.known > 0 then
        self:drawText(row.known .. " known", c.rec, y + 3, C.ok.r, C.ok.g, C.ok.b, 1, self.font)
    elseif row.learnable > 0 then
        self:drawText(row.learnable .. " learnable", c.rec, y + 3, C.warn.r, C.warn.g, C.warn.b, 1, self.font)
    else
        self:drawText("-", c.rec, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 0.6, self.font)
    end
    return y + h
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------
local Root = ISPanel:derive("WSGearRoot")

function Root:prerender()
    ISPanel.prerender(self)
    local C = DFKit.col
    local f = fS()
    self:drawText("Carried gear the Workshop can help with - worst condition first. Click a line for its recipes.",
        PAD, 4, C.textDim.r, C.textDim.g, C.textDim.b, 1, f)
    local hy = V.headerH - fh() - 2
    local c = cols(self.width)
    self:drawText("Item", c.name, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Where", c.where, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Cond", c.cond, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Fixable", c.fix, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Recipes", c.rec, hy, 0.7, 0.7, 0.7, 1, f)
    if V.list and #V.list.items == 0 then
        DFKit.drawEmpty(self, 0, V.headerH, self.width, self.height - V.headerH,
            "Nothing you carry is fixable or craftable right now.")
    end
end

function V.create(parent, w, h)
    V.root = Root:new(0, 0, w, h)
    V.root.background = false
    V.root:initialise()
    V.root:instantiate()
    parent:addChild(V.root)

    V.list = ISScrollingListBox:new(0, 0, w, h)
    V.list:initialise()
    V.list.font = fS()
    V.list.itemheight = fh() + 6
    V.list.drawBorder = true
    V.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    V.list.doDrawItem = drawRow
    -- Click = route. Instance wrap over the vanilla handler so selection
    -- bookkeeping stays the engine's.
    local base = V.list.onMouseDown
    V.list.onMouseDown = function(self, x, y)
        base(self, x, y)
        local it = self.items and self.items[self.selected]
        if it and WSTab and WSTab.routeItem then
            WSTab.routeItem(it.item)
        end
    end
    V.root:addChild(V.list)

    V.btnRefresh = DFKit.button(V.root, 0, 0, 80, "Refresh", V, function() V.populate() end)
    V.layout(w, h)
end

function V.layout(w, h)
    V.headerH = fh() * 2 + 12
    V.root:setWidth(w); V.root:setHeight(h)
    DFKit.sizeList(V.list, 0, V.headerH, w, h - V.headerH - PAD)
    if V.btnRefresh then
        V.btnRefresh:setX(w - V.btnRefresh:getWidth() - PAD)
        V.btnRefresh:setY(0)
    end
end

function V.populate()
    local player = getPlayer()
    if not player or not V.list then return end
    local rows = collect(player)
    DFKit.refillList(V.list, function(box)
        for _, row in ipairs(rows) do box:addItem(row.disp, row) end
    end)
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
