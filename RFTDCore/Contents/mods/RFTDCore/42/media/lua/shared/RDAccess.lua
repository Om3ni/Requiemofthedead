-- RDAccess.lua - the family's one answer to "who may do what" (both sides).
--
-- The pre-Core family had four incompatible answers (five-level allowlist,
-- four-level allowlist, any-non-None, Admin-only) plus Dragonfly's capability
-- checks. This standardizes on the CAPABILITY MODEL: features check named
-- capabilities, roles grant capability sets, and the server's role editor -
-- not a mod republish - is where policy changes happen. Each satellite maps
-- its old allowlist onto capability checks at its migration turn.
--
-- Loaded on client and server because the same gate runs both sides: the
-- client greys out what the player can't use, the server re-validates and
-- rejects spoofed commands (RDNet does this automatically for registered
-- commands).

RDAccess = RDAccess or {}

-- Resolve a capability given as either the engine enum value or its name.
local function resolveCap(capability)
    if type(capability) ~= "string" then return capability end
    local ok, cap = pcall(function() return Capability[capability] end)
    if ok and cap then return cap end
    return nil
end

-- Safe capability check. Roles can be nil during early load and in single
-- player; pcall keeps a bad role lookup from killing the whole gate.
function RDAccess.roleHas(player, capability)
    if not player or not capability then return false end
    local cap = resolveCap(capability)
    if not cap then return false end
    local ok, result = pcall(function()
        local role = player:getRole()
        return role and role:hasCapability(cap)
    end)
    return ok and result == true
end

-- True if the player's role grants at least one capability of any kind -
-- they hold *some* staff privilege. For actions any staffer may legitimately
-- trigger but no ordinary player should. Iterates the capability list; cheap,
-- and only runs on gated paths, never per tick.
function RDAccess.hasAnyCapability(player)
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

-- The one gate everything routes through. `requirement` is:
--   nil    -> open to everyone
--   "any"  -> any capability at all (staff)
--   other  -> a specific capability (enum value or name string)
function RDAccess.can(player, requirement)
    if requirement == nil then return true end
    if requirement == "any" then return RDAccess.hasAnyCapability(player) end
    return RDAccess.roleHas(player, requirement)
end

return RDAccess
