-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDTeleport.lua - the family's one way to move an admin to a coordinate.
--
-- WHY THIS EXISTS: three call sites had grown their own copy of the same chat
-- command - Longstrider's tour runner, Reclamation's "Go to placement", and
-- Limes' zone probe was about to be the third - and they had already drifted
-- apart on the thing that matters most. LSTour gates on
-- Capability.TeleportToCoordinates; RCJanitorView gated on a blunt isAdmin()
-- instead. Two answers to "who may move themselves across the map" is one too
-- many, and the looser one wins by accident the moment someone copies the
-- nearest example.
--
-- WHY A CHAT COMMAND AND NOT setX/setY: /teleportto is SERVER authoritative.
-- It re-checks the caller's access level server-side and streams the
-- destination chunks in. Moving the player locally would be rubber-banded by
-- the server on a dedicated host, which is the only place any of these callers
-- matter. So the client-side capability check here is UX - it explains the
-- refusal instead of letting the server swallow it - and the server's own check
-- is the actual gate. Never treat this function as the security boundary.
--
-- Returns (ok, reason) rather than raising or notifying: the callers differ in
-- how they report (DFFeedback, a status line, a tab notification), so the
-- message is handed back rather than chosen here.

if isServer() then return end

RDTeleport = RDTeleport or {}

-- The vanilla command takes integers; a fractional tile silently does nothing
-- useful, so floor at the boundary rather than trusting every caller to.
function RDTeleport.toCoords(x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z or 0)
    if not x or not y then
        return false, "Teleport needs numeric coordinates."
    end

    local player = getPlayer()
    if not player then
        return false, "No local player."
    end
    if RDAccess and RDAccess.roleHas
        and not RDAccess.roleHas(player, Capability.TeleportToCoordinates) then
        return false, "You lack the Teleport-to-coordinates capability."
    end

    SendCommandToServer(string.format("/teleportto %d,%d,%d",
        math.floor(x), math.floor(y), math.floor(z or 0)))
    return true
end

-- Convenience for the common "can I even offer this button" question, so a UI
-- can disable rather than let the press fail.
function RDTeleport.allowed()
    local player = getPlayer()
    if not player then return false end
    if not RDAccess or not RDAccess.roleHas then return true end
    return RDAccess.roleHas(player, Capability.TeleportToCoordinates) and true or false
end

return RDTeleport

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
