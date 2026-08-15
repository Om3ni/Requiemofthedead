-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFServer - command dispatcher and audit log.
--
-- Every client action routes through here. We re-validate the action's
-- capability against the caller's role (client gate is decorative), print
-- an audit line, dispatch to the registered handler, then reply with a
-- Result event the client consumes for HaloText feedback.
--
-- Handlers register at load time via DFServer.registerHandler{action, capability, run}.
-- Consumer mods (Reaper etc.) add their server-side handlers the same way.

if not isServer() then return end

DFServer = DFServer or { handlers = {} }

function DFServer.registerHandler(spec)
    if not spec or not spec.action or type(spec.run) ~= "function" then return end
    DFServer.handlers[spec.action] = spec
end

local function reply(player, ok, action, reasonOrMessage)
    if not player or not sendServerCommand then return end
    local args = { ok = ok and true or false, action = action }
    if ok then args.message = reasonOrMessage else args.reason = reasonOrMessage end
    -- GameServer.sendServerCommand:3256 returns early for an unmapped player
    -- and a closed connection, so a disconnected caller needs no guard.
    sendServerCommand(player, DFCore.MODULE, "Result", args)
end

-- Per-player command rate limit. 20 commands/sec is far above any human
-- clicking cadence but stops a scripted flood. Over-limit commands are dropped
-- with NO reply (a reply is itself a packet) and are never audited (audit
-- broadcasts to all clients, which would re-amplify the flood); we log to the
-- server console at most once per 10s per player instead.
local RATE_MAX       = 20
local RATE_WINDOW_MS = 1000
local lastWarnMs     = {}   -- username -> last console-warn time (ms), or true

local function noteThrottled(player)
    local name = player and player.getUsername and player:getUsername()
    if not name then return end
    local now = getTimestampMs()
    if type(now) ~= "number" then
        if lastWarnMs[name] then return end          -- no clock: warn once ever
        lastWarnMs[name] = true
        print("[Dragonfly] rate-limit: dropping commands from " .. name)
        return
    end
    local last = type(lastWarnMs[name]) == "number" and lastWarnMs[name] or 0
    if now - last < 10000 then return end
    lastWarnMs[name] = now
    print(string.format(
        "[Dragonfly] rate-limit: dropping excess commands from %s (> %d per %dms)",
        name, RATE_MAX, RATE_WINDOW_MS))
end

-- Exposed so the disconnect hook can drop a leaver's warn-state alongside the
-- DFCore bucket.
function DFServer._forgetRateState(name)
    if name then lastWarnMs[name] = nil end
end

local function onClientCommand(module, command, player, args)
    if module ~= DFCore.MODULE then return end
    if command == "Result" then return end  -- never bounce our own replies

    if not DFCore.allow(player, RATE_MAX, RATE_WINDOW_MS) then
        noteThrottled(player)
        return
    end

    local handler = DFServer.handlers[command]
    if not handler then
        DFCore.audit(command, player, "(unknown action)")
        reply(player, false, command, "Unknown action: " .. tostring(command))
        return
    end

    if handler.capability and not DFCore.roleHas(player, handler.capability) then
        DFCore.audit(command, player, "(refused: missing capability)")
        reply(player, false, command, "Missing capability for " .. tostring(command))
        return
    end

    DFCore.audit(command, player)
    -- pcall: handler containment - consumer mods (Reaper etc.) register run
    -- callbacks here, and a tenant's error must not take the dispatcher down.
    local ok, result = pcall(handler.run, player, args or {})
    if not ok then
        print(string.format("[Dragonfly] handler error (%s): %s", tostring(command), tostring(result)))
        reply(player, false, command, "Handler error")
        return
    end
    -- Handler may return (ok_bool, message_or_reason).
    if type(result) == "table" then
        reply(player, result.ok ~= false, command, result.message or result.reason)
    else
        reply(player, true, command, nil)
    end
end

Events.OnClientCommand.Add(onClientCommand)

-- Audit-only handler: chat-command admin actions (kick/ban/teleport/mute)
-- bypass our dispatcher because they're handled by vanilla. The scoreboard
-- extension sends a parallel auditOnly event so the audit line still
-- broadcasts to every admin's Console tab. Server doesn't perform the
-- action - vanilla already did - just records and broadcasts.
DFServer.registerHandler{
    action = "auditOnly",
    -- Staff-gate: auditOnly's only job is to broadcast a log line to every
    -- client, so an ungated handler is an amplification + log-poisoning vector
    -- (1 inbound -> N outbound, with attacker-controlled text). The legitimate
    -- senders are admins mirroring a vanilla chat-command action (kick / ban /
    -- teleport / mute), who by definition already hold the matching capability.
    -- Require *some* admin capability; reject everyone else before the broadcast.
    run = function(player, args)
        if not DFCore.hasAnyCapability(player) then
            return { ok = false, reason = "not permitted" }
        end
        local action = tostring(args.action or "?")
        local target = args.target and (" target=" .. tostring(args.target)) or ""
        DFCore.audit(action, player, target)
        return { ok = true }
    end,
}

-- Prune rate-limit state when a player leaves so the per-username tables don't
-- grow over the server's lifetime. Defensive about the arg shape: some B42
-- builds pass the IsoPlayer, some a username string.
local function onDisconnect(a)
    local name
    if type(a) == "string" then
        name = a
    elseif a and a.getUsername then
        name = a:getUsername()   -- IsoGameCharacter.getUsername, field return
    end
    if not name then return end
    DFCore.forgetRateLimit(name)
    DFServer._forgetRateState(name)
end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(onDisconnect) end

print("[Dragonfly] DFServer loaded (v" .. tostring(DFCore.VERSION) .. ")")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
