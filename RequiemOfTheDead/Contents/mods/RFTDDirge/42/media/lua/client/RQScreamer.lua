-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQScreamer - client-side disorientation for the screamer
-- All behavior (scream trigger, spawn, sound) runs server-side.
-- This file handles the local player screen effect only.
--
-- Uses the SearchMode overlay system (blur + darkness + desat).
-- Non-zero interior values ensure the entire screen is affected -
-- no clear tunnel in the center, just a gradient from heavy at
-- edges to moderate at center.
--
-- Critically: SearchMode holds the effect natively with no per-tick
-- reapplication. The intoxication approach caused rhythmic 60fps
-- flicker as the engine fought our stat set - a genuine accessibility
-- concern for photosensitive players. This approach has none of that.
--
-- Cleanup: all parameters zeroed before releasing override so no
-- residual values linger in the SearchMode system.

RQScreamer = RQScreamer or {}

-- Effect parameters by trait
-- exterior = screen edges, interior = center (both non-zero = no clear tunnel)
-- Interior = exterior: uniform full-screen coverage, no clear center.
-- Exterior slightly higher so edges are marginally darker (vignette lean)
-- without creating a visible "window" in the center.
local EFFECTS = {
    normal = {
        name      = "normal",
        blur_ext  = 0.80, blur_int  = 0.75,
        dark_ext  = 0.20, dark_int  = 0.15,
        desat_ext = 0.35, desat_int = 0.25,
        linger    = 10000,
    },
    brave = {
        name      = "brave",
        blur_ext  = 0.50, blur_int  = 0.45,
        dark_ext  = 0.10, dark_int  = 0.08,
        desat_ext = 0.15, desat_int = 0.10,
        linger    = 5000,
    },
    cowardly = {
        name      = "cowardly",
        blur_ext  = 0.95, blur_int  = 0.90,
        dark_ext  = 0.30, dark_int  = 0.22,
        desat_ext = 0.55, desat_int = 0.45,
        linger    = 20000,
    },
}

-- Radius of 0 collapses the clear zone so the effect covers the full screen.
-- Interior and exterior effect values are identical - uniform coverage
-- with slightly more darkness at the actual screen edges via the gradient.
local RADIUS_EXT   = 0     -- no clear zone
local GRAD_EXT     = 6     -- soft gradient from center outward
local FADE_IN      = 0.3   -- seconds
local FADE_OUT     = 1.5   -- seconds
local MAX_LINGER   = 20000 -- ms - hard cap, stacking can't push past 20s

local disorientation = { active = false, clearTime = 0 }

local function getResistance(player)
    if player:hasTrait(CharacterTrait.DESENSITIZED) then return nil end
    if player:hasTrait(CharacterTrait.BRAVE)        then return EFFECTS.brave end
    if player:hasTrait(CharacterTrait.COWARDLY)     then return EFFECTS.cowardly end
    return EFFECTS.normal
end

local function applyPanicBump(player)
    pcall(function()
        player:getStats():add(CharacterStat.PANIC, 25)
    end)
end

local function startDisorientation(player, fx, lingerMs)
    local pn = player:getPlayerNum()
    local sm = getSearchMode()
    RQDirgeLog.write("Screamer", "[INFO] startDisorientation effect=" .. tostring(fx.name)
        .. " linger=" .. tostring(lingerMs) .. " smAvail=" .. tostring(sm ~= nil))
    if not sm then
        RQDirgeLog.write("Screamer", "[WARN] getSearchMode() returned nil - screen effect SKIPPED")
    end

    if sm then pcall(function()
        local psm  = sm:getSearchModeForPlayer(pn)
        local cfg  = RQConfig.get()
        local blur = cfg.screamerBlurStrength or 1.0
        local dark = cfg.screamerDarkStrength or 1.0

        psm:getBlur():setExterior(fx.blur_ext * blur)
        psm:getBlur():setInterior(fx.blur_int * blur)
        psm:getDarkness():setExterior(fx.dark_ext * dark)
        psm:getDarkness():setInterior(fx.dark_int * dark)
        psm:getDesat():setExterior(fx.desat_ext)
        psm:getDesat():setInterior(fx.desat_int)
        RQDirgeLog.write("Screamer", "[INFO] SearchMode params set"
            .. " blur=(" .. string.format("%.2f", fx.blur_ext * blur) .. "/" .. string.format("%.2f", fx.blur_int * blur) .. ")"
            .. " dark=(" .. string.format("%.2f", fx.dark_ext * dark) .. "/" .. string.format("%.2f", fx.dark_int * dark) .. ")"
            .. " desat=(" .. string.format("%.2f", fx.desat_ext) .. "/" .. string.format("%.2f", fx.desat_int) .. ")")

        -- Radius controls the gradient shape.
        -- Interior=0 means effect starts right at the player position and
        -- transitions outward. Exterior=12 sets the gradient outer edge.
        -- Combined with high interior values this gives full-screen coverage
        -- with no clear tunnel.
        local radius   = psm:getRadius()
        local gradient = psm:getGradientWidth()
        radius:setExterior(RADIUS_EXT)
        radius:setInterior(0)
        gradient:setExterior(GRAD_EXT)
        gradient:setInterior(0)

        sm:setFadeTime(FADE_IN)
        sm:setOverride(pn, true)
        sm:setEnabled(pn, true)
    end) end

    local now  = getTimestampMs()
    local base = (disorientation.active and disorientation.clearTime > now)
                 and disorientation.clearTime or now
    disorientation.clearTime = math.min(base + lingerMs, now + MAX_LINGER)
    disorientation.active    = true

    RQMoodle.setDazed(player:getPlayerNum(), fx.name)
end

local function clearDisorientation()
    if not disorientation.active then return end
    RQDirgeLog.write("Screamer", "[INFO] clearDisorientation")

    local player = getPlayer()
    if player then
        local pn = player:getPlayerNum()
        local sm = getSearchMode()
        if sm then
            pcall(function()
                local psm = sm:getSearchModeForPlayer(pn)
                -- Zero all parameters before releasing so nothing lingers
                psm:getBlur():setExterior(0);     psm:getBlur():setInterior(0)
                psm:getDarkness():setExterior(0); psm:getDarkness():setInterior(0)
                psm:getDesat():setExterior(0);    psm:getDesat():setInterior(0)
                psm:getRadius():setExterior(0);   psm:getRadius():setInterior(0)
                psm:getGradientWidth():setExterior(0)
                psm:getGradientWidth():setInterior(0)
                sm:setFadeTime(FADE_OUT)
                sm:setEnabled(pn, false)
                sm:setOverride(pn, false)
            end)
        end
    end

    disorientation.active    = false
    disorientation.clearTime = 0

    if player then
        RQMoodle.clearDazed(player:getPlayerNum())
    end
end

-- Reflection probe (RQReflect): is the blur/darkness overlay up right now?
-- An active overlay at hit time can explain "I saw nothing" by itself.
function RQScreamer.isDisoriented()
    return disorientation.active == true
end

function RQScreamer.onCastStart(player, screamer, blastX, blastY)
    if not player then return end
    local cfg      = RQConfig.get()
    local rangeSq  = cfg.screamerTriggerRange * cfg.screamerTriggerRange

    local inRange
    local posSource
    if screamer then
        local dx = player:getX() - screamer:getX()
        local dy = player:getY() - screamer:getY()
        inRange   = dx*dx + dy*dy <= rangeSq
        posSource = "zombie"
    elseif blastX and blastY then
        local dx = player:getX() - blastX
        local dy = player:getY() - blastY
        inRange   = dx*dx + dy*dy <= rangeSq
        posSource = "broadcast"
    else
        inRange   = false
        posSource = "none"
    end

    local fx = getResistance(player)
    RQDirgeLog.write("Screamer", "[INFO] onCastStart"
        .. " posSource=" .. posSource
        .. " inRange=" .. tostring(inRange)
        .. " immune=" .. tostring(fx == nil)
        .. " range=" .. tostring(cfg.screamerTriggerRange))
    if not inRange then return end
    if not fx then
        RQDirgeLog.write("Screamer", "[INFO] player is Desensitized - effect skipped")
        return
    end

    startDisorientation(player, fx, fx.linger)
    applyPanicBump(player)
end

function RQScreamer.onCastDone(player, screamer)
end

function RQScreamer.onDead(zombie)
    local ok, oid = pcall(zombie.getOnlineID, zombie)
    if ok and oid and oid ~= 0 then
        RQRing.clear("screamer_" .. oid)
    end
    clearDisorientation()
end

-- Linger timeout - no per-tick stat manipulation, just a timer check.
-- SearchMode holds the effect natively until we release it.
Events.OnTick.Add(function()
    if not disorientation.active then return end
    local now = getTimestampMs()
    if disorientation.clearTime > 0 and now >= disorientation.clearTime then
        RQDirgeLog.write("Screamer", "[INFO] disorientation linger expired at t=" .. tostring(now))
        clearDisorientation()
    end
end)

Events.OnGameStart.Add(function()
    disorientation = { active = false, clearTime = 0 }
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
