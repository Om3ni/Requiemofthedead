-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMProfilesView - "Profiles": named rulesets, their dials, their loot rules.
--
-- The S6 panel of the 2026-08-26 redesign (prototype A5): profiles on the
-- left with their stamped-on count, the selected profile's fields on the
-- right through the shared LMFieldForm (phases - the activation gate - lives
-- there as an ordinary registered field), and under them the LOOT RULES
-- widget with the kit treatment the owner asked for: [+ Item] opens the
-- live-narrowing DFItemQuery search every kit surface already uses, and
-- [+ Category] the same flow over the CLOSED vocabulary LMLootShared derives
-- from the script registry - free text cannot invent a category that matches
-- nothing.
--
-- THE ROWS ARE A VIEW OVER ONE FIELD. The store holds lootReduce as a single
-- canonical string ("Base.Axe=25; cat:Ammo=50"); this widget parses it to
-- rows (Limes.parseLootReduce) and writes the whole string back
-- (Limes.formatLootReduce) on every mutation - so the field keeps its
-- whole-value override semantics ("nearest source wins wholesale") and rides
-- sync, draft, diff and the .ini as ordinary cargo. Click a row's percent to
-- retype it; x removes the rule.
--
-- EDITS GO TO THE SHARED DRAFT (one draft, one Save), same as the Tiers panel.

if isServer() then return end

require "LMCore"
require "LMEdit"
require "LMFieldForm"
require "LMLootShared"
require "DFEntry"
require "DFItemQuery"

LMProfilesView = LMProfilesView or {}

local ui         = nil
local activeProf = nil
local form       = nil

local LEFT_W = 232

local rebuildList, rebuildLoot, refresh

local function draft() return LMEditView.draft() end

-- Zones this profile is stamped on, against the DRAFT.
local function stampedOn(prof)
    local d = draft()
    if not d then return 0 end
    local n = 0
    for _, name in ipairs(d:names()) do
        for _, p in ipairs(d:profilesOf(name)) do
            if p == prof then n = n + 1 break end
        end
    end
    return n
end

-- Profile records first-class, legacy kind-less templates after them - the
-- same population profileCandidates offers, so the panel and the picker never
-- disagree about what counts as a profile.
local function profileNames()
    local d = draft()
    if not d then return {} end
    local kinded, legacy = {}, {}
    for _, name in ipairs(d:names()) do
        local rec = d:get(name)
        if rec.kind == "profile" then
            kinded[#kinded + 1] = name
        elseif rec.kind == nil and name ~= "_default"
            and (not rec.rects or #rec.rects == 0) then
            legacy[#legacy + 1] = name
        end
    end
    for _, n in ipairs(legacy) do kinded[#kinded + 1] = n end
    return kinded
end

-- ---------------------------------------------------------------------------
-- The profile list
-- ---------------------------------------------------------------------------

local ProfList = ISScrollingListBox:derive("LMProfilePanelList")

function ProfList:doDrawItem(y, item, alt)
    local p = item.item
    if not p then return y + self.itemheight end
    local h = self.itemheight

    if p.name == activeProf then
        self:drawRect(0, y, self.width, h - 1, 0.55, 0.20, 0.35, 0.55)
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08)
    end

    self:drawText(p.name, 6, y + 3, 0.92, 0.92, 0.92, 1, UIFont.Small)

    local tail = p.used .. (p.used == 1 and " zone" or " zones")
    if p.legacy then tail = "legacy  -  " .. tail end
    if p.phases then tail = "~  " .. tail end
    local tw = getTextManager():MeasureStringX(UIFont.Small, tail)
    self:drawText(tail, self.width - tw - 8, y + 3, 0.62, 0.68, 0.75, 1, UIFont.Small)
    return y + h
end

function ProfList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    self.selected = idx
    activeProf = row.item.name
    refresh()
end

function ProfList:onRightMouseUp(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    activeProf = row.item.name
    refresh()
    local name = row.item.name
    local context = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    context:addOption("Rename...", nil, function()
        local d = draft()
        if not d then return end
        DFEntry.show{
            title = "Rename profile " .. name, value = name,
            rule = "Letters, digits, _ - . only. Every zone applying this"
                .. " profile repoints in the same step.",
            maxLen = 48,
            validate = function(s)
                local why = LMEdit.nameProblem(s)
                if why then return false, why end
                if s ~= name and d:get(s) then return false, "'" .. s .. "' already exists." end
                return true
            end,
            onCommit = function(s)
                local ok, moved = d:rename(name, s)
                if not ok then print("[Limes] " .. tostring(moved)); return end
                activeProf = s
                LMEditView.refresh()
                refresh()
            end,
        }
    end)
    context:addOption("Delete...", nil, function()
        local d = draft()
        if not d then return end
        local n = stampedOn(name)
        local msg = "Delete profile '" .. name .. "' from the draft?"
        if n > 0 then
            msg = msg .. "\n\n" .. n .. " zone" .. (n == 1 and "" or "s")
                .. " appl" .. (n == 1 and "ies" or "y") .. " it and will lose its rules."
        end
        msg = msg .. "\n\nNothing leaves this machine until you press Save."
        local function go()
            d:remove(name)
            if activeProf == name then activeProf = nil end
            LMEditView.refresh()
            refresh()
        end
        if DFConfirm and DFConfirm.ask then DFConfirm.ask(msg, go) else go() end
    end)
end

-- ---------------------------------------------------------------------------
-- The loot rules widget
-- ---------------------------------------------------------------------------

local LootList = ISScrollingListBox:derive("LMLootRules")

function LootList:doDrawItem(y, item, alt)
    local it = item.item
    if not it then return y + self.itemheight end
    local h = self.itemheight
    if alt then self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08) end

    local label
    if it.kind == "category" then
        label = "Category: " .. it.name
        self:drawText(label, 6, y + 3, 0.79, 0.71, 0.47, 1, UIFont.Small)
    else
        label = it.disp and (it.disp .. "   (" .. it.name .. ")") or it.name
        self:drawText(label, 6, y + 3, 0.92, 0.92, 0.92, 1, UIFont.Small)
    end

    local pct = "-" .. it.pct .. "%"
    local pw = getTextManager():MeasureStringX(UIFont.Small, pct)
    self:drawText(pct, self.width - pw - 34, y + 3, 0.85, 0.55, 0.45, 1, UIFont.Small)
    local xw = getTextManager():MeasureStringX(UIFont.Small, "x")
    self:drawText("x", self.width - xw - 10, y + 3, 0.62, 0.68, 0.75, 1, UIFont.Small)
    return y + h
end

-- Rebuild the field from rows - the one write path, so every mutation goes
-- through the same canonical formatter the exporter uses.
local function writeRules(entries)
    local d = draft()
    if not (d and activeProf) then return end
    local s = Limes.formatLootReduce(entries)
    d:setField(activeProf, "lootReduce", s ~= "" and s or nil)
    LMEditView.refresh()
    refresh()
end

local function currentRules()
    local d = draft()
    local rec = d and activeProf and d:get(activeProf) or nil
    local lr = rec and rec.fields and rec.fields.lootReduce
    if not lr or lr == "" then return {} end
    return (Limes.parseLootReduce(lr))
end

function LootList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item and activeProf) then return end
    local entries = currentRules()
    local e = entries[idx]
    if not e then return end
    if x > self.width - 24 then
        table.remove(entries, idx)
        writeRules(entries)
        return
    end
    -- The row is the dial: click re-opens the percent.
    DFEntry.show{
        title = "Remove how much of "
            .. (e.kind == "category" and ("category " .. e.name) or e.name) .. "?",
        value = tostring(e.pct),
        rule  = "Percent REMOVED from containers, 0-100.",
        maxLen = 3,
        validate = function(s)
            local n = tonumber(s)
            if not n or n < 0 or n > 100 or n ~= math.floor(n) then
                return false, "A whole number, 0-100."
            end
            return true
        end,
        onCommit = function(s)
            e.pct = tonumber(s)
            writeRules(entries)
        end,
    }
end

local function addItemRule()
    if not activeProf then return end
    DFEntry.show{
        title = "Reduce which item in " .. activeProf .. "?",
        value = "",
        rule  = "Type to search every item the server knows - modded included."
            .. " The rule starts at 50% removed; click it after to tune.",
        maxLen = 64,
        -- ONE search for every item surface (DFItemQuery, in Core) - the same
        -- ranking the kit editor and Add Item use, so "nails finds it there
        -- but not here" cannot happen.
        suggest = function(q)
            local out = {}
            for _, r in ipairs(DFItemQuery.search(q, 8)) do
                out[#out + 1] = { value = r.full, label = r.disp .. "   " .. r.full }
            end
            return out
        end,
        validate = function(s)
            if type(s) ~= "string" or s == "" then return false, "An item type is required." end
            if not s:find(".", 1, true) then
                return false, "Needs its module - 'Base.Axe', not '" .. s .. "'."
            end
            if not s:match("^[%w_%.]+$") then
                return false, "Item types take letters, digits, _ and . only."
            end
            return true
        end,
        onCommit = function(s)
            local entries = currentRules()
            for _, e in ipairs(entries) do
                if e.kind == "item" and e.name == s then return end
            end
            entries[#entries + 1] = { kind = "item", name = s, pct = 50 }
            writeRules(entries)
        end,
    }
end

local function addCategoryRule()
    if not activeProf then return end
    DFEntry.show{
        title = "Reduce which category in " .. activeProf .. "?",
        value = "",
        rule  = "A CLOSED list - the categories items actually declare, modded"
            .. " included - so a typo cannot write a rule that matches nothing."
            .. " Starts at 50% removed; click it after to tune.",
        maxLen = 48,
        suggest = function(q)
            local out = {}
            local ql = tostring(q or ""):lower()
            for _, c in ipairs(LMLootShared.categories()) do
                if ql == "" or c:lower():find(ql, 1, true) then
                    out[#out + 1] = c
                end
            end
            return out
        end,
        validate = function(s)
            if not LMLootShared.isCategory(s) then
                return false, "'" .. tostring(s) .. "' is not a category any item"
                    .. " declares - pick from the suggestions."
            end
            return true
        end,
        onCommit = function(s)
            local entries = currentRules()
            for _, e in ipairs(entries) do
                if e.kind == "category" and e.name == s then return end
            end
            entries[#entries + 1] = { kind = "category", name = s, pct = 50 }
            writeRules(entries)
        end,
    }
end

-- Display names for item rows, resolved through DFItemQuery's cache by
-- searching for the exact type - a few string.finds per rebuild, not a
-- registry walk.
local function dispFor(full)
    local hits = DFItemQuery.search(full, 1)
    local h = hits and hits[1]
    if h and h.full == full then return h.disp end
    return nil
end

rebuildLoot = function()
    if not (ui and ui.lootList) then return end
    local entries = currentRules()
    DFKit.refillList(ui.lootList, function(box)
        for _, e in ipairs(entries) do
            box:addItem(e.name, { kind = e.kind, name = e.name, pct = e.pct,
                                  disp = e.kind == "item" and dispFor(e.name) or nil })
        end
    end)
    local on = activeProf ~= nil
    if ui.addItemBtn then ui.addItemBtn.enable = on end
    if ui.addCatBtn then ui.addCatBtn.enable = on end
end

-- ---------------------------------------------------------------------------
-- Actions and chrome
-- ---------------------------------------------------------------------------

local function newProfile()
    local d = draft()
    if not d then return end
    DFEntry.show{
        title = "New profile",
        value = "",
        rule  = "Letters, digits, _ - . only. A profile is a named ruleset;"
            .. " stamp it on zones with the Zone Selector's Apply Profile menu.",
        maxLen = 48,
        validate = function(s)
            local why = LMEdit.nameProblem(s)
            if why then return false, why end
            if d:get(s) then return false, "'" .. s .. "' already exists." end
            return true
        end,
        onCommit = function(s)
            d:create(s, { kind = "profile", fields = {} })
            activeProf = s
            LMEditView.refresh()
            refresh()
        end,
    }
end

rebuildList = function()
    if not (ui and ui.list) then return end
    local d = draft()
    DFKit.refillList(ui.list, function(box)
        if not d then return end
        for _, name in ipairs(profileNames()) do
            local rec = d:get(name)
            local phases = rec.fields and rec.fields.phases
            box:addItem(name, {
                name = name,
                used = stampedOn(name),
                legacy = rec.kind == nil,
                phases = (phases and phases ~= "") and phases or nil,
            })
            if name == activeProf then box.selected = box:size() end
        end
    end)
end

refresh = function()
    if not ui then return end
    local d = draft()
    if activeProf and (not d or not d:get(activeProf)) then activeProf = nil end
    if not activeProf then activeProf = profileNames()[1] end
    rebuildList()
    rebuildLoot()
    ui.head:setName(activeProf
        and (activeProf .. "  -  stamped on " .. stampedOn(activeProf) .. " zone"
             .. (stampedOn(activeProf) == 1 and "" or "s")
             .. "  -  loot rules here replace any from weaker sources")
        or "No profiles in the store - New Profile makes one")
    local n, errs = LMEditView.draftCounts()
    ui.saveBtn.enable   = (n > 0 and errs == 0)
    ui.revertBtn.enable = (n > 0)
end

-- ---------------------------------------------------------------------------
-- The DFViews contract
-- ---------------------------------------------------------------------------

function LMProfilesView.attach(panel)
    local w = {}

    local list = ProfList:new(0, 0, 10, 10)
    list:initialise(); list:instantiate()
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    list.selected   = 0
    DFKit.well(list)
    local origRender = list.render
    list.render = function(self_)
        if origRender then origRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height, "No profiles in the store")
        end
    end
    panel:addChild(list)
    w[#w + 1] = list

    local newBtn = DFKit.button(panel, 0, 0, 96, "New Profile", panel, newProfile, "action",
        { tooltip = "Create a named ruleset - no spawns, no safehouse, reduced"
                 .. " loot, whatever the place needs - then stamp it on zones"
                 .. " from the Zone Selector's right-click menu." })
    local saveBtn = DFKit.button(panel, 0, 0, 118, "Save to server", panel,
        function() LMEditView.saveDraft() end, "primary",
        { tooltip = "One draft across every panel: this saves ALL unsaved zone,"
                 .. " tier and profile edits in one command." })
    local revertBtn = DFKit.button(panel, 0, 0, 64, "Revert", panel,
        function() LMEditView.revertDraft(); refresh() end, "action",
        { tooltip = "Throw the whole draft away - zone, tier and profile edits"
                 .. " alike - and start from the server's state." })
    w[#w + 1] = newBtn; w[#w + 1] = saveBtn; w[#w + 1] = revertBtn

    local head = DFKit.label(panel, 0, 0, "")
    w[#w + 1] = head

    form = LMFieldForm.new{
        groups = true,
        title  = "Profile",
        zone   = function() return activeProf end,
        draft  = draft,
        onChange = function() LMEditView.refresh(); refresh() end,
    }
    for _, el in ipairs(form:attach(panel)) do w[#w + 1] = el end

    local lootHead = DFKit.label(panel, 0, 0, "Loot rules")
    local lootNote = DFKit.label(panel, 0, 0,
        "Each rule removes a share of an item or category from containers."
        .. " The nearest source that sets rules replaces the whole list.",
        DFKit.col.textDim)
    w[#w + 1] = lootHead; w[#w + 1] = lootNote

    local addItemBtn = DFKit.button(panel, 0, 0, 84, "+ Item...", panel,
        addItemRule, "action",
        { tooltip = "Search every item the server knows - type and the list"
                 .. " narrows. The same search the kit editor uses." })
    local addCatBtn = DFKit.button(panel, 0, 0, 110, "+ Category...", panel,
        addCategoryRule, "action",
        { tooltip = "Pick from the categories items actually declare - a closed"
                 .. " list, so a typo cannot write a rule that matches nothing." })
    w[#w + 1] = addItemBtn; w[#w + 1] = addCatBtn

    local lootList = LootList:new(0, 0, 10, 10)
    lootList:initialise(); lootList:instantiate()
    lootList.itemheight = DFKit.rowHeight()
    lootList.drawBorder = true
    lootList.selected   = 0
    DFKit.well(lootList)
    local origLootRender = lootList.render
    lootList.render = function(self_)
        if origLootRender then origLootRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height,
                "No loot rules - containers here fill as normal")
        end
    end
    panel:addChild(lootList)
    w[#w + 1] = lootList

    ui = { list = list, newBtn = newBtn, saveBtn = saveBtn, revertBtn = revertBtn,
           head = head, lootHead = lootHead, lootNote = lootNote,
           addItemBtn = addItemBtn, addCatBtn = addCatBtn, lootList = lootList }

    refresh()
    return w
end

function LMProfilesView.layout(panel, x, y, w, h)
    if not ui then return end
    local m = DFKit.metrics
    local PAD, BTN, GAP = m.pad, m.btnH, 4

    local tx, ty = x + PAD, y + PAD
    ui.newBtn:setX(tx); ui.newBtn:setY(ty)
    local saveX   = x + w - PAD - ui.saveBtn:getWidth()
    local revertX = saveX - GAP - ui.revertBtn:getWidth()
    ui.saveBtn:setX(saveX);     ui.saveBtn:setY(ty)
    ui.revertBtn:setX(revertX); ui.revertBtn:setY(ty)

    local bodyY = ty + BTN + PAD
    local bodyH = math.max(120, (y + h) - bodyY - PAD)

    DFKit.sizeList(ui.list, x + PAD, bodyY, LEFT_W, bodyH)

    local rx = x + PAD + LEFT_W + PAD
    local rw = math.max(120, (x + w) - rx - PAD)
    local lh = getTextManager():getFontHeight(DFKit.font.small or UIFont.Small) + 4

    ui.head:setX(rx); ui.head:setY(bodyY)

    -- The loot block claims the bottom of the column; the field form scrolls
    -- in whatever is left between the heading and it.
    local lootListH = math.min(DFKit.rowHeight() * 5 + 4, math.floor(bodyH / 3))
    local lootY = (y + h) - PAD - lootListH - BTN - GAP - lh * 2
    ui.lootHead:setX(rx);  ui.lootHead:setY(lootY)
    ui.lootNote:setX(rx);  ui.lootNote:setY(lootY + lh)
    ui.addItemBtn:setX(rx); ui.addItemBtn:setY(lootY + lh * 2)
    ui.addCatBtn:setX(rx + ui.addItemBtn:getWidth() + GAP)
    ui.addCatBtn:setY(lootY + lh * 2)
    DFKit.sizeList(ui.lootList, rx, lootY + lh * 2 + BTN + GAP, rw, lootListH)

    local fy = bodyY + lh + 4
    local fh = math.max(60, lootY - fy - PAD)
    if form then form:layout(rx, fy, rw, fh) end
end

-- DFViews contract shims - identical to every other view's by construction
-- (the contract's one line around this module's private state; nothing a
-- promotion could capture). See LMTiersView's note; baseline raised together.
function LMProfilesView.draw(el)
    if form then form:draw(el) end
end

function LMProfilesView.onShow()
    refresh()
end

return LMProfilesView

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
