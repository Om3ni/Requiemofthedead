-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRPlayerPanel.lua  (client)
--
-- Last Rites' cosmetic toggles on the family's player panel: the danger
-- indicators master switch, the per-signal switches, the over-head thought
-- quips, the icon shake, and the over-head height calibration. Registration
-- only - schema + get/set against LRPrefs - the panel's sheet draws the rows
-- and no UI code lives here.
--
-- SAME DIALS AS LRHub's DANGER TAB, deliberately, and LRHub stays for now:
-- both surfaces read and write LRPrefs live (the hub seeds its tick-boxes
-- when its window opens), so they cannot go stale against each other. The
-- family direction is that the player panel becomes THE home for these and
-- the hub's Client-panel button retires - LRUserPanelHook's top-insert is a
-- politer version of the same hand-placed-row disease that killed Bookmark's
-- checkbox - but that retirement is its own decision, not a rider on this
-- registration.
--
-- Changes apply immediately: set() writes the pref and pokes LRDanger.update,
-- exactly as the hub's handlers do. The schema is a function so getText runs
-- at panel-open, when translations are certain.

if isServer() then return end

-- Display order mirrors the hub's Danger tab, master switch first.
local TOGGLES = {
    { key = "lr_danger_enabled", default = true, label = "IGUI_LR_Danger_Enabled" },
    { key = "lr_danger_cold",    default = true, label = "IGUI_LR_Danger_Cold" },
    { key = "lr_danger_hot",     default = true, label = "IGUI_LR_Danger_Hot" },
    { key = "lr_danger_blood",   default = true, label = "IGUI_LR_Danger_Blood" },
    { key = "lr_danger_quips",   default = true, label = "IGUI_LR_Danger_Quips" },
    { key = "lr_danger_shake",   default = true, label = "IGUI_LR_Danger_Shake" },
}

local Y_KEY  = "lr_overhead_yadjust"
local Y_STEP = 8      -- the hub's nudge increment, kept so both surfaces
local Y_MIN  = -300   -- land on the same values
local Y_MAX  = 300

local defaults = { [Y_KEY] = 0 }
for i = 1, #TOGGLES do defaults[TOGGLES[i].key] = TOGGLES[i].default end

Events.OnGameBoot.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerSettings) then return end

    Dragonfly.registerPlayerSettings{
        id     = "lastrites",
        title  = getText("IGUI_LR_Panel"),
        order  = 20,
        schema = function()
            local s = {}
            for i = 1, #TOGGLES do
                local t = TOGGLES[i]
                s[#s + 1] = { key = t.key, kind = "bool", label = getText(t.label) }
            end
            s[1].help = getText("IGUI_LR_Danger_Hint")
            s[#s + 1] = { key = Y_KEY, kind = "int",
                min = Y_MIN, max = Y_MAX, step = Y_STEP, unit = "px",
                label = getText("IGUI_LR_Danger_OverheadY"),
                help  = "Where the over-head warnings and thoughts sit above your character. Projection alignment varies with zoom and resolution, so this is a calibration you set once for your screen rather than a number with one right answer.\n\nPositive values raise them, negative values lower them." }
            return s
        end,
        get = function(k)
            return LRPrefs.get(k, defaults[k])
        end,
        set = function(k, v)
            if k == Y_KEY then
                v = tonumber(v) or 0
                if v < Y_MIN then v = Y_MIN elseif v > Y_MAX then v = Y_MAX end
                LRPrefs.set(k, v)
                -- The HUD field the hub's nudge writes directly; update()
                -- below re-reads it too, so this is belt and braces.
                if LRDangerHUD then LRDangerHUD.overheadYAdjust = v end
            else
                LRPrefs.set(k, v == true)
            end
            if LRDanger and LRDanger.update then LRDanger.update() end
        end,
    }
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
