-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFAdminTab - a reserved slot in the roster. Nothing behind it yet.
--
-- WHY REGISTER AN EMPTY TAB AT ALL. Tab order is sorted (DFRegistry.getTabs),
-- so the position a tab lands in is decided by every OTHER tab's `order` as
-- much as its own. Adding a real tab later would shuffle whatever currently
-- sits at 30+ sideways, and the roster is something admins learn by muscle
-- memory. Claiming the slot now means the day Admin ships, nothing else moves.
--
-- It is inert by construction: no `build`, so there is no panel to keep
-- working, no scan to keep cheap, and no state to keep in sync. The whole cost
-- of this file is one greyed word in the nav.
--
-- BOTH SHELLS ALREADY KNEW HOW TO GREY A ROW - the classic panel via
-- ISButton.enable and the deck by drawing !enabled rows in scar instead of ash
-- - because a per-player `capability` check needed exactly that. `disabled`
-- rides the same path; see DFRegistry.isSelectable for why the two are kept
-- distinct rather than folded together.

if isServer() then return end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    -- No guard. Core is a HARD dependency, not the "foreign-mod API" the old
    -- comment claimed, and registerTab is a validated assignment: a nil or
    -- id-less spec is refused with a print, anything else is a table write
    -- (DFRegistry.lua:23-30). Husbandry's host-tab slice removed this exact
    -- wrapper on that reading. "Must not kill this OnGameStart listener" was
    -- never a reason either - the engine already contains each listener in its
    -- own try/catch (Event.java:53-63).
    DFRegistry.registerTab{
        id       = "admin",
        label    = "Admin",
        -- Deck nav order, one decision 2026-08-18: Admin 10, Players 20,
        -- Necro 30, Vehicles 40, Husbandry 50, Longstrider 60, Zones 70,
        -- Console 1000 (always last). Spaced by ten so a new tab can land
        -- between two without renumbering five files across five mods.
        order    = 10,
        disabled = true,
        -- No build. Adding one is the entire remaining task, and until
        -- then the shells refuse to select this id at all.
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
