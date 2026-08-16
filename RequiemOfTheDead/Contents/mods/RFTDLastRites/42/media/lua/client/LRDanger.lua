-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRDanger.lua  (client)
--
-- The danger-indicator controller. Polls the local player's vanilla moodle
-- levels for the three life-threatening signals (heat, cold, bleeding), turns
-- each into a badge descriptor for LRDangerHUD, and fires an over-head thought
-- "quip" on a temperature signal - on each escalation and then every few
-- minutes while it persists.
--
-- Why drive off the vanilla MOODLE LEVEL (0-4) rather than raw core
-- temperature: the engine already bands temperature severity into that level
-- and - crucially - only starts applying thermal HEALTH damage at levels 3-4.
-- So level maps cleanly onto the requested escalation:
--   1 onset  2 worsening  3 hurting  4 actively dying (continuous shake).
-- All three signals render over-head from stage 1 (the sidebar phase was
-- dropped); levels 1-3 pulse-shake, level 4 shakes continuously.
--
-- Purely local & cosmetic (reads only this client's state), so it runs in SP
-- and MP alike; the LRHub settings UI is MP-only but the defaults apply
-- everywhere.

LRDanger = LRDanger or {}

local POLL_MS = 300  -- how often we re-evaluate (moodles change slowly)

-- Signal definitions, in stacking order. quip nil => no quips (blood).
-- All signals are over-head from stage 1 (overheadFrom = 1): cold, heat and
-- bleeding are each a "react now" pressure, so none starts in the sidebar.
local SIGNALS = {
    { key = "cold",  pref = "lr_danger_cold",  moodle = "HYPOTHERMIA",  texBase = "LR_cold_",  quip = "cold", overheadFrom = 1 },
    { key = "hot",   pref = "lr_danger_hot",   moodle = "HYPERTHERMIA", texBase = "LR_hot_",   quip = "hot",  overheadFrom = 1 },
    { key = "blood", pref = "lr_danger_blood", moodle = "BLEEDING",     texBase = "LR_blood_", quip = nil,    overheadFrom = 1 },
}

-- A persisting temperature quip re-pops on this cadence (real-time ms), so the
-- player keeps getting nudged, not just once when they cross a stage gate.
local QUIP_REPEAT_MS = 180000  -- 3 minutes

-- Map a moodle level to a quip tier name.
local function tierFor(level)
    if level <= 1 then return "onset"
    elseif level == 2 then return "worsening"
    else return "critical" end
end

-- Texture cache: texBase .. level -> Texture (getTexture is the heavy call).
local texCache = {}
local function badgeTex(texBase, level)
    local path = texBase .. level
    local t = texCache[path]
    if t == nil then
        t = getTexture("media/textures/" .. path .. ".png") or false
        texCache[path] = t
    end
    return t or nil
end

local prevLevel = { cold = 0, hot = 0, blood = 0 }
local lastQuip  = { cold = 0, hot = 0 }  -- ms of last quip per temperature signal
local lastPoll  = 0

local function clearAll()
    LRDangerHUD.badges = {}
    for s = 1, #SIGNALS do LRDangerMoodle.clear(SIGNALS[s].key) end
    prevLevel.cold, prevLevel.hot, prevLevel.blood = 0, 0, 0
    lastQuip.cold, lastQuip.hot = 0, 0
end

local function update()
    local player = getPlayer()
    if not player then clearAll() return end

    local now = getTimestampMs()

    if not LRPrefs.get("lr_danger_enabled", true) then
        clearAll()
        return
    end

    LRDangerHUD.overheadYAdjust = LRPrefs.get("lr_overhead_yadjust", 0)
    local quipsOn = LRPrefs.get("lr_danger_quips", true)
    local shakeOn = LRPrefs.get("lr_danger_shake", true)
    local moodles = player:getMoodles()

    local overheadBadges = {}
    local sidebarSlot, overheadSlot = 0, 0

    for s = 1, #SIGNALS do
        local sig   = SIGNALS[s]
        local mType = MoodleType[sig.moodle]
        local level = mType and moodles:getMoodleLevel(mType) or 0
        local shown = LRPrefs.get(sig.pref, true)

        if shown and level >= 1 then
            local tex   = badgeTex(sig.texBase, level)
            local shake = "none"
            if shakeOn then shake = (level >= 4) and "continuous" or "pulse" end
            if level >= sig.overheadFrom then
                -- Over-head: world-projected stencil badge.
                LRDangerMoodle.clear(sig.key)
                overheadBadges[#overheadBadges + 1] = { tex = tex, shake = shake, slot = overheadSlot }
                overheadSlot = overheadSlot + 1
            else
                -- Sidebar: real moodle widget (RQMoodle pattern).
                LRDangerMoodle.set(sig.key, tex, shake, sidebarSlot, level)
                sidebarSlot = sidebarSlot + 1
            end
        else
            LRDangerMoodle.clear(sig.key)
        end

        -- Quips (temperature signals only). Our own over-head renderer
        -- (LRDangerHUD), not HaloTextHelper - it lasts a controlled duration and
        -- never gets swallowed by the engine halo queue. Fire on a fresh
        -- escalation (level climbed) AND then every QUIP_REPEAT_MS while the
        -- signal persists, so the warning keeps nagging rather than going quiet.
        if sig.quip then
            if level >= 1 then
                local escalated = level > prevLevel[sig.key]
                local due       = now - lastQuip[sig.key] >= QUIP_REPEAT_MS
                if quipsOn and (escalated or due) then
                    local line = LRDangerQuips.pick(sig.quip .. "_" .. tierFor(level))
                    if line then LRDangerHUD.showQuip(line); lastQuip[sig.key] = now end
                end
            else
                lastQuip[sig.key] = 0  -- cleared: re-onset should quip immediately
            end
        end
        prevLevel[sig.key] = level
    end

    LRDangerHUD.badges = overheadBadges
end

Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastPoll < POLL_MS then return end
    lastPoll = now
    LRDangerHUD.ensure()
    -- guarded to REPORT, not to contain: the print below is the point. Without it a
    -- poll fault is one more line in a log nobody reads.
    local ok, err = pcall(update)
    if not ok then print("[LRDanger] update error: " .. tostring(err)) end
end)

Events.OnGameStart.Add(clearAll)

-- Exposed so the Danger panel can force an immediate re-evaluation.
LRDanger.update = update

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
