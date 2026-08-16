-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMRestrictShared - the zone-flag lookup both restriction halves ask.
--
-- LMRestrictCl (client, the surfaces a player touches) and LMRestrictSv
-- (server, the authority) answer the same question - "does the zone covering
-- this square set this flag?" - and ran identical copies of it. A restriction
-- whose client and server halves can disagree is worse than no restriction:
-- the player is told one thing and the server does another.
--
-- Reads the RESOLVED store, so a child zone inherits its parent's restrictions
-- exactly the way every other field inherits.
--
-- Returns (denied, zoneName) so a refusal can NAME the zone - "you cannot build
-- here" invites an argument, "Sunstar Motel does not allow building" ends it.

require "LMCore"

LMRestrictShared = LMRestrictShared or {}

function LMRestrictShared.denied(x, y, flag)
    if not x or not y then return false, nil end
    -- pcall stays: both callers run this INSIDE a wrapped vanilla action, so a
    -- throw in the store walk would break that action rather than just the flag.
    local ok, zone = pcall(Limes.getLocation, math.floor(x), math.floor(y))
    if not ok or not zone or not zone.fields then return false, nil end
    if zone.fields[flag] == true then return true, zone.name end
    return false, nil
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
