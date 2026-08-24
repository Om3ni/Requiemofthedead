-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDVarsPush - replicates each player's OWN variables to their client.
--
-- The other half of RDVarsMirror (client). RDVars is the store and stays
-- wire-free; this file subscribes to its touch seam and owns everything about
-- the wire: who gets a push, when, and what rides in it.
--
-- THE PROTOCOL IS FULL-DOCUMENT REPLACE. A player's document is a handful of
-- flags and counters - well under a hundred bytes - so a delta protocol would
-- be complexity spent saving nothing. Every push is RDVars.mirrorOf(user),
-- whole, and the client swaps its cache wholesale.
--
-- WHEN A PUSH HAPPENS:
--   on any mutation of a player's record   RDVars.onTouched, one targeted send
--   on any connect-ish event               everyone online, re-pushed
--
-- The connect push sweeps ALL online players rather than resolving the event's
-- argument, for the reason DFPlayerRoles_Server.lua:227-229 states: the
-- connect events disagree about arg shape, and a sweep of tiny documents is
-- cheaper than being wrong about one of them. Re-pushing a player who already
-- has their document is harmless - the replace is idempotent.
--
-- No pcall anywhere: sendServerCommand returns early for a player with no
-- mapped connection (GameServer.java:3256, already cited by RDChunk.lua:297),
-- and an exposed Java method body cannot throw into Lua.

if not isServer() then return end

require "RDShared"
require "RDVars"

RDVarsPush = RDVarsPush or {}

-- The server->client module token for Core's own pushes. Client filter is
-- RDVarsMirror.lua; the pair must agree, so both name it once at the top.
local MODULE  = "RFTDCore"
local COMMAND = "VarsMine"

-- The online player object for a username, or nil. A linear walk, at event
-- cadence, over the online list - the same idiom DFVars_Server.onlineNames
-- uses, and not worth an index for a list this size.
local function onlinePlayer(user)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getUsername and tostring(p:getUsername()) == user then
            return p
        end
    end
    return nil
end

-- Push one player's document, if they are online. An offline player is not an
-- error - they get theirs from the connect sweep when they arrive.
function RDVarsPush.push(user)
    if type(user) ~= "string" or user == "" then return false end
    local p = onlinePlayer(user)
    if not p then return false end
    local doc = RDVars.mirrorOf(user)
    if not doc then return false end
    sendServerCommand(p, MODULE, COMMAND, doc)
    return true
end

-- Everyone online. The connect events' handler, and cheap enough that being
-- called once per event flavour on the same join does not matter.
function RDVarsPush.pushAll()
    local players = getOnlinePlayers()
    if not players then return 0 end
    local sent = 0
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local user = p and p.getUsername and tostring(p:getUsername())
        if user then
            local doc = RDVars.mirrorOf(user)
            if doc then
                sendServerCommand(p, MODULE, COMMAND, doc)
                sent = sent + 1
            end
        end
    end
    return sent
end

RDVars.onTouched = function(user) RDVarsPush.push(user) end

-- The connect-event lottery, played the way the suite already plays it:
-- register on whichever of the four exists on this build (StaffTools'
-- DFPlayerRoles_Server.lua:240-243; Dirge's RQServer.lua:1313 documents that
-- OnClientConnect is null on B42 dedicated servers). Duplicate fires are
-- harmless - the push is idempotent.
local bound = {}
local function tryBind(eventName)
    local ev = Events[eventName]
    if ev and ev.Add then
        ev.Add(function() RDVarsPush.pushAll() end)
        bound[#bound + 1] = eventName
    end
end
tryBind("OnPlayerConnect")
tryBind("OnClientConnect")
tryBind("OnConnected")
tryBind("OnCreatePlayer")

if #bound > 0 then
    print("[RFTDCore] RDVarsPush: mirror push bound to "
        .. table.concat(bound, ", "))
else
    print("[RFTDCore] WARNING: RDVarsPush found no connect event; clients "
        .. "will only receive their variables after the first change to them.")
end

return RDVarsPush

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
