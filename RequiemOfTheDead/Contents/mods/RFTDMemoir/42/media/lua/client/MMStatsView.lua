-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMStatsView.lua - READ-ONLY character sheet (Shift+P), styled after the admin
-- "Check Your Stats" panel (ISPlayerStatsUI) but DUPLICATED with zero edit widgets.
-- Same look (header fields, trait icons, Perk/Level/XP/Boost/Multiplier table); no
-- Change/Add/Remove/AddXP/Level buttons. Security: shipping no mutation affordance
-- removes the lazy exploit surface; the only edit path is the server-validated
-- journal reconcile.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "XpSystem/ISUI/ISSkillProgressBar"
require "MMSvShared"

MMStatsView = ISCollapsableWindow:derive("MMStatsView")
MMStatsView.instance = nil

local FONT = UIFont.Small

local function boostPct(b)
    if b == 1 then return "75%" elseif b == 2 then return "100%" elseif b == 3 then return "125%" end
    return "50%"
end

-- Mirrors ISPlayerStatsUI.loadPerks: xp shown as "into-level / needed", name "Perk (Parent)".
local function collectSkills(player)
    local rows, xp = {}, player:getXp()
    for i = 0, Perks.getMaxIndex() - 1 do
        local perkType = Perks.fromIndex(i)
        local perk = PerkFactory.getPerk(perkType)
        if perk and perk:getParent() ~= Perks.None then
            local level = player:getPerkLevel(perkType)
            local xpToLevel = perk:getXpForLevel(level + 1) -- -1 at max
            local into = round(xp:getXP(perkType) - ISSkillProgressBar.getPreviousXpLvl(perk, level), 2)
            local boostLvl = xp:getPerkBoost(perkType) -- free levels granted by profession/traits
            rows[#rows + 1] = {
                name = perk:getName() .. " (" .. PerkFactory.getPerkName(perk:getParent()) .. ")",
                level = level,
                xp = into,
                xpToLevel = xpToLevel,
                boost = boostPct(boostLvl),
                granted = boostLvl,
                multiplier = xp:getMultiplier(perkType),
            }
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

function MMStatsView:buildHeader()
    local p = self.player
    local desc = p:getDescriptor()
    self.fields = {}
    local function add(k, v) self.fields[#self.fields + 1] = { k = k, v = tostring(v) } end
    add("Username", p:getUsername() or "")
    add("Forename", desc and desc:getForename() or "")
    add("Surname", desc and desc:getSurname() or "")
    local prof = desc and desc:getCharacterProfession()
    add("Profession", MMShared.professionUIName(prof and MMShared.labelOf(prof)))
    add("Survived", math.floor(p:getHoursSurvived() or 0) .. " hours")
    local nut = p:getNutrition()
    add("Weight", nut and math.floor(nut:getWeight() or 0) or "?")

    -- traits with icon + label (hardened: a bad def lookup must not kill the section)
    self.traits = {}
    local known = p:getCharacterTraits():getKnownTraits()
    local n = (known and known:size()) or 0
    for i = 0, n - 1 do
        local trait = known:get(i)
        -- Fallback label is the full registry id, not getName(): this only shows for a
        -- trait with no definition, and that is exactly when you want the namespace.
        local label, tex = MMShared.labelOf(trait), nil
        local ok, def = pcall(CharacterTraitDefinition.getCharacterTraitDefinition, trait)
        if ok and def then
            local okl, l = pcall(function() return def:getLabel() end)
            if okl and l and l ~= "" then label = l end
            local okt, t = pcall(function() return def:getTexture() end)
            if okt then tex = t end
        end
        self.traits[#self.traits + 1] = { label = label, tex = tex }
    end
    table.sort(self.traits, function(a, b) return a.label < b.label end)
    MMlog("StatsView: collected " .. tostring(#self.traits) .. " trait(s) for " .. MMname(p))
end

function MMStatsView:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local fh = getTextManager():getFontHeight(FONT)

    -- header height: 6 field lines + traits (icon rows, ~3 per row) + column header
    self.fieldH = fh + 3
    self.traitRowsH = fh * 3 + 8
    self.headerH = self.fieldH * 3 + 6 + self.traitRowsH + fh + 6

    -- column header + list
    local listY = th + self.headerH
    self.list = ISScrollingListBox:new(2, listY, self.width - 4, self.height - listY - 4)
    self.list:initialise()
    self.list.font = FONT
    self.list.itemheight = fh + 6
    self.list.drawBorder = true
    self.list.doDrawItem = MMStatsView.drawSkillRow
    self.list.parentView = self
    self:addChild(self.list)

    -- populate immediately so the first frame already has fields/traits/skills
    self:populate()
end

function MMStatsView:columns()
    local w = self.list and self.list:getWidth() or (self.width - 4)
    return {
        name = 6,
        level = math.floor(w * 0.46),
        xp = math.floor(w * 0.55),
        boost = math.floor(w * 0.76),
        multi = math.floor(w * 0.87),
    }
end

function MMStatsView.drawSkillRow(self, y, item, alt)
    local r = item.item
    local h = self.itemheight
    local c = self.parentView:columns()
    if alt then self:drawRect(0, y, self:getWidth(), h, 0.06, 1, 1, 1) end
    -- column separators
    for _, x in pairs({ c.level, c.xp, c.boost, c.multi }) do
        self:drawRect(x - 4, y, 1, h, 0.4, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    end
    self:drawText(r.name, c.name, y + 3, 0.9, 0.9, 0.9, 1, self.font)
    local lvlStr = tostring(r.level)
    if r.granted and r.granted > 0 then lvlStr = lvlStr .. " (+" .. r.granted .. ")" end
    self:drawText(lvlStr, c.level, y + 3, 1, 1, 1, 1, self.font)
    local xpStr = (r.xpToLevel == -1) and "MAX" or (tostring(r.xp) .. "/" .. tostring(r.xpToLevel))
    self:drawText(xpStr, c.xp, y + 3, 1, 1, 1, 1, self.font)
    self:drawText(r.boost, c.boost, y + 3, 0.8, 0.9, 0.8, 1, self.font)
    self:drawText(tostring(r.multiplier), c.multi, y + 3, 0.8, 0.8, 0.9, 1, self.font)
    return y + h
end

function MMStatsView:prerender()
    ISCollapsableWindow.prerender(self)
    if not self.fields then return end -- guard: data not built yet (render beat populate)
    local th = self:titleBarHeight()
    local fh = getTextManager():getFontHeight(FONT)
    local x, y = 10, th + 4

    -- header fields, two per line
    for i = 1, #self.fields, 2 do
        local f1 = self.fields[i]
        self:drawText(f1.k .. ": ", x, y, 0.85, 0.7, 0.4, 1, FONT)
        self:drawText(f1.v, x + 90, y, 1, 1, 1, 1, FONT)
        local f2 = self.fields[i + 1]
        if f2 then
            self:drawText(f2.k .. ": ", x + 280, y, 0.85, 0.7, 0.4, 1, FONT)
            self:drawText(f2.v, x + 370, y, 1, 1, 1, 1, FONT)
        end
        y = y + self.fieldH
    end

    -- traits with icons
    y = y + 4
    self:drawText("Traits:", x, y, 0.85, 0.7, 0.4, 1, FONT)
    local tx, ty = x + 60, y
    for _, t in ipairs(self.traits) do
        if t.tex then self:drawTextureScaled(t.tex, tx, ty - 2, fh + 2, fh + 2, 1, 1, 1, 1); tx = tx + fh + 6 end
        self:drawText(t.label, tx, ty, 0.9, 0.9, 0.9, 1, FONT)
        tx = tx + getTextManager():MeasureStringX(FONT, t.label) + 18
        if tx > self.width - 120 then tx = x + 60; ty = ty + fh + 4 end
    end

    -- column header line
    local cy = th + self.headerH - fh - 2
    local c = self:columns()
    self:drawText("Perk", c.name, cy, 0.7, 0.7, 0.7, 1, FONT)
    self:drawText("Level", c.level, cy, 0.7, 0.7, 0.7, 1, FONT)
    self:drawText("XP", c.xp, cy, 0.7, 0.7, 0.7, 1, FONT)
    self:drawText("Boost", c.boost, cy, 0.7, 0.7, 0.7, 1, FONT)
    self:drawText("Multiplier", c.multi, cy, 0.7, 0.7, 0.7, 1, FONT)
end

function MMStatsView:populate()
    self:buildHeader()
    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(self.list, function(box)
        for _, row in ipairs(collectSkills(self.player)) do box:addItem(row.name, row) end
    end)
end

function MMStatsView:new(player)
    local w, h = 720, 600
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.player = player
    o.title = "Check Your Stats"
    o.resizable = true
    return o
end

function MMStatsView.toggle()
    if MMStatsView.instance and MMStatsView.instance:getIsVisible() then
        MMStatsView.instance:removeFromUIManager()
        MMStatsView.instance = nil
        return
    end
    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end
    local win = MMStatsView:new(player)
    win:initialise()
    win:addToUIManager()
    win:populate()
    MMStatsView.instance = win
end

-- ---- keybind: default LeftShift + P, rebindable ----
local function initBinds()
    table.insert(keyBinding, { value = "[Dragonfly]" })
    table.insert(keyBinding, { value = "Open Character Sheet", key = Keyboard.KEY_P })
end

local function onKey(key)
    if isGamePaused() then return end
    if getCore():isKey("Open Character Sheet", key) and isKeyDown(Keyboard.KEY_LSHIFT) then
        MMStatsView.toggle()
    end
end

Events.OnGameBoot.Add(initBinds)
Events.OnGameStart.Add(function() Events.OnKeyPressed.Add(onKey) end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
