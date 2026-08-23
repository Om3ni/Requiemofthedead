-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFVars_Server - the admin surface for RDVars.
--
-- RDVars (Core) owns definitions, per-player state, expiry and death. This file
-- is the only thing that lets a human reach any of it, and it owns exactly two
-- questions: who may, and does the answer say so afterwards.
--
-- ---------------------------------------------------------------------------
-- THIS IS NOT A PLAYER SURFACE, AND ADDING IT DOES NOT MAKE ONE.
--
-- RDVars' header states the boundary and it is worth restating where it could
-- erode: vars are never exposed to PLAYERS. No chat reply reads one back, no
-- tooltip mentions one, nothing a player can send reaches this file. A player
-- learns they were part of something by what a kit gives them.
--
-- Every command below is capability-gated staff-only, and RDVars still has no
-- client half of its own - the reads here are performed on the server and the
-- ANSWERS are pushed, so a client never gets a handle on the store. That is the
-- distinction that keeps the original decision intact: an admin panel is a
-- staff surface that happens to run on a client, not a client API.
--
-- ---------------------------------------------------------------------------
-- WHO MAY, and this is the part to argue with rather than assume.
--
-- The engine's Capability enum (Capability.java:9-107) has no name for "manage
-- a mod's state" - ManipulateMods gates exactly one command, a mod-update check
-- (CheckModsNeedUpdate.java:17) - so no capability is a clean fit and pretending
-- one is would be precision theatre. The gate is therefore split by what the
-- action actually touches, the same way the layout overlay's is:
--
--   define / undefine   ChangeAndReloadServerOptions. A definition is
--                       server-wide schema: it changes what this world can
--                       express, and undefining PURGES every player's holding
--                       of it. That is the strictest gate this panel uses and
--                       it is the right one for an irreversible server-wide act.
--
--   grant / revoke      CanModifyPlayerStatsInThePlayerStatsUI. This is the
--   set / reset         engine's own gate for an admin changing another
--                       player's character state - it is what PlayerXpPacket
--                       requires (PlayerXpPacket.java:20) and what
--                       GameServer.java:1309 tests before letting one player
--                       edit another's stats. Granting a marker is that act.
--
--   reading             any staff capability. A var name and a holder list are
--                       operational data, not secrets, and a panel that cannot
--                       show you the state before you change it is worse than
--                       one that shows it to a moderator.
--
-- The alternative - an operator-set access TIER in sandbox, which is what Dirge
-- does for the same shape of problem (RDNet.lua:33-38) - is deliberately not
-- taken here: a new sandbox option is a compatibility decision and this slice
-- did not have approval for one. Filed in TODO.md so the choice stays open.
--
-- ---------------------------------------------------------------------------
-- TARGETS ARE USERNAMES, AND A USERNAME OFF THE WIRE IS A TABLE KEY.
--
-- RDVars keys by username and accepts a bare string, which is correct for its
-- own purposes - an admin must be able to grant a marker to the person who won
-- last night's event whether or not they are online right now. It does mean an
-- unbounded string from a client becomes a record in the store, so the bound is
-- applied HERE, at the door, rather than in Core: length, and nothing below
-- space. Not an existence check, because "must be online" would break the
-- legitimate case above.

if not isServer() then return end

require "RDShared"
require "RDVars"
require "RDVarDefs"

DFVars_Server = DFVars_Server or {}

local USER_MAX = 64

local CAP_SCHEMA = "ChangeAndReloadServerOptions"
local CAP_PLAYER = "CanModifyPlayerStatsInThePlayerStatsUI"

-- ---------------------------------------------------------------------------
-- Input at the door
-- ---------------------------------------------------------------------------

function DFVars_Server.validUser(name)
    if type(name) ~= "string" then return false end
    if #name == 0 or #name > USER_MAX then return false end
    -- Control characters would travel into the store's keys, the JSON mirror
    -- and the audit line, and each of those three reads them differently.
    if name:find("%c") then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Reads
--
-- Assembled on the SERVER and pushed as answers. A client is never handed
-- anything it could walk back into the store.
-- ---------------------------------------------------------------------------

-- Every definition, with the one number an admin actually wants beside it:
-- how many people hold it. Counted here rather than sent as a holder list -
-- a marker granted to two hundred event attendees is a list nobody reads and
-- a packet nobody needs.
function DFVars_Server.summary()
    local out = {}
    for _, def in ipairs(RDVars.definitions()) do
        local row = {
            key          = def.key,
            name         = def.name,
            kind         = def.kind,
            by           = def.by,
            createdMs    = def.createdMs,
            resetOnDeath = def.resetOnDeath,
            permanent    = RDVarDefs.isPermanent(def),
            revokers     = def.revokers,
        }
        if RDVarDefs.isChar(def) then
            local holders = RDVars.holders(def.name)
            row.holders = holders and #holders or 0
        end
        out[#out + 1] = row
    end
    return out
end

local function pushSummary(player)
    sendServerCommand(player, DFCore.MODULE, "AdminVars", { defs = DFVars_Server.summary() })
end

local function pushPlayer(player, user)
    sendServerCommand(player, DFCore.MODULE, "AdminVarsPlayer", RDVars.ofPlayer(user))
end

-- ---------------------------------------------------------------------------
-- Wire
--
-- DFServer.lua sorts after this file in the server's tier walk, so registration
-- waits for OnServerStarted. Same trap as DFOverlay_Server and the two tab
-- servers before it.
-- ---------------------------------------------------------------------------

Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] DFVars_Server: DFServer missing, handlers not registered")
        return
    end

    -- Every handler below registers with NO dispatcher capability and gates
    -- itself, because two of the three gates differ from each other and the
    -- dispatcher takes one name. See WHO MAY, and TODO.md for the cost.
    local function staffOnly(run)
        return function(player, args)
            if not DFCore.hasAnyCapability(player) then
                return { ok = false, reason = "not permitted" }
            end
            return run(player, args or {})
        end
    end

    local function gated(capability, run)
        return function(player, args)
            if not RDAccess.roleHas(player, capability) then
                return { ok = false, reason = "not permitted" }
            end
            return run(player, args or {})
        end
    end

    -- A per-player verb, minus the four lines every one of them repeats: the
    -- capability, the username bound, the audit line, and the refreshed record
    -- that goes back so the panel never has to guess what it did.
    --
    -- `run` returns (true, message) or (nil, reason). Both halves are used -
    -- the message reaches the admin's feedback line and the reason reaches the
    -- audit log - so neither verb has to build a reply table of its own.
    local function playerVerb(action, run)
        DFServer.registerHandler{
            action = action,
            run = gated(CAP_PLAYER, function(player, args)
                local user = args.user
                if not DFVars_Server.validUser(user) then
                    return { ok = false, reason = "bad username" }
                end
                local ok, detail = run(player, args, user)
                DFCore.audit(action, player,
                    string.format("target=%s var=%s%s", user, tostring(args.name),
                        ok and "" or (" REFUSED: " .. tostring(detail))))
                -- Pushed whether the verb succeeded or not: a refused action
                -- leaves the panel showing whatever it believed before, and the
                -- one thing an admin needs after a refusal is the truth.
                pushPlayer(player, user)
                if not ok then return { ok = false, reason = tostring(detail) } end
                return { ok = true, message = detail }
            end),
        }
    end

    DFServer.registerHandler{
        action = "varsList",
        run = staffOnly(function(player)
            pushSummary(player)
            return { ok = true }
        end),
    }

    DFServer.registerHandler{
        action = "varsOfPlayer",
        run = staffOnly(function(player, args)
            if not DFVars_Server.validUser(args.user) then
                return { ok = false, reason = "bad username" }
            end
            pushPlayer(player, args.user)
            return { ok = true }
        end),
    }

    DFServer.registerHandler{
        action = "varDefine",
        run = gated(CAP_SCHEMA, function(player, args)
            -- args.def goes STRAIGHT to RDVarDefs.validate, which refuses an
            -- unknown field, a bad kind, a stringVar with no resetOnDeath and
            -- a revoker outside the closed set. Re-checking any of that here
            -- would be a second copy of a rule that already has one home.
            local def, why = RDVars.define(args.def, player:getUsername())
            if not def then
                DFCore.audit("varDefine", player, "REFUSED: " .. tostring(why))
                return { ok = false, reason = tostring(why) }
            end
            DFCore.audit("varDefine", player, "var=" .. def.name .. " kind=" .. def.kind)
            RDNet.sendStaff(DFCore.MODULE, "AdminVarsStale", {})
            return { ok = true, message = "Defined " .. def.name .. "." }
        end),
    }

    DFServer.registerHandler{
        action = "varUndefine",
        run = gated(CAP_SCHEMA, function(player, args)
            -- The purge is the point, not a side effect - RDVars' own comment
            -- explains why leaving orphaned state behind is worse - so the
            -- count comes back and goes in the audit line. An admin deleting a
            -- var should see how many people it was taken from.
            local ok, touched = RDVars.undefine(args.name)
            if not ok then
                DFCore.audit("varUndefine", player, "REFUSED: " .. tostring(touched))
                return { ok = false, reason = tostring(touched) }
            end
            DFCore.audit("varUndefine", player, string.format(
                "var=%s purged=%d", tostring(args.name), touched or 0))
            RDNet.sendStaff(DFCore.MODULE, "AdminVarsStale", {})
            return { ok = true, message = string.format(
                "Removed %s, and cleared it from %d player(s).",
                tostring(args.name), touched or 0) }
        end),
    }

    playerVerb("varGrant", function(player, args, user)
        local ok, why = RDVars.grant(user, args.name, player:getUsername())
        if not ok then return nil, why end
        return true, "Granted " .. tostring(args.name) .. " to " .. user .. "."
    end)

    playerVerb("varRevoke", function(_, args, user)
        local ok, why = RDVars.revoke(user, args.name, "admin panel")
        if not ok then return nil, why end
        return true, "Revoked " .. tostring(args.name) .. " from " .. user .. "."
    end)

    playerVerb("varSet", function(_, args, user)
        -- NO type check here, and that is deliberate. RDVars.set already refuses
        -- a non-number AND a NaN, and its message names the type it got - which
        -- is strictly better than anything this door could say. A copy here was
        -- written first and deleted: it was the weaker of two implementations of
        -- one rule, which is the duplicated-semantics problem, not defence in
        -- depth. The value is untrusted; it is simply checked once, where the
        -- rule lives.
        local v, why = RDVars.set(user, args.name, args.value)
        if v == nil then return nil, why end
        return true, user .. "'s " .. tostring(args.name) .. " is now " .. tostring(v) .. "."
    end)

    playerVerb("varReset", function(_, args, user)
        -- Back to ABSENT, not to zero, which is a distinction the panel has to
        -- keep saying out loud - it is the whole reason counters and markers
        -- are two kinds rather than one.
        local ok, why = RDVars.reset(user, args.name)
        if not ok then return nil, why end
        return true, tostring(args.name) .. " is absent again for " .. user .. "."
    end)

    print("[Dragonfly] DFVars_Server handlers registered")
end)

print("[Dragonfly] DFVars_Server loaded (registration deferred to OnServerStarted)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
