-- DFCore - shared constants and helpers for the Dragonfly admin panel.
--
-- Loaded on client and server. Capability checks live here because the same
-- gate runs both sides: client greys out buttons the player can't use, server
-- re-validates and rejects spoofed commands. Anything that only makes sense on
-- one side (HaloText, ISUI) lives in DFFeedback or DFPanel instead.
--
-- Designed for dedicated MP. SP and coop-host paths are not tested or
-- supported; the role/capability system this leans on only meaningfully
-- exists in MP, and audit log lines assume a real server console.

DFCore = DFCore or {}

DFCore.MODULE  = "RFTDDragonfly"
DFCore.VERSION = "0.7.0"   -- 0.7.0: RFTDCore adoption (hard require) - RDAccess/RDRate/RDLife
                           --        delegates, sandbox-tiered panel/debug gates. NOTE: this
                           --        constant previously drifted against mod.info (0.6.2 vs
                           --        0.6.3); keep the pair in sync - RD.HELLO now catches it.
                           -- 0.6.2: panel gate falls back to getAccessLevel (isAdmin() flaky on dedi clients)
                           -- 0.6.1: admin gate on opening the panel (was ungated)
                           -- 0.6.0: command rate-limiter + auditOnly staff-gate; BanBox engine + login confiscation

-- RFTDCore adoption (hard require - no guards, per family law). Registered
-- under the WORKSHOP MOD ID ("Dragonfly"), not the wire token - the HELLO
-- handshake compares what the server config loads.
RDShared.registerMod("Dragonfly", DFCore.VERSION)

-- Capability check: delegates to the family gate (RDAccess). Signature kept
-- because ~20 call sites across the panel/scoreboard/tabs use it.
function DFCore.roleHas(player, capability)
    return RDAccess.roleHas(player, capability)
end

-- Any-capability staff check: delegates to the family gate (RDAccess).
function DFCore.hasAnyCapability(player)
    return RDAccess.hasAnyCapability(player)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Rate limiter: delegates to RDRate, the family's one fixed-window limiter
-- (this file used to carry its own copy of the same algorithm; RCServer had
-- another). RDRate is server-only; these shims are only ever called from
-- DFServer's dispatcher, and fail open client-side by design.
-- ─────────────────────────────────────────────────────────────────────────
function DFCore.allow(player, max, windowMs)
    if RDRate then return RDRate.allow(player, max, windowMs) end
    return true
end

function DFCore.forgetRateLimit(name)
    if RDRate then RDRate.forget(name) end
end

-- Server-side audit line. Format matches Reaper's "[Reaper] forceScan
-- requested by USERNAME" so logs across the family read the same way.
-- Also broadcasts the line to every connected client so admins see each
-- other's actions in the in-game Console tab without needing server-console
-- access. Non-admin clients receive but don't display (panel is gated).
function DFCore.audit(action, player, extra)
    local username = (player and player.getUsername and player:getUsername()) or "?"
    local tail = extra and (" " .. tostring(extra)) or ""
    local line = string.format("[Dragonfly] %s by %s%s", tostring(action), tostring(username), tail)
    print(line)

    if isServer() and sendServerCommand then
        local text = string.format("%s by %s%s", tostring(action), tostring(username), tail)
        pcall(sendServerCommand, DFCore.MODULE, "LogBroadcast", {
            source = "Admin",
            level  = "audit",
            text   = text,
        })
    end
end

-- Dragonfly v0.6.2
