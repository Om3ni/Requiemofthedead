-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMTiersView - "Difficulty Tiers": the ladder, one rung's dials, its moon.
--
-- The S5 panel of the 2026-08-26 redesign, shaped by the signed-off prototype
-- (docs/limes-editor-mockup.html, A4): the rungs on the left ordered by rank
-- with their numbered badges, the selected rung's dials on the right through
-- the same LMFieldForm every other surface uses - a tier record is terminal,
-- so the form's effective() shows its OWN fields and nothing else - and under
-- them the MOON OVERLAY: the phase gate and the sparse list of dials that
-- beat the base ones while the moon is in phase. One phase mechanism
-- (Limes.phasesActive); this panel is only UI over it.
--
-- EDITS GO TO THE SHARED DRAFT (LMEditView's - one draft, one Save), and this
-- panel carries its own Save/Revert pair calling into it, so work started
-- here never needs a trip back to the Zone Selector to land.

if isServer() then return end

require "LMCore"
require "LMEdit"
require "LMFieldForm"
require "DFEntry"

LMTiersView = LMTiersView or {}

local ui         = nil
local activeTier = nil
local form       = nil

local LEFT_W = 232

local rebuildList, rebuildMoon, refresh

local function draft() return LMEditView.draft() end

-- Zones standing on a rung, through the resolved slot - the "Used by N zones"
-- footer the prototype carries, computed against the DRAFT so an unsaved
-- retier counts immediately.
local function usedBy(tier)
    local d = draft()
    if not d then return 0 end
    local n = 0
    for _, name in ipairs(d:names()) do
        local rec = d:get(name)
        if rec.kind == nil and d:effectiveTier(name) == tier then n = n + 1 end
    end
    return n
end

local function tierNames()
    local d = draft()
    if not d then return {} end
    local out = {}
    for _, name in ipairs(d:names()) do
        if d:get(name).kind == "tier" then out[#out + 1] = name end
    end
    table.sort(out, function(a, b)
        local ra = tonumber(d:get(a).fields and d:get(a).fields.rank) or 99
        local rb = tonumber(d:get(b).fields and d:get(b).fields.rank) or 99
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- The ladder list
-- ---------------------------------------------------------------------------

local TierList = ISScrollingListBox:derive("LMTierList")

function TierList:doDrawItem(y, item, alt)
    local t = item.item
    if not t then return y + self.itemheight end
    local h = self.itemheight

    if t.name == activeTier then
        self:drawRect(0, y, self.width, h - 1, 0.55, 0.20, 0.35, 0.55)
    elseif alt then
        self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08)
    end

    -- The numbered badge, the prototype's 1..5. A rung with no rank shows "-"
    -- rather than pretending an order it does not have.
    local badge = t.rank and tostring(t.rank) or "-"
    self:drawRectBorder(6, y + 2, h - 5, h - 5, 0.6, 0.44, 0.73, 0.89)
    local bw = getTextManager():MeasureStringX(UIFont.Small, badge)
    self:drawText(badge, 6 + math.floor((h - 5 - bw) / 2), y + 3,
        0.44, 0.73, 0.89, 1, UIFont.Small)

    self:drawText(t.name, h + 8, y + 3, 0.92, 0.92, 0.92, 1, UIFont.Small)

    local tail = t.used .. (t.used == 1 and " zone" or " zones")
    if t.moon then tail = tail .. "  ~" end
    local tw = getTextManager():MeasureStringX(UIFont.Small, tail)
    self:drawText(tail, self.width - tw - 8, y + 3, 0.62, 0.68, 0.75, 1, UIFont.Small)
    return y + h
end

function TierList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    self.selected = idx
    activeTier = row.item.name
    refresh()
end

function TierList:onRightMouseUp(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    activeTier = row.item.name
    refresh()
    local name = row.item.name
    local context = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    context:addOption("Rename...", nil, function()
        local d = draft()
        if not d then return end
        DFEntry.show{
            title = "Rename tier " .. name, value = name,
            rule = "Letters, digits, _ - . only. Every zone standing on this"
                .. " rung repoints in the same step.",
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
                activeTier = s
                LMEditView.refresh()
                refresh()
            end,
        }
    end)
    context:addOption("Delete...", nil, function()
        local d = draft()
        if not d then return end
        local n = usedBy(name)
        local msg = "Delete tier '" .. name .. "' from the draft?"
        if n > 0 then
            msg = msg .. "\n\n" .. n .. " zone" .. (n == 1 and "" or "s")
                .. " stand" .. (n == 1 and "s" or "") .. " on it and will lose its dials."
        end
        msg = msg .. "\n\nNothing leaves this machine until you press Save."
        local function go()
            d:remove(name)
            if activeTier == name then activeTier = nil end
            LMEditView.refresh()
            refresh()
        end
        if DFConfirm and DFConfirm.ask then DFConfirm.ask(msg, go) else go() end
    end)
end

-- ---------------------------------------------------------------------------
-- The moon overlay block - the gate, and the sparse dials under it
-- ---------------------------------------------------------------------------

local MoonList = ISScrollingListBox:derive("LMMoonList")

function MoonList:doDrawItem(y, item, alt)
    local it = item.item
    if not it then return y + self.itemheight end
    local h = self.itemheight
    if alt then self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08) end
    self:drawText(it.key .. " = " .. tostring(it.value), 6, y + 3,
        0.92, 0.92, 0.92, 1, UIFont.Small)
    local xw = getTextManager():MeasureStringX(UIFont.Small, "x")
    self:drawText("x", self.width - xw - 10, y + 3, 0.62, 0.68, 0.75, 1, UIFont.Small)
    return y + h
end

function MoonList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item and activeTier) then return end
    local d = draft()
    if not d then return end
    if x > self.width - 24 then
        d:setMoonField(activeTier, row.item.key, nil)
        LMEditView.refresh()
        refresh()
        return
    end
    -- Anywhere else on the row re-opens the value entry - the row IS the dial.
    local key = row.item.key
    DFEntry.show{
        title = "Moon value for " .. key,
        value = tostring(row.item.value),
        rule  = "The value this dial takes while the moon is in phase."
            .. " Empty removes the override.",
        maxLen = 96,
        onCommit = function(s)
            d:setMoonField(activeTier, key, s ~= "" and s or nil)
            LMEditView.refresh()
            refresh()
        end,
    }
end

local function setPhases()
    local d = draft()
    if not (d and activeTier) then return end
    local rec = d:get(activeTier)
    DFEntry.show{
        title = "Moon phases for " .. activeTier,
        value = (rec.moon and rec.moon.phases) or "",
        rule  = "Comma list: new, waxing_crescent, first_quarter, waxing_gibbous,"
            .. " full, waning_gibbous, last_quarter, waning_crescent - or waxing /"
            .. " waning, or 0-7. Empty means the overlay always applies.",
        maxLen = 96,
        onCommit = function(s)
            d:setMoonPhases(activeTier, s)
            LMEditView.refresh()
            refresh()
        end,
    }
end

local function addOverride()
    local d = draft()
    if not (d and activeTier) then return end
    DFEntry.show{
        title = "Add moon override to " .. activeTier,
        value = "",
        rule  = "The field this rung changes while the moon is in phase -"
            .. " dirgeSpawnChance, zeds, any registered dial.",
        maxLen = 64,
        suggest = function(q)
            local out = {}
            local ql = tostring(q or ""):lower()
            for _, s in ipairs(Limes.fields.list()) do
                if ql == "" or s.name:lower():find(ql, 1, true) then
                    out[#out + 1] = { value = s.name, label = s.name
                        .. (s.label and ("  -  " .. s.label) or "") }
                end
            end
            return out
        end,
        validate = function(s)
            local why = LMEdit.keyProblem(s)
            if why then return false, why end
            return true
        end,
        onCommit = function(key)
            DFEntry.show{
                title = "Moon value for " .. key,
                value = "",
                rule  = "The value " .. key .. " takes while the moon is in phase.",
                maxLen = 96,
                onCommit = function(v)
                    if v == "" then return end
                    d:setMoonField(activeTier, key, v)
                    LMEditView.refresh()
                    refresh()
                end,
            }
        end,
    }
end

rebuildMoon = function()
    if not (ui and ui.moonList) then return end
    local d = draft()
    local rec = d and activeTier and d:get(activeTier) or nil
    DFKit.refillList(ui.moonList, function(box)
        if not (rec and rec.moon) then return end
        local keys = {}
        for k in pairs(rec.moon.fields or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            box:addItem(k, { key = k, value = rec.moon.fields[k] })
        end
    end)
    if ui.phasesBtn then
        local ph = rec and rec.moon and rec.moon.phases
        ui.phasesBtn:setTitle("Phases: " .. ((ph and ph ~= "") and ph or "(always)"))
        ui.phasesBtn.enable = activeTier ~= nil
    end
    if ui.addMoonBtn then ui.addMoonBtn.enable = activeTier ~= nil end
end

-- ---------------------------------------------------------------------------
-- Actions and chrome
-- ---------------------------------------------------------------------------

local function newTier()
    local d = draft()
    if not d then return end
    DFEntry.show{
        title = "New tier",
        value = "",
        rule  = "Letters, digits, _ - . only. It joins the ladder after the"
            .. " current top rung; drag zones onto it with Set Tier.",
        maxLen = 48,
        validate = function(s)
            local why = LMEdit.nameProblem(s)
            if why then return false, why end
            if d:get(s) then return false, "'" .. s .. "' already exists." end
            return true
        end,
        onCommit = function(s)
            local top = 0
            for _, tn in ipairs(tierNames()) do
                local r = tonumber(d:get(tn).fields and d:get(tn).fields.rank)
                if r and r > top then top = r end
            end
            d:create(s, { kind = "tier", fields = { rank = top + 1 } })
            activeTier = s
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
        for _, name in ipairs(tierNames()) do
            local rec = d:get(name)
            box:addItem(name, {
                name = name,
                rank = tonumber(rec.fields and rec.fields.rank),
                used = usedBy(name),
                moon = rec.moon ~= nil,
            })
            if name == activeTier then box.selected = box:size() end
        end
    end)
end

refresh = function()
    if not ui then return end
    local d = draft()
    if activeTier and (not d or not d:get(activeTier)
        or d:get(activeTier).kind ~= "tier") then
        activeTier = nil
    end
    if not activeTier then
        local first = tierNames()[1]
        activeTier = first
    end
    rebuildList()
    rebuildMoon()
    ui.head:setName(activeTier
        and (activeTier .. "  -  used by " .. usedBy(activeTier) .. " zone"
             .. (usedBy(activeTier) == 1 and "" or "s"))
        or "No tiers in the store - New Tier makes one")
    local n, errs = LMEditView.draftCounts()
    ui.saveBtn.enable   = (n > 0 and errs == 0)
    ui.revertBtn.enable = (n > 0)
end

-- ---------------------------------------------------------------------------
-- The DFViews contract
-- ---------------------------------------------------------------------------

function LMTiersView.attach(panel)
    local w = {}

    local list = TierList:new(0, 0, 10, 10)
    list:initialise(); list:instantiate()
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    list.selected   = 0
    DFKit.well(list)
    local origRender = list.render
    list.render = function(self_)
        if origRender then origRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height, "No tiers in the store")
        end
    end
    panel:addChild(list)
    w[#w + 1] = list

    local newBtn = DFKit.button(panel, 0, 0, 84, "New Tier", panel, newTier, "action",
        { tooltip = "Add a rung to the ladder. Five ship (Newcomer to IDDQL);"
                 .. " the ladder is yours to extend." })
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
        title  = "Tier",
        zone   = function() return activeTier end,
        draft  = draft,
        onChange = function() LMEditView.refresh(); refresh() end,
    }
    for _, el in ipairs(form:attach(panel)) do w[#w + 1] = el end

    local moonHead = DFKit.label(panel, 0, 0, "Moon overlay")
    local moonNote = DFKit.label(panel, 0, 0,
        "While the moon is in the phases below, these dials beat the tier's own.",
        DFKit.col.textDim)
    w[#w + 1] = moonHead; w[#w + 1] = moonNote

    local phasesBtn = DFKit.button(panel, 0, 0, 190, "Phases: (always)", panel,
        setPhases, "action",
        { tooltip = "The overlay's gate - the SAME phase mechanism profiles use,"
                 .. " so 'what is active tonight' has one answer everywhere." })
    local addMoonBtn = DFKit.button(panel, 0, 0, 110, "Add override", panel,
        addOverride, "action",
        { tooltip = "Add a dial the rung changes while the moon is in phase."
                 .. " Click a row to retype its value; x removes it." })
    w[#w + 1] = phasesBtn; w[#w + 1] = addMoonBtn

    local moonList = MoonList:new(0, 0, 10, 10)
    moonList:initialise(); moonList:instantiate()
    moonList.itemheight = DFKit.rowHeight()
    moonList.drawBorder = true
    moonList.selected   = 0
    DFKit.well(moonList)
    local origMoonRender = moonList.render
    moonList.render = function(self_)
        if origMoonRender then origMoonRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height,
                "No overrides - the rung reads the same under any moon")
        end
    end
    panel:addChild(moonList)
    w[#w + 1] = moonList

    ui = { list = list, newBtn = newBtn, saveBtn = saveBtn, revertBtn = revertBtn,
           head = head, moonHead = moonHead, moonNote = moonNote,
           phasesBtn = phasesBtn, addMoonBtn = addMoonBtn, moonList = moonList }

    refresh()
    return w
end

function LMTiersView.layout(panel, x, y, w, h)
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

    -- The moon block claims the bottom of the column; the dial form scrolls
    -- in whatever is left between the heading and it.
    local moonListH = math.min(DFKit.rowHeight() * 4 + 4,
                               math.floor(bodyH / 4))
    local moonY = (y + h) - PAD - moonListH - BTN - GAP - lh * 2
    ui.moonHead:setX(rx);   ui.moonHead:setY(moonY)
    ui.moonNote:setX(rx);   ui.moonNote:setY(moonY + lh)
    ui.phasesBtn:setX(rx);  ui.phasesBtn:setY(moonY + lh * 2)
    ui.addMoonBtn:setX(rx + ui.phasesBtn:getWidth() + GAP)
    ui.addMoonBtn:setY(moonY + lh * 2)
    DFKit.sizeList(ui.moonList, rx, moonY + lh * 2 + BTN + GAP, rw, moonListH)

    local fy = bodyY + lh + 4
    local fh = math.max(60, moonY - fy - PAD)
    if form then form:layout(rx, fy, rw, fh) end
end

-- DFViews contract shims. check-helpers reads these as copies of every other
-- view's draw/onShow - the bodies ARE identical, because they are the
-- contract's one line around this module's private `form`/`refresh`, which no
-- promotion can capture (each shim closes over its own module's locals).
-- Baseline raised with this reason, 2026-08-27.
function LMTiersView.draw(el)
    if form then form:draw(el) end
end

function LMTiersView.onShow()
    refresh()
end

return LMTiersView

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
