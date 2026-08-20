-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPlayersTab_Server - handlers for the Players tab.
--
-- One server-side action:
--   playersList  - snapshot online players for the tab list
--
-- Kick / ban / teleport stay client-side via SendCommandToServer chat
-- commands (matches DFScoreboard's pattern). Vanilla already permission-gates
-- those server-side, and the client emits a parallel auditOnly event so the
-- audit line still broadcasts to every admin's Console tab.
--
-- setRoleForUser was deliberately removed along with the tab's role dropdown:
-- in-panel role assignment double-dutied with vanilla's role management,
-- leaving two sources of truth for a player's role. NOTE: DFPlayerRoles_Server
-- stays - existing assignments in Dragonfly_PlayerRoles.txt still re-apply on
-- connect, and deleting that engine before migrating them to vanilla's DB
-- would silently revert those players' roles.

if not isServer() then return end

-- `field = "players"` keeps the wire shape the client already reads.
if RDChunk then
    RDChunk.declare(DFCore.MODULE, "PlayersList",
        { budget = 3072, envelope = 240, maxRows = 60, field = "players" })
end

-- getRole (IsoPlayer:6987) and Role.getName (:47) are field returns.
local function roleName(target)
    local role = target:getRole()
    local name = role and role:getName()
    return name or "-"
end

-- IsoPlayer.getAccessLevel:6983 null-checks the role and answers "none" itself.
local function accessLevel(target)
    return target:getAccessLevel() or "none"
end

-- isGodMod / isInvisible are PlayerCheats EnumSet reads
-- (IsoGameCharacter:11023 / :10943) - cannot throw.
local function isGod(target)
    return target:isGodMod()
end

local function isInvis(target)
    return target:isInvisible()
end

-- The old guard named the right hazard and then stood in for the precondition
-- instead of establishing it. The chain, read out: getDisplayName
-- (IsoPlayer.java:7343) calls getUsername(showFirstAndLastName,
-- hideDisguisedUserName || usernameDisguises); the second argument being true is
-- what reaches updateDisguisedState (:6001), which returns immediately unless one
-- of those two options is set (IsoGameCharacter.java:14130) and otherwise derefs
-- the TARGET's role at :14138 - reachable only inside a safehouse with
-- safehouseDisableDisguises on. The camera-character deref at :6010 is behind
-- GameClient.client and cannot fire here.
--
-- role is field-initialized (IsoPlayer.java:354) from Roles.defaultForNewUser, a
-- plain static that is null until setRoles runs - which is why the engine
-- null-checks it itself at :6984. So it is nullable, and getRole() (:6987) is a
-- field return that answers the question directly. Check it and call bare.
local function displayName(target)
    if not target:getRole() then return target:getUsername() end
    local name = target:getDisplayName()
    if name and name ~= "" then return name end
    return target:getUsername()
end

local function serializePlayer(target)
    local x, y, z = target:getX(), target:getY(), target:getZ()
    return {
        username = target:getUsername(),
        display  = displayName(target),
        role     = roleName(target),
        access   = accessLevel(target),
        god      = isGod(target),
        invis    = isInvis(target),
        x = math.floor(x), y = math.floor(y), z = math.floor(z),
    }
end

-- DFServer.lua loads after this file alphabetically (P < S), so DFServer is
-- nil at top-of-file execution. Defer registration until the whole server
-- script set has loaded. OnServerStarted is the right gate - clients can't
-- send commands until after it fires anyway.
Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] DFPlayersTab_Server: DFServer missing, handlers not registered")
        return
    end

    DFServer.registerHandler{
        action     = "playersList",
        capability = Capability.KickUser,
        run = function(player, args)
            local out = {}
            local players = getOnlinePlayers()
            if players then
                for i = 0, players:size() - 1 do
                    local p = players:get(i)
                    if p then out[#out + 1] = serializePlayer(p) end
                end
            end
            -- PAGED SINCE 2026-08-09. Not flagged in the 2026-08-08 capture -
            -- 4,093 B average, 4,696 B largest, inside the 8 KB ceiling - but this
            -- payload is one row per ONLINE PLAYER, so its size is set by the
            -- server's population and the capture was not taken at peak. At the
            -- 39 players this server actually runs it is several times the size
            -- that was measured, which puts it past the ceiling on the roster
            -- alone. Paging it now costs nothing and removes the cliff.
            if RDChunk then
                RDChunk.send(player, DFCore.MODULE, "PlayersList", out,
                    { total_players = #out })
            else
                sendServerCommand(player, DFCore.MODULE, "PlayersList",
                    { players = out })
            end
            return { ok = true }  -- silent success; PlayersList drives UI
        end,
    }

    -- setAccessLevelForUser used to live here, but server-side
    -- target:setAccessLevel doesn't persist to the whitelist DB - on
    -- reconnect vanilla snapped them back to the saved access. Client now
    -- routes access changes through `SendCommandToServer("/setaccesslevel ...")`
    -- instead so vanilla's command handler does the DB write. No handler
    -- here; the client emits auditOnly so the action still broadcasts to
    -- every admin's Console tab.

    print("[Dragonfly] DFPlayersTab_Server handlers registered")
end)

print("[Dragonfly] DFPlayersTab_Server loaded (registration deferred to OnServerStarted)")

-- Dragonfly v0.2.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
