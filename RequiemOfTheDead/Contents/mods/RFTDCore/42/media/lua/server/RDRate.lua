-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDRate.lua - per-player command rate limiter (server only).
--
-- Absorbed from DFCore.allow / RCServer.underRate, which were the same
-- fixed-window algorithm written twice (same 20/1000ms defaults, same
-- fail-open policy). Client commands are cheap to send but can be expensive
-- to serve; a modded or malicious client can flood a dispatcher and feed the
-- engine's "server too busy" path - and since 42.16 the engine itself
-- throttles client packets by type, so a flooding client is punished twice.
--
-- FAILS OPEN: if we can't read a username or a clock we allow the command -
-- a limiter glitch must never brick staff tooling.
--
-- FIXED WINDOW, not sliding or token-bucket - and the boundary burst that
-- implies is accepted, not overlooked. The window resets wholesale on the
-- first hit past windowMs, so `max` hits at windowStart+999ms followed by
-- `max` hits at windowStart+1000ms serves 2*max inside about a millisecond.
-- At the 20/1000ms default that is a 40-command burst, which is still an order
-- of magnitude under anything that troubles a dispatcher, and since 42.16 the
-- engine throttles client packets by type underneath us anyway. A ring of
-- timestamps would cost per-player allocation on the tick thread to buy
-- precision nothing here needs. Revisit only if a command is ever registered
-- with a rate low enough that 2x matters (roughly: rate < 5).
--
-- Note also that b.count keeps incrementing while over-limit, so it is a tally
-- within the window rather than a rate - harmless, but do not read it as one.
-- And an over-limit command still costs a forensic write in RDNet's reject
-- path, so a flooding client converts throttled commands into log lines;
-- that volume is bounded by the ring, not by this limiter.

if not isServer() then return end

RDRate = RDRate or {}

local buckets = {}   -- "username|scope" (or bare username) -> { count, windowStart }

-- True if the player is under the limit (this hit is recorded); false once
-- they exceed `max` hits inside the current `windowMs` window.
--
-- `scope` isolates the bucket - pass the command identity ("token.command")
-- and each command gets its own window, its own count, and its own max.
-- WITHOUT it, every caller shares one bucket per username while comparing the
-- shared count against its own max, which means a `rate = 1` command is
-- allowed only when the user sent NOTHING ELSE that second: any same-second
-- family traffic - another mod's join handshake, a tab poll - makes the
-- low-rate command the Nth hit in the bucket and it is dropped, silently to
-- the client. That is not a theoretical burst-boundary quirk like the one in
-- the header; it is cross-contamination between unrelated commands, and it
-- was eating LMSync's join pulls and zone saves. Nil-scope callers keep the
-- legacy shared bucket.
function RDRate.allow(player, max, windowMs, scope)
    local name = player and player.getUsername and player:getUsername()
    if not name then return true end
    local now = RDShared.nowMs()
    if now == 0 then return true end
    max = max or 20
    windowMs = windowMs or 1000
    local key = scope and (name .. "|" .. tostring(scope)) or name
    local b = buckets[key]
    if not b or (now - b.windowStart) >= windowMs then
        buckets[key] = { count = 1, windowStart = now }
        return true
    end
    b.count = b.count + 1
    return b.count <= max
end

-- Forget every bucket the user owns, scoped or not. Clearing existing fields
-- during a pairs() traversal is defined behavior in Lua; only additions are
-- not.
function RDRate.forget(name)
    if not name then return end
    buckets[name] = nil
    local prefix = name .. "|"
    local plen = #prefix
    for k in pairs(buckets) do
        if string.sub(k, 1, plen) == prefix then buckets[k] = nil end
    end
end

-- Drop buckets on disconnect so the table doesn't accumulate one entry per
-- username ever seen. The "IsoPlayer or string" branch is inherited from the
-- family's dispatchers: different engine paths hand this event different
-- argument shapes.
local function prune(p)
    local name
    if type(p) == "string" then name = p
    elseif p and p.getUsername then name = p:getUsername() end
    RDRate.forget(name)
end
if Events.OnDisconnect then Events.OnDisconnect.Add(prune) end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(prune) end

return RDRate

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
