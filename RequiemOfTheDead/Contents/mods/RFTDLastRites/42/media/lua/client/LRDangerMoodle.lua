-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRDangerMoodle.lua  (client)
--
-- Sidebar danger badges, built as real moodle widgets the same way Dirge solved
-- it for the Screamer "Dazed" moodle (RQMoodle.lua): one ISUIElement per signal,
-- added to the UIManager, stacking below the vanilla moodle column and showing a
-- hover tooltip - rather than a hand-drawn stencil blit. This gives proper UI
-- participation (tooltips, layering) that the over-head stencil pass can't.
--
-- Our icons are self-contained 64x64 art (frame baked in), so unlike RQMoodle we
-- draw a single texture instead of vanilla bg/border/icon layers. Size and shake
-- are shared with the over-head pass via LRDangerHUD.getBadgeSize / .shakeX so
-- both placements feel identical.
--
-- The controller drives this with LRDangerMoodle.set(key, level, tex, shake) /
-- LRDangerMoodle.clear(key). Only one temperature badge is ever in the sidebar
-- at a time (hot and cold are mutually exclusive), but the slot math supports
-- more in case that changes.

LRDangerMoodle = LRDangerMoodle or {}

local X_OFFSET = 10    -- gap from the right edge of the player's screen
local Y_OFFSET = 120   -- vanilla moodle baseline
local STEP_PAD = 10    -- vertical gap between stacked badges

-- Per-signal, per-level tooltip copy (title + one-line hint). Cold is the only
-- signal that uses the sidebar (heat/blood are over-head, which has no hover), so
-- cold carries the full L1-4 set; others keep a generic fallback for safety.
local TOOLTIP = {
    cold = {
        [1] = { title = "Getting cold",   desc = "Your body is losing heat. Find warmth." },
        [2] = { title = "Cold setting in", desc = "Chilling fast - get warm soon." },
        [3] = { title = "Severe cold",    desc = "Dangerously cold. Warm up now." },
        [4] = { title = "Freezing",       desc = "Freezing to death. Get warm immediately." },
    },
    hot  = { [1] = { title = "Overheating", desc = "Your body is too hot. Find shade and water." } },
}

local function tooltipFor(key, level)
    local t = TOOLTIP[key]
    if not t then return nil end
    return t[level] or t[2] or t[1]
end

-- Count active vanilla moodles so our badges stack below them.
-- B42: iterate Registries.MOODLE_TYPE:values() (no MoodleType.FromIndex).
local function countVanillaMoodles(player)
    local count = 0
    local moodles = player:getMoodles()
    local values  = Registries.MOODLE_TYPE:values()
    for i = 0, values:size() - 1 do
        local mType  = values:get(i)
        local mLevel = moodles:getMoodleLevel(mType)
        if mLevel ~= 0 and (mType ~= MoodleType.FOOD_EATEN or mLevel >= 3) then
            count = count + 1
        end
    end
    return count
end

-- ── element ───────────────────────────────────────────────
local LRMoodleElem = ISUIElement:derive("LRMoodleElem")

function LRMoodleElem:new(key)
    local size = LRDangerHUD.getBadgeSize()
    local o = ISUIElement:new(0, 0, size, size)
    setmetatable(o, self)
    self.__index = self
    o.key      = key
    o.tex      = nil
    o.shake    = "none"
    o.level    = 1     -- current moodle level (for the tooltip)
    o.slot     = 0     -- stacking index among active LR sidebar badges
    o.active   = false
    o.addedToUI = false
    o.keepOnScreen    = false   -- don't clamp; we position it ourselves (RQMoodle)
    o.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o:setWantKeyEvents(false)
    o:initialise()
    return o
end

function LRMoodleElem:render()
    if not self.active or not self.tex then return end

    local player = getPlayer()
    if not player then return end
    local pn   = player:getPlayerNum()
    local size = LRDangerHUD.getBadgeSize()

    local baseX = getPlayerScreenLeft(pn) + getPlayerScreenWidth(pn) - X_OFFSET - size
    local baseY = getPlayerScreenTop(pn) + Y_OFFSET
                  + (countVanillaMoodles(player) + self.slot) * (size + STEP_PAD)

    local shakeX = LRDangerHUD.shakeX(self.shake, getTimestampMs())

    self:setX(baseX + shakeX)
    self:setY(baseY)
    self:setWidth(size)
    self:setHeight(size)

    self:drawTextureScaled(self.tex, 0, 0, size, size, 1)

    -- Tooltip on hover, drawn to the left like vanilla moodles.
    if self:isMouseOver() then
        local tip = tooltipFor(self.key, self.level)
        if tip then
            local font = UIFont.Small
            local pad  = 3
            local tm   = getTextManager()
            local tW   = math.max(tm:MeasureStringX(font, tip.title),
                                  tm:MeasureStringX(font, tip.desc)) + pad * 2
            local tH   = tm:MeasureStringY(font, tip.title)
            local dH   = tm:MeasureStringY(font, tip.desc)
            local boxH = tH + dH + pad * 3
            local boxX = -(tW + 6)
            local boxY = math.max(0, math.floor((size - boxH) / 2))
            self:drawRect(boxX, boxY, tW, boxH, 0.7, 0, 0, 0)
            self:drawText(tip.title, boxX + pad, boxY + pad,            1, 1, 1, 1,   font)
            self:drawText(tip.desc,  boxX + pad, boxY + pad + tH + pad, 1, 1, 1, 0.7, font)
        end
    end
end

-- ── per-signal instances ──────────────────────────────────
local instances = {}  -- key -> LRMoodleElem

local function getOrCreate(key)
    local m = instances[key]
    if not m then
        m = LRMoodleElem:new(key)
        instances[key] = m
    end
    return m
end

-- Show/update the sidebar badge for a signal.
function LRDangerMoodle.set(key, tex, shake, slot, level)
    local m = getOrCreate(key)
    m.tex    = tex
    m.shake  = shake or "none"
    m.slot   = slot or 0
    m.level  = level or 1
    m.active = true
    if not m.addedToUI then
        m:addToUIManager()
        m.addedToUI = true
    end
end

-- Hide the sidebar badge for a signal.
function LRDangerMoodle.clear(key)
    local m = instances[key]
    if not m then return end
    m.active = false
    if m.addedToUI then
        -- Guard stays for the same reason as LRDangerHUD's teardown: vanilla
        -- LUA, unverifiable against the decompile.
        if m.javaObject then pcall(m.removeFromUIManager, m) end
        m.addedToUI = false
    end
end

local function clearAll()
    for key, _ in pairs(instances) do
        LRDangerMoodle.clear(key)
    end
end

Events.OnGameStart.Add(clearAll)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
