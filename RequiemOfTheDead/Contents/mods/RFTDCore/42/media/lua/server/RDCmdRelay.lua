-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDCmdRelay.lua - live client-command feed to staff consoles (server only).
--
-- Guardian records every inbound client command to the forensic ring, which is
-- perfect forensics and useless for watching. This relays a BOUNDED, FILTERED
-- subset to staff clients so it lands in Dragonfly's Console tab as it happens.
--
-- IT IS A TRIPWIRE, NOT A GATE, and the distinction is engine-imposed rather than
-- a design choice. Verified in the 42.20 decompile: GameServer.receiveClientCommand
-- fires LuaEventManager.triggerEvent("OnClientCommand", ...) as its LAST act
-- (GameServer.java:2141), triggerEvent returns void, and every engine-side gate -
-- the CCFilter, and the Capability.GeneralCheats check on vehicle.remove
-- (:2135) - has already run and returned. By the time Lua hears about a command
-- the server has accepted it. Nothing here can refuse one; it can only make one
-- visible while an admin is looking. Do not add a "block" option to this file.
--
-- NO SECOND LISTENER. RDGuardian's header is explicit about why: OSN registered
-- its own OnClientCommand handler purely to size payloads, which put a second
-- callback on the hottest event in the game to walk a table Guardian already had.
-- That mistake is not repeated here. RDGuardian calls RDCmdRelay.offer() from
-- inside its existing handler, behind an `if RDCmdRelay then` guard - the same
-- removable-file idiom as MMAudit. Delete this file and the feed disappears with
-- no other edit.
--
-- DEFAULT OFF (RFTDCore.CmdRelayEnabled). OnClientCommand is a firehose: every
-- inventory transaction, every action sync, from every player. Armed, the cost is
-- ONE batched packet per flush window per staff recipient - not one per command -
-- because per-command sends would be the single most expensive thing Core does.
--
-- BOUNDED THREE WAYS, because an unbounded admin feed is a self-inflicted DoS:
--   * scope filter, applied before buffering (see CmdRelayScope)
--   * hard cap per flush window; overflow is COUNTED and reported, never silently
--     dropped - a feed that quietly truncates reads as a quiet server
--   * fixed flush throttle, so N commands in a second cost one packet
--
-- Recipients are resolved at FLUSH time, not per command: a getOnlinePlayers walk
-- plus a capability check per command would defeat the point of batching.

if not isServer() then return end

require "RDShared"

RDCmdRelay = RDCmdRelay or {}

local FLUSH_MS   = 1000
local HARD_CAP   = 40     -- entries per flush window, before we start counting drops
local CMD_MAXLEN = 120    -- module:command display cap; args are NOT relayed (see below)

local cfg          = nil
local buf          = {}
local dropped      = 0
local lastFlushMs  = 0

local function sb(key, default)
    local v
    local ok = pcall(function() v = SandboxVars.RFTDCore and SandboxVars.RFTDCore[key] end)
    if not ok or v == nil then return default end
    return v
end

local function resolveConfig()
    -- scope: 1 = non-staff only (the Guardian detection domain - a privileged
    -- command from an unauthorised account is the offence), 2 = staff only (audit
    -- what your own admins did), 3 = everything (debugging, expect volume).
    local scope = tonumber(sb("CmdRelayScope", 1)) or 1
    if scope < 1 or scope > 3 then scope = 1 end
    return {
        enabled = (sb("CmdRelayEnabled", false) == true),
        scope   = scope,
    }
end

-- Cheap staff test. RDAccess.hasAnyCapability is the "any staff" notion the family
-- already uses; isTopAdmin alone would miss capability-granted roles.
local function isStaff(player)
    if not RDAccess then return false end
    local ok, v = pcall(function()
        return RDAccess.isTopAdmin(player) or RDAccess.hasAnyCapability(player)
    end)
    return ok and v == true
end

-- ---------------------------------------------------------------------------
-- Hot path. Called once per client command from RDGuardian's handler, so it must
-- do as little as possible and never throw.
-- ---------------------------------------------------------------------------

function RDCmdRelay.offer(module, command, player, access, est)
    if not cfg or not cfg.enabled then return end

    local staff = isStaff(player)
    if cfg.scope == 1 and staff then return end
    if cfg.scope == 2 and not staff then return end

    if #buf >= HARD_CAP then
        dropped = dropped + 1
        return
    end

    local label = tostring(module) .. ":" .. tostring(command)
    if #label > CMD_MAXLEN then label = label:sub(1, CMD_MAXLEN) .. "~" end

    buf[#buf + 1] = {
        u = (player and player.getUsername and player:getUsername()) or "?",
        c = label,
        a = tostring(access or ""),
        e = tonumber(est) or 0,
        s = staff and 1 or 0,
    }
end

-- ---------------------------------------------------------------------------
-- Flush
-- ---------------------------------------------------------------------------
--
-- Args are deliberately NOT relayed. Guardian already puts the full serialised
-- arg table in the forensic ring, which is the right home for it: args are
-- unbounded client input, they are the bulk of a command's wire cost, and pushing
-- them to every staff client turns a monitoring feature into an amplifier. The
-- console answers "who is sending what, right now"; the ring answers "what
-- exactly did they send".

local function flush()
    if #buf == 0 and dropped == 0 then return end

    local payload = { n = #buf, dropped = dropped, rows = buf }
    buf, dropped = {}, 0

    local ok, players = pcall(getOnlinePlayers)
    if not ok or not players then return end

    pcall(function()
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and isStaff(p) then
                sendServerCommand(p, RDShared.MODULE, "cmdRelay", payload)
            end
        end
    end)
end

Events.OnTick.Add(function()
    if not cfg then
        cfg = resolveConfig()
        if cfg.enabled then
            print("[RFTDCore] RDCmdRelay armed: scope=" .. tostring(cfg.scope)
                .. ", <=" .. HARD_CAP .. " cmds per " .. (FLUSH_MS / 1000)
                .. "s to staff consoles (args NOT relayed - see the forensic ring).")
        end
        return
    end
    if not cfg.enabled then return end

    local now = RDShared.nowMs()
    if now == 0 then return end
    if now - lastFlushMs < FLUSH_MS then return end
    lastFlushMs = now
    flush()
end)

return RDCmdRelay

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
