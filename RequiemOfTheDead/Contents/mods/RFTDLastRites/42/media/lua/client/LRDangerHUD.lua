-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRDangerHUD.lua  (client)
--
-- Render surface for the OVER-HEAD danger badges only. Sidebar badges are real
-- moodle widgets (see LRDangerMoodle.lua, the Dirge RQMoodle pattern); this
-- file handles the world-projected ones that float above the player's head.
--
-- A single 1x1 ISUIElement (so it never blocks world clicks) that suspends its
-- stencil and draws every over-head badge each frame with an attention shake.
-- It owns NO logic: the controller (LRDanger) recomputes LRDangerHUD.badges
-- each tick and this element just draws them. Badge descriptor:
--   { tex=<Texture>, shake="none"|"pulse"|"continuous", slot=n }
--
-- Over-head projection reuses the sibling-proven isoToScreenX/Y head-anchor
-- trick (zoom/camera baked in) - see Dirge RQCastBar.lua.
--
-- Also the home of the shake helper shared with the sidebar widget
-- (LRDangerHUD.shakeX) so the shake feel stays identical across both
-- placements. Badge SIZE is Core's (DFKit.moodleBadgeSize) - it is vanilla's
-- ladder, not ours.

require "RDWorldOverlay"

LRDangerHUD = LRDangerHUD or {}

-- Live over-head badge list, replaced wholesale by the controller each frame.
LRDangerHUD.badges = LRDangerHUD.badges or {}

-- Over-head thought "quip": our own renderer (not HaloTextHelper, whose
-- lifespan is a short fixed engine timer with a dedup queue that swallows
-- lines). Gives us a controllable duration and reliable per-tier pops for both
-- hot and cold.
LRDangerHUD.quip = LRDangerHUD.quip or { text = nil, expire = 0 }

-- ── tunables ──────────────────────────────────────────────
local OVERHEAD_HEAD_Z = 0.7    -- world-Z to anchor at (~head height; RQCastBar uses 0.6)
local OVERHEAD_GAP    = 4       -- px gap between stacked over-head badges
local SHAKE_AMP       = 4       -- px horizontal shake amplitude
local SHAKE_FREQ      = 0.045   -- shake wobble speed (rad per ms)
local SHAKE_PERIOD    = 1500    -- ms between pulses (pulse mode)
local SHAKE_BURST     = 450     -- ms shake duration within a pulse
local QUIP_MS         = 2500    -- default over-head thought duration
local QUIP_FADE       = 600     -- ms fade-out tail
local QUIP_GAP        = 8       -- px gap between top badge and the quip line

-- Calibration knob for the over-head vertical anchor (set from the LRHub tab).
LRDangerHUD.overheadYAdjust = 0

-- ── shared helpers (also used by LRDangerMoodle) ──────────
-- The badge-size helper used to live here and is now DFKit.moodleBadgeSize
-- (Core, 2026-08-19) - Dirge's RQMoodle had grown the identical fourteen lines,
-- and neither copy cited the vanilla ladder it was reproducing. Both placements
-- call Core directly rather than through an alias here: one name for one thing.

-- Show an over-head thought line for `ms` (default QUIP_MS). Replaces any
-- currently-showing quip (a new tier pop supersedes the old one).
function LRDangerHUD.showQuip(text, ms)
    LRDangerHUD.quip.text   = text
    LRDangerHUD.quip.expire = getTimestampMs() + (ms or QUIP_MS)
end

-- Horizontal pixel offset for the given shake mode at time `now` (ms).
function LRDangerHUD.shakeX(mode, now)
    if mode == "continuous" then
        return math.sin(now * SHAKE_FREQ) * SHAKE_AMP
    elseif mode == "pulse" then
        if (now % SHAKE_PERIOD) > SHAKE_BURST then return 0 end
        return math.sin(now * SHAKE_FREQ) * SHAKE_AMP
    end
    return 0
end

-- ── element ───────────────────────────────────────────────
-- The 1x1 click-through element moved to Core 2026-08-19: Dirge's cast bar and
-- health bar had grown the same one independently, down to the empty prerender
-- and the list of return-false handlers. The old comment here read "the 1x1
-- footprint already avoids most of it", which undersold those handlers -
-- UIElement.consumeMouseEvents defaults TRUE, so an inherited nil return EATS
-- the click. RDWorldOverlay's header has the read.
local LRDangerHUDElem = RDWorldOverlay:derive("LRDangerHUDElem")

function LRDangerHUDElem:render()
    local player = getPlayer()
    if not player then return end

    local now  = getTimestampMs()
    local q    = LRDangerHUD.quip
    local quipOn = q.text ~= nil and now < q.expire
    local badges = LRDangerHUD.badges or {}
    if #badges == 0 and not quipOn then return end

    local pn   = player:getPlayerNum()
    local size = DFKit.moodleBadgeSize()

    self:suspendStencil()

    -- Over-head anchor: screen position of a point above the player's head.
    local wx, wy, wz = player:getX(), player:getY(), player:getZ()
    local headSX = isoToScreenX(pn, wx, wy, wz + OVERHEAD_HEAD_Z)
    local headSY = isoToScreenY(pn, wx, wy, wz + OVERHEAD_HEAD_Z) + LRDangerHUD.overheadYAdjust

    for i = 1, #badges do
        local b = badges[i]
        if b.tex then
            local x = headSX - size / 2 + LRDangerHUD.shakeX(b.shake, now)
            -- Badge bottom sits just above the head anchor; further slots stack up.
            local y = headSY - (size + OVERHEAD_GAP) * (b.slot + 1)
            self:drawTextureScaled(b.tex, x, y, size, size, 1)
        end
    end

    -- Quip line, above the top badge (or just above the head if none).
    if quipOn then
        local font = UIFont.Medium
        local remain = q.expire - now
        local a = (remain < QUIP_FADE) and (remain / QUIP_FADE) or 1.0
        local ty = headSY - (size + OVERHEAD_GAP) * #badges - QUIP_GAP
                   - getTextManager():MeasureStringY(font, q.text)
        local tw = getTextManager():MeasureStringX(font, q.text)
        local tx = headSX - tw / 2
        -- Shadow for legibility against bright/dark scenery, then the text.
        self:drawText(q.text, tx + 1, ty + 1, 0, 0, 0, a * 0.7, font)
        self:drawText(q.text, tx,     ty,     1, 0.92, 0.85, a, font)
    end

    self:resumeStencil()
end

-- ── singleton lifecycle ───────────────────────────────────
local hud = nil

function LRDangerHUD.ensure()
    if hud and hud.javaObject then return hud end
    hud = RDWorldOverlay.attach(LRDangerHUDElem)
    return hud
end

local function reset()
    LRDangerHUD.badges = {}
    LRDangerHUD.quip = { text = nil, expire = 0 }
    if hud and hud.javaObject then
        -- Vanilla ISUIElement.lua:1373-1380 already handles a missing Java
        -- object, removes the element, and marks it removed.
        hud:removeFromUIManager()
    end
    hud = nil
    LRDangerHUD.ensure()
end

Events.OnGameStart.Add(reset)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
