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
require "LMMoon"
require "DFEntry"

LMDetailsView = LMDetailsView or {}

local ui       = nil
local activeId = nil     -- selected mod id
local forms    = {}      -- mod id -> DFForm (built once, on demand)

local LEFT_W = 232

local rebuildMods, refresh, rebuildProfiles

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
-- The profiles block (M-C, 2026-08-07) - which bags this zone applies, in
-- which order, and whether the moon currently lets them speak.
--
-- ORDER IS PRECEDENCE (later beats earlier), so the list is ordered UI with
-- move buttons, not a checklist. The rows carry their own controls as drawn
-- hotspots resolved by x in onMouseDown - the ISScrollingListBox idiom the
-- ModList above already uses - because sixteen rows of real ISButtons is a
-- widget tree for a list that mostly holds two entries.
--
-- A profile row that is off-phase says so. The Details forms show RESOLVED
-- values through the same phase gate the game uses, which is honest but
-- reads as "my BloodMoon numbers vanished" at new moon - the badge is the
-- missing sentence: they are not gone, they are waiting.
-- ---------------------------------------------------------------------------

local ProfileList = ISScrollingListBox:derive("LMProfileList")

-- Per-row hotspot columns, right-aligned: [up][down][edit][remove].
local COLW = 22

local function profileHot(list, x)
    local edge = list.width - 4
    if x > edge - COLW then return "remove" end
    if x > edge - COLW * 2 then return "edit" end
    if x > edge - COLW * 3 then return "down" end
    if x > edge - COLW * 4 then return "up" end
    return nil
end

function ProfileList:doDrawItem(y, item, alt)
    local it = item.item
    if not it then return y + self.itemheight end
    local h = self.itemheight
    if alt then self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08) end

    local label = tostring(item.text)
    if it.missing then
        self:drawText(label .. "  (missing)", 6, y + 2, 0.85, 0.45, 0.30, 1, UIFont.Small)
    elseif it.inactive then
        self:drawText(label, 6, y + 2, 0.55, 0.55, 0.62, 1, UIFont.Small)
        local tag = "waiting for " .. tostring(it.phases)
        local lw = getTextManager():MeasureStringX(UIFont.Small, label)
        self:drawText(tag, 12 + lw, y + 2, 0.45, 0.50, 0.60, 1, UIFont.Small)
    else
        self:drawText(label, 6, y + 2, 0.92, 0.92, 0.92, 1, UIFont.Small)
    end

    local edge = self.width - 4
    local glyphs = { { "^", 4 }, { "v", 3 }, { ">", 2 }, { "x", 1 } }
    for _, g in ipairs(glyphs) do
        local gx = edge - COLW * g[2]
        self:drawText(g[1],
            gx + math.floor((COLW - getTextManager():MeasureStringX(UIFont.Small, g[1])) / 2),
            y + 2, 0.62, 0.68, 0.75, 1, UIFont.Small)
    end
    return y + h
end

function ProfileList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if not (row and row.item) then return end
    local zone  = LMEditView.selected()
    local draft = LMEditView.draft()
    if not (zone and draft) then return end
    local pname = row.item.name

    local hot = profileHot(self, x)
    if hot == "remove" then
        draft:removeProfile(zone, pname)
    elseif hot == "up" then
        draft:moveProfile(zone, pname, -1)
    elseif hot == "down" then
        draft:moveProfile(zone, pname, 1)
    elseif hot == "edit" then
        -- Jump the shared selection to the profile itself, so the forms below
        -- edit ITS fields - where phases and the actual numbers live.
        if not row.item.missing then LMEditView.select(pname) end
        return
    else
        return
    end
    LMEditView.refresh()
    refresh()
end

rebuildProfiles = function()
    if not (ui and ui.profList) then return end
    local zone  = LMEditView.selected()
    local draft = LMEditView.draft()
    local phase = Limes.moonPhase and Limes.moonPhase() or nil

    DFKit.refillList(ui.profList, function(box)
        if not (zone and draft) then return end
        for i, pname in ipairs(draft:profilesOf(zone)) do
            local prec = draft:get(pname)
            local phases = prec and prec.fields and prec.fields.phases
            local inactive = false
            if prec and phases and phases ~= "" and LMMoon and LMMoon.parsePhases then
                local set = LMMoon.parsePhases(phases)
                inactive = (set ~= nil) and (phase == nil or set[phase] ~= true)
            end
            box:addItem(i .. ". " .. pname, {
                name = pname, missing = (prec == nil),
                inactive = inactive, phases = phases,
            })
        end
    end)

    -- The moon caption: the one line that explains why a dormant profile's
    -- numbers are not in the forms below.
    if ui.profMoon then
        local pn = LMMoon and LMMoon.phaseName and LMMoon.phaseName(phase)
        ui.profMoon:setName("Moon: " .. (pn or "unknown"))
    end
end

local function applyProfilePick(pname)
    local zone  = LMEditView.selected()
    local draft = LMEditView.draft()
    if not (zone and draft) then return end
    local ok, why = draft:addProfile(zone, pname)
    if not ok and why then print("[Limes] " .. tostring(why)) end
    if ui and ui.picker then ui.picker:setVisible(false) end
    LMEditView.refresh()
    refresh()
end

local PickerList = ISScrollingListBox:derive("LMProfilePicker")

function PickerList:doDrawItem(y, item, alt)
    local h = self.itemheight
    if alt then self:drawRect(0, y, self.width, h - 1, 0.18, 0.08, 0.08, 0.08) end
    self:drawText(tostring(item.text), 6, y + 2, 0.92, 0.92, 0.92, 1, UIFont.Small)
    return y + h
end

function PickerList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local row = self.items[idx]
    if row and row.item then applyProfilePick(row.item) end
end

local function openPicker()
    local zone  = LMEditView.selected()
    local draft = LMEditView.draft()
    if not (zone and draft and ui and ui.picker) then return end
    local names = draft:profileCandidates(zone)
    DFKit.refillList(ui.picker, function(box)
        for _, n in ipairs(names) do box:addItem(n, n) end
    end)
    ui.picker:setVisible(#names > 0)
    if #names == 0 then
        print("[Limes] no templates left to apply - New makes one")
    end
end

local function newProfile()
    local zone  = LMEditView.selected()
    local draft = LMEditView.draft()
    if not (zone and draft) then return end
    DFEntry.show{
        title       = "New profile",
        value       = "",
        rule        = "Letters, digits, _ - . only. A profile is a zone with no"
            .. " ground; it will be applied to " .. zone .. " immediately.",
        maxLen      = 48,
        validate    = function(s)
            local why = LMEdit.nameProblem(s)
            if why then return false, why end
            if draft:get(s) then return false, "'" .. s .. "' already exists." end
            return true
        end,
        onCommit    = function(s)
            local ok, why = draft:create(s)      -- no rec: rect-less = template
            if not ok then print("[Limes] " .. tostring(why)) return end
            draft:addProfile(zone, s)
            -- Land the admin on the new profile's own forms - the next thing
            -- they will do is give it fields, and phases lives there too.
            LMEditView.select(s)
            LMEditView.refresh()
            refresh()
        end,
    }
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
    -- Vanilla setVisible instantiates a missing backing widget before changing
    -- visibility (ISUIElement.lua:657-660).
    for id, f in pairs(forms) do
        if f._el then f._el:setVisible(id == activeId) end
    end

    -- The profiles block exists only with a zone in hand; the picker never
    -- survives a refresh (a stale candidate list is worse than a second click).
    local showProf = zone ~= nil
    for _, el in ipairs({ ui.profHead, ui.profMoon, ui.profList, ui.applyBtn, ui.newBtn }) do
        if el then el:setVisible(showProf) end
    end
    if ui.picker then ui.picker:setVisible(false) end
    if showProf then rebuildProfiles() end

    local info = activeId and Limes.mods.info(activeId)
    ui.head:setName(zone
        and ((info and info.label or activeId or "?") .. "  -  " .. zone)
        or  "Select a zone on the Zone Selector tab first")

    local desc = info and info.description
    ui.desc:setName(desc or "")

    -- Say what could not be rendered rather than letting an admin conclude the
    -- store has no such field. String fields render since 2026-08-06 (DFForm
    -- grew `choice` and `text`), so this line is normally empty - it stays
    -- because a mod can register a `ui` this build has never heard of, and
    -- `colour` is still Core work. Worded for the general case now rather than
    -- for text specifically.
    local skipped = activeId and forms[activeId] and LMFieldForm.skipped(forms[activeId]) or {}
    ui.note:setName(#skipped > 0
        and (#skipped .. " field" .. (#skipped == 1 and "" or "s")
             .. " this build cannot draw: " .. table.concat(skipped, ", "))
        or "")
end

-- ---------------------------------------------------------------------------
-- The DFViews contract
-- ---------------------------------------------------------------------------

function LMDetailsView.attach(panel)
    -- THE FORM CACHE DIES WITH THE PANEL. The deck rebuilds tab content on
    -- every roster switch, so this attach runs again on a FRESH panel while
    -- the previous one - and every hotspot the old forms attached to it - is
    -- already destroyed. The module-level cache made formFor() hand those
    -- orphans back: they still painted (draw() renders onto whatever panel is
    -- passed each frame) but nothing could be clicked, their widgets were
    -- missing from ui.formWidgets so visibility switching no longer covered
    -- them, and the whole Details view read as "drawn but dead" after any
    -- trip to another tab. A DFForm is a per-panel object; cache accordingly.
    forms = {}
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

    -- The profiles block: header line (label + moon caption + two buttons),
    -- the ordered list, and the transient Apply picker. Built fresh in every
    -- attach like everything else here - the dead-orphan-widget rule above
    -- applies to these exactly as it does to the forms.
    local profHead = DFKit.label(panel, 0, 0, "Profiles")
    local profMoon = DFKit.label(panel, 0, 0, "", C.textDim)
    w[#w + 1] = profHead; w[#w + 1] = profMoon

    local profList = ProfileList:new(0, 0, 10, 10)
    profList:initialise(); profList:instantiate()
    profList.itemheight = 20
    profList.drawBorder = true
    profList.selected   = 0
    DFKit.well(profList)
    local origProfRender = profList.render
    profList.render = function(self_)
        if origProfRender then origProfRender(self_) end
        if self_:size() == 0 then
            DFKit.drawEmpty(self_, 0, 0, self_.width, self_.height,
                "No profiles applied - Apply picks a template, New makes one")
        end
    end
    panel:addChild(profList)
    w[#w + 1] = profList

    local applyBtn = DFKit.button(panel, 0, 0, 58, "Apply", nil, openPicker, "action",
        { tooltip = "Apply an existing profile (a template zone) to this zone."
            .. " Later profiles in the list beat earlier ones." })
    local newBtn = DFKit.button(panel, 0, 0, 44, "New", nil, newProfile, "action",
        { tooltip = "Create a new empty profile, apply it here, and jump to its"
            .. " fields. Set 'Active moon phases' there to make it phase-bound." })
    w[#w + 1] = applyBtn; w[#w + 1] = newBtn

    local picker = PickerList:new(0, 0, 10, 10)
    picker:initialise(); picker:instantiate()
    picker.itemheight = 20
    picker.drawBorder = true
    picker.selected   = 0
    DFKit.well(picker)
    picker:setVisible(false)
    panel:addChild(picker)
    w[#w + 1] = picker

    ui = { list = list, head = head, desc = desc, note = note,
           profHead = profHead, profMoon = profMoon, profList = profList,
           applyBtn = applyBtn, newBtn = newBtn, picker = picker,
           formWidgets = {}, panel = panel }

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

    -- Line pitch is the glyph, measured - the old fixed 20px was only true at
    -- the font it was tuned against; at a larger text-size preference the
    -- description drew into the heading and the note into the form.
    local lh = 20
    -- pcall: getFontHeight (TextManager:127) hands its argument to
    -- getFontFromEnum and dereferences the result unguarded, so a font this
    -- build does not carry is an NPE. The 20 above is the fallback that keeps.
    pcall(function()
        lh = getTextManager():getFontHeight(DFKit.font.small or UIFont.Small) + 4
    end)
    ui.head:setX(rx); ui.head:setY(y + PAD)
    ui.desc:setX(rx); ui.desc:setY(y + PAD + lh)
    ui.note:setX(rx); ui.note:setY(y + h - lh)

    -- The profiles block claims its rows between the description and the
    -- forms, but ONLY while a zone is selected - with nothing selected the
    -- forms keep the whole column and the block hides entirely (refresh()
    -- drives visibility; layout only reserves the space).
    local fy = y + PAD + lh * 2
    local zone = LMEditView.selected and LMEditView.selected() or nil
    if zone and ui.profList then
        local btnH  = DFKit.metrics.btnH
        local listH = 20 * 3 + 4                    -- three rows before scrolling
        ui.profHead:setX(rx); ui.profHead:setY(fy)
        local moonW = 120
        ui.profMoon:setX(rx + rw - moonW - ui.applyBtn:getWidth() - ui.newBtn:getWidth() - m.gap * 2)
        ui.profMoon:setY(fy)
        ui.applyBtn:setX(rx + rw - ui.applyBtn:getWidth() - ui.newBtn:getWidth() - m.gap)
        ui.applyBtn:setY(fy - 2)
        ui.newBtn:setX(rx + rw - ui.newBtn:getWidth())
        ui.newBtn:setY(fy - 2)
        local ly = fy + math.max(lh, btnH)
        DFKit.sizeList(ui.profList, rx, ly, rw, listH)
        -- The picker drops over the top of the forms, under the Apply button.
        ui.picker:setX(rx + rw - 240)
        ui.picker:setY(ly)
        DFKit.sizeList(ui.picker, rx + rw - 240, ly, 240, 20 * 6 + 4)
        fy = ly + listH + PAD
    end

    local fh = math.max(60, (y + h) - fy - lh - 4)
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
