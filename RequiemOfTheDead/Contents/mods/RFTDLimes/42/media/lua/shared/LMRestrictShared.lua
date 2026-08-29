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
require "RDAccess"

LMRestrictShared = LMRestrictShared or {}

function LMRestrictShared.denied(x, y, flag)
    if not x or not y then return false, nil end
    -- This is Limes' own validated spatial index, not a foreign callback. An
    -- absent zone is its normal nil result; a broken store must fail visibly
    -- rather than silently turning a server-side restriction into allow.
    local zone = Limes.getLocation(math.floor(x), math.floor(y))
    if not zone or not zone.fields then return false, nil end
    if zone.fields[flag] == true then return true, zone.name end
    return false, nil
end

-- ---------------------------------------------------------------------------
-- The pass list (noplayersPass, 2026-08-27): "no players, except these".
--
-- A token matches the player's ROLE NAME (case-insensitive - "Moderator" and
-- "moderator" are the same claim; Role.getName, Role.java:47) or a role
-- CAPABILITY resolved through RDAccess (Role.hasCapability, Role.java:187).
-- Both are checked so an admin can grant passage the way their server is
-- actually organised - by the role they built or by the power it carries.
--
-- DEFAULT DENY (§12): no player, no role, an empty list, junk tokens - none
-- of them open the gate. A token that matches nothing is simply a token that
-- matches nothing; validate() does not police it because role names are the
-- server's, not the store's.
-- ---------------------------------------------------------------------------

function LMRestrictShared.passes(player, passList)
    if not player or type(passList) ~= "string" or passList == "" then return false end
    local role = player.getRole and player:getRole() or nil
    local roleName = role and role.getName and role:getName() or nil
    if roleName then roleName = tostring(roleName):lower() end
    for tok in passList:gmatch("[^,]+") do
        tok = tok:match("^%s*(.-)%s*$")
        if tok ~= "" then
            if roleName and tok:lower() == roleName then return true end
            if RDAccess.roleHas(player, tok) then return true end
        end
    end
    return false
end

-- The per-player question: denied, unless the zone's own pass list clears
-- this player. Only `noplayers` carries an exemption - the other flags gate
-- ACTIONS, and an admin who may pass a boundary does not thereby get to
-- sledge inside it.
function LMRestrictShared.deniedFor(player, x, y, flag)
    local no, zoneName = LMRestrictShared.denied(x, y, flag)
    if not no then return false, nil end
    if flag == "noplayers" then
        local z = Limes.getZone(zoneName)
        local pass = z and z.fields and z.fields.noplayersPass
        if pass and pass ~= "" and LMRestrictShared.passes(player, pass) then
            return false, nil
        end
    end
    return true, zoneName
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
