-- RDWire.lua - estimate the serialized size of a network payload (both sides).
--
-- Absorbed from OmenSpyNetwork's OSNSizer. OSN stays published and standalone
-- with its own users; this is the same absorption Guardian got, for the same
-- reason - the family wants the capability permanently, not as a drop-in probe.
--
-- WHY AN ESTIMATE AND NOT A MEASUREMENT: there is no engine API for true wire
-- bytes. TableNetworkUtils exposes zero @LuaMethod and the ByteBuffer is never
-- handed to Lua, so the only option is to model the wire format and walk the
-- table ourselves:
--
--   string  #s + 2   (length-prefixed UTF)
--   number  8        (Double, always - Kahlua has no integer subtype)
--   boolean 1
--   table   1 marker + contents
--   other   0        (functions/userdata are stripped before send)
--
-- This RANKS offenders. It is never exact and must never be reported as though
-- it were - every consumer calls the field "est", not "bytes".
--
-- BOUNDED, and this matters more here than it looks. OSN's walker was depth-
-- capped and cycle-safe but had no node budget, so sizing one enormous flat
-- blob meant walking every key of it on every single transmit - the probe
-- becomes the accomplice of the bandwidth hog it exists to find. A budget fixes
-- that, and blowing the budget is itself the signal: a payload too big to
-- measure is reported partial=true, which is exactly the alert an operator
-- wants. Under-reporting bytes would have hidden it.
--
-- Engine-free by construction: pcall, pairs, type and nothing else. That is
-- deliberate - it means tools/run-tests.bat exercises this under real Lua 5.1
-- with no stubs. Keep it that way; sandbox reads belong in RDMeter.

RDWire = RDWire or {}

RDWire.DEPTH_CAP    = 8       -- matches the wire serializer's own nesting limit
RDWire.NODE_BUDGET  = 20000   -- stop walking; report partial rather than stall a send

local function cost(v, depth, seen, budget)
    local t = type(v)
    if t == "string"  then return #v + 2 end
    if t == "number"  then return 8 end
    if t == "boolean" then return 1 end
    if t ~= "table"   then return 0 end

    if depth >= RDWire.DEPTH_CAP then return 1 end
    if seen[v] then return 1 end   -- cycle guard

    seen[v] = true
    local total = 1                -- table marker
    for k, val in pairs(v) do      -- pairs(), NOT next(): B42's Kahlua has no next global
        budget.n = budget.n - 2
        if budget.n <= 0 then
            budget.partial = true
            break
        end
        total = total + cost(k, depth + 1, seen, budget)
                      + cost(val, depth + 1, seen, budget)
    end
    -- Path-scoped, like RDJson's: the same table twice as siblings is a DAG,
    -- not a cycle, and both instances really do cost bytes on the wire.
    seen[v] = nil
    return total
end

-- estimate(args) -> approxBytes, partial
-- Never throws. partial=true means the node budget ran out, so approxBytes is a
-- floor rather than an estimate - treat it as "at least this big".
function RDWire.estimate(args)
    if type(args) ~= "table" then return 0, false end
    local budget = { n = RDWire.NODE_BUDGET, partial = false }
    local ok, n = pcall(cost, args, 0, {}, budget)
    if not ok then return 0, false end
    return n or 0, budget.partial
end

-- sendClientCommand / sendServerCommand are overloaded with an OPTIONAL leading
-- player argument. The (module, command, args) form has a string first; the
-- (player, module, command, args) form does not.
function RDWire.parseSend(a1, a2, a3, a4)
    if type(a1) == "string" then return a1, a2, a3 end
    return a2, a3, a4
end

-- The size a command costs beyond its payload: both name strings plus framing.
function RDWire.commandEstimate(module, command, args)
    local est, partial = RDWire.estimate(args)
    return est + #tostring(module) + #tostring(command) + 3, partial
end

return RDWire
