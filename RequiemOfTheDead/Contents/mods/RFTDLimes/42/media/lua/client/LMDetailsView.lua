-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMDetailsView - per-mod overrides for the selected zone. Two panels: who has
-- registered with Limes, and what they let you set (§11.3).
--
-- THIS IS THE EXTENSION SURFACE. Limes is not meant to know what Dirge, or
-- Reclamation, or somebody's own mod wants from a zone - it is meant to hold the
-- value, replicate it, persist it, and hand it back. A mod that calls
--
--     Limes.mods.register("MyMod", { label = "My Mod", description = "..." })
--     Limes.fields.register("MyMod", "myDial",
--         { type = "number", min = 0, max = 10, side = "server",
--           label = "My dial", help = "What it does." })
--
-- gets a heading in this list and a working control under it, with no edit to
-- this file and no edit to Limes. The registry has carried `owner` since M0;
-- what M4 added is the display half.
--
-- WHY IT IS A SEPARATE VIEW rather than more rows on the Zone Selector. The
-- properties cell there holds the policies that are true for a zone absent any
-- other mod - tier, priority, disabled, announce. Everything here is a mod's
-- opinion ABOUT that zone, it grows with every mod installed, and it is edited
-- rarely. Mixing them puts a fourteen-field Dirge table between an admin and the
-- tier they came to change.
--
-- LMCore IS LISTED, first (revised 2026-08-05). Its fields used to be a
-- properties cell under the Zone Selector's tree, and this view excluded them so
-- one dial had one home. That cell is gone: the tree needs the whole column once
-- zones nest, and the honest split turned out to be geometry on one tab and
-- policy on the other. So "Zone basics" is simply the first registrant in the
-- list, above Dirge and anything else installed - which is what it always was in
-- the registry.

if isServer() then return end

require "LMCore"
require "LMEdit"

LMDetailsView = LMDetailsView or {}

local ui       = nil
local activeId = nil     -- selected mod id
local forms    = {}      -- mod id -> DFForm (built once, on demand)

local LEFT_W = 232

local rebuildMods, refresh

-- ---------------------------------------------------------------------------
-- The mod list
-- ---------------------------------------------------------------------------

local ModList = ISScrollingListBox:derive("LMModList")

function ModList:doDrawItem(y, item, alt)
    local mo = item.item
    if not mo then return y + self.itemheight end
    local h = self.itemheight

    if mo.id == activeId then
        self:drawRect(0, y, self.width, h - 1, 0.55, 0.20, 0.35, 0.55)
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08)
    end

    self:drawText(mo.label, 6, y + 2, 0.92, 0.92, 0.92, 1, UIFont.Small)

    -- The count is the honest measure of what a mod contributes here, and an
    -- unregistered owner is marked rather than hidden: its dials still work, it
    -- just never told us what to call it.
    local badge = mo.count .. (mo.count == 1 and " field" or " fields")
    if not mo.registered then badge = badge .. "  (no label)" end
    local bw = getTextManager():MeasureStringX(UIFont.Small, badge)
    self:drawText(badge, self.width - bw - 8, y + 2, 0.62, 0.68, 0.75, 1, UIFont.Small)
    return y + h
end

function ModList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    self.selected = idx
    activeId = row.item.id
    refresh()
end

-- ---------------------------------------------------------------------------
-- Forms, one per mod, built the first time that mod is looked at
-- ---------------------------------------------------------------------------

local function formFor(panel, id)
    if forms[id] then return forms[id] end
    local info = Limes.mods.info(id)
    local f = LMFieldForm.new{
        owner = id,
        title = (info and info.label) or id,
        zone  = function() return LMEditView.selected() end,
        draft = function() return LMEditView.draft() end,
        onChange = function() LMEditView.refresh(); refresh() end,
    }
    -- attach() adds a hotspot child; done once per mod and kept, because a form
    -- rebuilt on every switch would drop its scroll position and any drag in
    -- flight. Hidden forms are switched off by visibility below.
    for _, el in ipairs(f:attach(panel)) do
        ui.formWidgets[#ui.formWidgets + 1] = el
        f._el = el
    end
    forms[id] = f
    return f
end

-- ---------------------------------------------------------------------------
-- Chrome
-- ---------------------------------------------------------------------------

rebuildMods = function()
    if not (ui and ui.list) then return end
    local mods = Limes.mods.list()
    DFKit.refillList(ui.list, function(box)
        for i = 1, #mods do
            box:addItem(mods[i].label, mods[i])
            if mods[i].id == activeId then box.selected = box:size() end
        end
    end)
    if not activeId and mods[1] then
        activeId = mods[1].id
        ui.list.selected = 1
    end
end

refresh = function()
    if not ui then return end
    local zone = LMEditView.selected()

    -- Only the active mod's form is visible, and visibility is what stops the
    -- others' hotspots eating clicks (the reason DFViews switches this way too).
    for id, f in pairs(forms) do
        if f._el then pcall(function() f._el:setVisible(id == activeId) end) end
    end

    local info = activeId and Limes.mods.info(activeId)
    ui.head:setName(zone
        and ((info and info.label or activeId or "?") .. "  -  " .. zone)
        or  "Select a zone on the Zone Selector tab first")

    local desc = info and info.description
    ui.desc:setName(desc or "")

    -- Say what could not be rendered rather than letting an admin conclude the
    -- store has no such field. Text and colour kinds are Core work (DFForm), not
    -- a patch to this panel.
    local skipped = activeId and forms[activeId] and LMFieldForm.skipped(forms[activeId]) or {}
    ui.note:setName(#skipped > 0
        and (#skipped .. " text field" .. (#skipped == 1 and "" or "s")
             .. " not editable here yet: " .. table.concat(skipped, ", "))
        or "")
end

-- ---------------------------------------------------------------------------
-- The DFViews contract
-- ---------------------------------------------------------------------------

function LMDetailsView.attach(panel)
    local C, w = DFKit.col, {}

    local list = ModList:new(0, 0, 10, 10)
    list:initialise(); list:instantiate()
    list.itemheight = 20
    list.drawBorder = true
    list.selected   = 0
    DFKit.well(list)
    local origRender = list.render
    list.render = function(self_)
        if origRender then origRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height,
                "No mods have registered fields")
        end
    end
    panel:addChild(list)
    w[#w + 1] = list

    local head = DFKit.label(panel, 0, 0, "")
    local desc = DFKit.label(panel, 0, 0, "", C.textDim)
    local note = DFKit.label(panel, 0, 0, "", C.warn)
    for _, l in ipairs({ head, desc, note }) do w[#w + 1] = l end

    ui = { list = list, head = head, desc = desc, note = note, formWidgets = {}, panel = panel }

    rebuildMods()
    -- Build every registered mod's form up front. Lazily would mean a form
    -- appearing mid-layout with no rect, and the set is small - one per mod that
    -- registered a field, not one per zone.
    for _, mo in ipairs(Limes.mods.list()) do formFor(panel, mo.id) end
    for _, el in ipairs(ui.formWidgets) do w[#w + 1] = el end

    refresh()
    return w
end

function LMDetailsView.layout(panel, x, y, w, h)
    if not ui then return end
    local m = DFKit.metrics
    local PAD = m.pad

    DFKit.sizeList(ui.list, x + PAD, y + PAD, LEFT_W, h - PAD * 2)

    local rx = x + PAD + LEFT_W + PAD
    local rw = math.max(120, (x + w) - rx - PAD)
    ui.head:setX(rx); ui.head:setY(y + PAD)
    ui.desc:setX(rx); ui.desc:setY(y + PAD + 20)
    ui.note:setX(rx); ui.note:setY(y + h - 20)

    local fy = y + PAD + 40
    local fh = math.max(60, (y + h) - fy - 24)
    for _, f in pairs(forms) do f:layout(rx, fy, rw, fh) end
end

function LMDetailsView.draw(el)
    local f = activeId and forms[activeId]
    if f then f:draw(el) end
end

-- Coming back to this view after editing zones elsewhere: the mod set can have
-- grown (a mod that registers on a later boot) and the selected zone almost
-- certainly changed.
function LMDetailsView.onShow()
    rebuildMods()
    refresh()
end

return LMDetailsView

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
