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

if not isServer() then return end

RDRate = RDRate or {}

local buckets = {}   -- username -> { count, windowStart }

-- True if the player is under the limit (this hit is recorded); false once
-- they exceed `max` hits inside the current `windowMs` window.
function RDRate.allow(player, max, windowMs)
    local name = player and player.getUsername and player:getUsername()
    if not name then return true end
    local now = RDShared.nowMs()
    if now == 0 then return true end
    max = max or 20
    windowMs = windowMs or 1000
    local b = buckets[name]
    if not b or (now - b.windowStart) >= windowMs then
        buckets[name] = { count = 1, windowStart = now }
        return true
    end
    b.count = b.count + 1
    return b.count <= max
end

function RDRate.forget(name)
    if name then buckets[name] = nil end
end

-- Drop buckets on disconnect so the table doesn't accumulate one entry per
-- username ever seen. The "IsoPlayer or string" branch is inherited from the
-- family's dispatchers: different engine paths hand this event different
-- argument shapes.
local function prune(p)
    local name
    if type(p) == "string" then name = p
    elseif p and p.getUsername then pcall(function() name = p:getUsername() end) end
    RDRate.forget(name)
end
if Events.OnDisconnect then Events.OnDisconnect.Add(prune) end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(prune) end

return RDRate
