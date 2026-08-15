-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- Capability is a plain KahluaTable of enum constants (rawset by the exposer,
-- LuaJavaClassExposer:301) - an unknown name indexes to nil, never a throw.
local function resolveCap(capability)
    if type(capability) ~= "string" then return capability end
    return Capability and Capability[capability] or nil
end

-- Roles can be nil during early load and in single player - nil-checked.
-- getRole (IsoPlayer:6987) is a field return; hasCapability (Role:187) is
-- HashSet.contains on a final set (:31). The method probe keeps a non-player
-- receiver at false instead of a throw that would lock the whole gate.
function RDAccess.roleHas(player, capability)
    if not player or not capability then return false end
    local cap = resolveCap(capability)
    if not cap then return false end
    if not player.getRole then return false end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(cap) == true
end

-- True if the player's role grants at least one capability of any kind -
-- they hold *some* staff privilege. For actions any staffer may legitimately
-- trigger but no ordinary player should. Iterates the capability list; cheap,
-- and only runs on gated paths, never per tick.
function RDAccess.hasAnyCapability(player)
    -- getCapabilities (LuaManager:3115) allocates a fresh ArrayList of the enum
    -- values; size/get are bounds-safe inside the loop; hasCapability as above
    if not player or not player.getRole then return false end
    local role = player:getRole()
    if not role then return false end
    local caps = getCapabilities()
    if not caps then return false end
    for i = 0, caps:size() - 1 do
        if role:hasCapability(caps:get(i)) then return true end
    end
    return false
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

-- The highest tier: access level "admin", nothing less. For surfaces with
-- too much power for general staff (zombie conversion, the admin panel,
-- debug menus). getAccessLevel is IsoPlayer-only (:6983, role null-checked
-- then a field read) - the probe keeps the ghost/non-player receivers that
-- used to crash here at false instead of a throw.
function RDAccess.isTopAdmin(player)
    if not player or not player.getAccessLevel then return false end
    local access = player:getAccessLevel()
    if type(access) ~= "string" then return false end
    return string.lower(access) == "admin"
end

-- Sandbox-driven tier gate, so each server chooses its own policy per
-- surface. `tier` is the raw enum value from a sandbox option:
--   1 (or anything else) -> Admin only        <- the shipped default
--   2                    -> All staff (any capability)
-- Strictest-by-default on purpose: an unset or out-of-range value locks
-- down rather than opening up.
function RDAccess.meetsTier(player, tier)
    if tier == 2 then return RDAccess.hasAnyCapability(player) end
    return RDAccess.isTopAdmin(player)
end

return RDAccess

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
