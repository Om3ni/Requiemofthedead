-- RDGuardian.lua - forensic record of every client command (server only).
--
-- Absorbed from OmenSpyNetwork's GuardianLogger. Guardian watches and
-- records; it does not act and renders no verdict. Lua cannot veto a client
-- command anyway - GameServer.receiveClientCommand fires OnClientCommand to
-- every registered listener unconditionally and discards return values - so
-- judgment is kept out of the sensor by design. Classification belongs to
-- whatever reads the ring (tools/cmdscan and its successors).
--
-- Why this sees what the engine's cmd.txt does not: cmd.txt drops the
-- argument table and is gated by a CCFilter; the Lua OnClientCommand event
-- fires OUTSIDE that filter and WITH the args, server-side.
--
-- Output: envelope JSONL into the "guardian" forensic ring stream (bounded,
-- rotating - volume control is the ring, not discipline).
--
-- COST DIMENSION (absorbed from OmenSpyNetwork, which is where the rest of the
-- traffic telemetry now lives - see RDMeter). OSN registered its OWN
-- OnClientCommand listener purely to estimate inbound payload size. That is a
-- second listener on the hottest event in the game to walk a table this one has
-- already got in hand, so the sizing is folded in here instead: every RD.CMD
-- record carries `est` (approximate wire bytes, per RDWire) and feeds the same
-- number to RDMeter's C2S bucket. Guardian answers "who sent what", RDMeter
-- answers "what did it cost", and neither needs its own copy of the event.
--
-- This does walk args twice - once for serializeArgs, once for the size - and
-- that is accepted rather than optimised away: both walks are independently
-- bounded (400 nodes here, 20000 in RDWire), real command args are tiny, and
-- fusing them would tangle a debug-string serializer with a wire-format model
-- for a saving nobody can measure. `est` is emitted whether or not the RDMeter
-- probe is armed, because it costs one bounded walk and makes every Guardian
-- record self-describing.
--
-- sid_approx is NOT the real SteamID: getSteamID() returns a Java long that
-- exceeds Lua's exact-integer range, so through Lua it is ALWAYS a lossy
-- double and no server-side global returns the exact string. %.0f at least
-- avoids scientific notation. Its one virtue: deterministic and stable per
-- account, so it survives username changes - a rename-resistant coarse
-- fingerprint, never a ban key. The authoritative exact id lives in the
-- engine's cmd.txt; a reader joins on username, the exact key this sensor
-- contributes.

if not isServer() then return end

-- Explicit: "RDGuardian.lua" sorts before both "RDMeter.lua" (same dir) and
-- Core's shared tier on the client's alphabetical walk, so neither global exists
-- at file scope here. Declared, not assumed - the family rule since the 42.19
-- boot-log crashes. Safe below the isServer() guard, which has already returned
-- on the client where these self-abort to nil.
require "RDWire"
require "RDMeter"

RDGuardian = RDGuardian or {}

local ARGS_DEPTH  = 4      -- nested-table serialization depth cap (also the cycle guard)
local ARGS_NODES  = 400    -- node budget so a huge payload can't stall the tick
local ARGS_MAXLEN = 2000   -- final serialized length cap

-- Compact, capped serializer for the args KahluaTable. Args can hold Java
-- objects and cycles, which the JSON encoder must never walk raw - the string
-- this produces is what lands in the record.
function RDGuardian.serializeArgs(a)
    if type(a) ~= "table" then return tostring(a) end
    local parts, n = {}, 0
    local function walk(v, depth)
        n = n + 1
        if n > ARGS_NODES then parts[#parts + 1] = "..."; return end
        local t = type(v)
        if t == "table" then
            if depth <= 0 then parts[#parts + 1] = "{...}"; return end
            parts[#parts + 1] = "{"
            local first = true
            for k, vv in pairs(v) do
                if not first then parts[#parts + 1] = "," end
                first = false
                parts[#parts + 1] = tostring(k) .. "="
                walk(vv, depth - 1)
            end
            parts[#parts + 1] = "}"
        elseif t == "string" then
            parts[#parts + 1] = '"' .. v .. '"'
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    walk(a, ARGS_DEPTH)
    local s = table.concat(parts)
    if #s > ARGS_MAXLEN then s = s:sub(1, ARGS_MAXLEN) .. "~" end
    return s
end

if not RDGuardian._hooked then
    RDGuardian._hooked = true
    Events.OnClientCommand.Add(function(module, command, player, args)
        pcall(function()   -- a sensor fault must never disturb the real command path
            local x, y, z = -1, -1, -1
            pcall(function()
                x = math.floor(player:getX()); y = math.floor(player:getY()); z = math.floor(player:getZ())
            end)
            local est, partial = RDWire.commandEstimate(module, command, args)
            RDLog.forensic("guardian", "RD.CMD", player, {
                access   = (player and player:getAccessLevel()) or "",
                sid      = RDIdentity.sidApprox(player) or "0",
                onlineid = (player and player:getOnlineID()) or -1,
                x = x, y = y, z = z,
                module   = tostring(module),
                command  = tostring(command),
                args     = RDGuardian.serializeArgs(args),
                est      = est,
                partial  = partial or nil,   -- omitted unless the size walk ran out of budget
            })
            RDMeter.record("C2S", tostring(module) .. ":" .. tostring(command), est, partial)
        end)
    end)
end

return RDGuardian
