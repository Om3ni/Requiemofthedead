-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQRegistry - client-side special zombie roster
-- Keyed by onlineID integer, not zombie object.
-- Server is the only writer (via RQCore broadcast handlers).
-- Survives chunk unloads and teleports.

RQRegistry = RQRegistry or {}

-- All valid naturally-spawning special zombie types (excludes Boss)
RQRegistry.TYPES = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger" }

-- modData key constants
RQRegistry.KEY_TYPE      = "RQType"
RQRegistry.KEY_CONVERTED = "RQConverted"

-- onlineID (int) -> zType string
-- plain table, no weak keys (IDs are integers, not objects)
RQRegistry.activeZombies = RQRegistry.activeZombies or {}

function RQRegistry.register(onlineID, zType)
    RQRegistry.activeZombies[onlineID] = zType
end

function RQRegistry.unregister(onlineID)
    RQRegistry.activeZombies[onlineID] = nil
end

function RQRegistry.getType(onlineID)
    return RQRegistry.activeZombies[onlineID]
end

function RQRegistry.isSpecial(onlineID)
    return RQRegistry.activeZombies[onlineID] ~= nil
end

function RQRegistry.resetAll()
    RQRegistry.activeZombies = {}
end

Events.OnGameStart.Add(RQRegistry.resetAll)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
