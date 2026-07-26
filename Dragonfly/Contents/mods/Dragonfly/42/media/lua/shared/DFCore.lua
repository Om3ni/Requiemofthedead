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
DFCore.VERSION = "0.6.2"   -- 0.6.2: panel gate falls back to getAccessLevel (isAdmin() flaky on dedi clients)
                           -- 0.6.1: admin gate on opening the panel (was ungated)
                           -- 0.6.0: command rate-limiter + auditOnly staff-gate; BanBox engine + login confiscation

-- Safe capability check. Roles can be nil during early load and in single
-- player; pcall keeps a bad role lookup from killing the whole gate.
function DFCore.roleHas(player, capability)
    if not player or not capability then return false end
    local ok, result = pcall(function()
        local role = player:getRole()
        return role and role:hasCapability(capability)
    end)
    return ok and result == true
end

-- True if the player's role grants at least one capability of any kind - i.e.
-- they hold *some* admin privilege. Used to gate actions any staffer may
-- legitimately trigger but no ordinary player should (e.g. auditOnly, which
-- broadcasts a log line to every client). Iterating the capability list is
-- cheap and only happens on those gated paths, never per tick.
function DFCore.hasAnyCapability(player)
    if not player then return false end
    local ok, result = pcall(function()
        local role = player:getRole()
        if not role then return false end
        local caps = getCapabilities()
        if not caps then return false end
        for i = 0, caps:size() - 1 do
            if role:hasCapability(caps:get(i)) then return true end
        end
        return false
    end)
    return ok and result == true
end

-- ─────────────────────────────────────────────────────────────────────────
-- Per-player command rate limiter (server-side defense-in-depth).
--
-- Client commands are cheap to send but can be expensive to serve (some
-- broadcast to every client, some fan out a packet per item). A modded or
-- malicious client can flood the dispatcher, which feeds the engine's
-- "server too busy -> dropping packets" path. This is a fixed-window counter
-- keyed by username: at most `max` commands per `windowMs`. It FAILS OPEN -
-- if we can't read a username or a clock we allow the command, so a limiter
-- glitch can never brick the panel.
-- ─────────────────────────────────────────────────────────────────────────
local rlBuckets = {}   -- username -> { count, windowStart }

local function rlNow()
    -- getTimestampMs (ms since launch) is the primary clock; getTimeInMillis is
    -- the fallback. Mirrors LSTour's clock probe. nil = no usable clock.
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" then return v end
    ok, v = pcall(getTimeInMillis)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Returns true if the player is under the limit (and records this hit), false
-- if they've exceeded `max` commands inside the current `windowMs` window.
function DFCore.allow(player, max, windowMs)
    local name = player and player.getUsername and player:getUsername()
    if not name then return true end       -- can't key it -> don't block
    local now = rlNow()
    if not now then return true end        -- no clock -> fail open
    max = max or 20
    windowMs = windowMs or 1000
    local b = rlBuckets[name]
    if not b or (now - b.windowStart) >= windowMs then
        rlBuckets[name] = { count = 1, windowStart = now }
        return true
    end
    b.count = b.count + 1
    return b.count <= max
end

-- Drop a player's bucket (call on disconnect so the table doesn't accumulate
-- one entry per username ever seen over the server's lifetime).
function DFCore.forgetRateLimit(name)
    if name then rlBuckets[name] = nil end
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
