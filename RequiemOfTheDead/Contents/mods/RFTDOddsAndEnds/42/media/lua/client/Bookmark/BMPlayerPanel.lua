-- SPDX-License-Identifier: GPL-3.0-or-later
-- BMPlayerPanel.lua  (client)
--
-- Bookmark's one switch - "Welcome Message", default OFF - on the family's
-- player panel, where player-facing config lives.
--
-- THIRD HOME, PERMANENT THIS TIME. The switch lived on the vanilla Client
-- panel (BMUserPanel.lua, retired 2026-08-08 - hand-placed rows in a shared
-- panel collide with other mods' and cannot be made collision-proof), then on
-- PZAPI.ModOptions (BMModOptions.lua, retired the same week it was born -
-- that berth was declared a stopgap the day the player panel was decided).
-- The player panel is the family's own surface: every mod gets its section by
-- registration, nothing contends for coordinates, and the toggle sits IN the
-- game where a player actually is - not behind ESC.
--
-- The ModOptions retirement also closes a real staleness hole: its tick-box
-- seeded from OEPrefs once, at file load, so a change made through any OTHER
-- surface would be silently reverted by the next unrelated Accept on the
-- options screen. The panel's sheet reads through get() live and has no
-- Accept step, so there is nothing to go stale.
--
-- REGISTRATION, not UI: schema + get/set against Bookmark's own switch, and
-- DFForm draws the row. The schema is a function so getText runs at
-- panel-open, when translations are certain. OEPrefs stays the single owner
-- BMClient reads; this file stays the only one that knows where the toggle
-- lives. Guarded like every DFRegistry registration in the family: no
-- Dragonfly, no surface, and O&E still ships.

if isServer() then return end

require "Bookmark/BMClient"   -- explicit: isEnabled/setEnabled must not ride on load order

Events.OnGameBoot.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerSettings) then return end

    Dragonfly.registerPlayerSettings{
        id     = "oddsandends",
        title  = getText("IGUI_OE_ModName"),
        order  = 30,
        schema = function()
            return {
                { key = "bookmarkEnabled", kind = "bool",
                  label = getText("IGUI_OE_BookmarkEnable"),
                  help  = getText("IGUI_OE_BookmarkBlurb") .. "\n\n"
                       .. getText("IGUI_OE_BookmarkTip") },
            }
        end,
        get = function(k)
            if k == "bookmarkEnabled" then return Bookmark.isEnabled() end
        end,
        set = function(k, v)
            if k == "bookmarkEnabled" then Bookmark.setEnabled(v == true) end
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
