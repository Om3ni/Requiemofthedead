-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCClaim - the claim brain. Loaded on both sides.
--
-- Owns the vehicle-modData claim scheme and the access dispatchers. Access is
-- GRANULAR: four permissions, each grantable per-whitelisted-player AND as a
-- per-vehicle "public" (everyone) flag.
--   driver    - enter/occupy the DRIVER seat (seat 0), seat-swap to it, tow
--   passenger - enter/occupy a PASSENGER seat, seat-swap to it
--   mechanic  - open the vehicle mechanics UI
--   inventory - take from the vehicle (trunk/seats/glovebox) + siphon fuel
-- Smashing a claimed car's window is owner/admin only (no tier grants it).
-- Opening/unlocking a door needs only "any access" (it's benign; the harmful
-- action behind it is gated at its own point).
--
-- Two dispatchers, both routed through here so UX and enforcement never differ:
--   canDo(vehicle, player, perm) - may this player do THIS specific thing?
--   canInteract(vehicle, player) - does this player have ANY access at all?
--                                  (used to fully hide the menus from a no-
--                                   access player; partial-access players see
--                                   the menu and are gated per-action.)
--
-- Reads only. Writes happen SERVER-SIDE ONLY (RCServer) + transmitModData.

RCClaim = RCClaim or {}

RCClaim.KEY_OWNER    = "RC_ClaimOwner"   -- owner username
RCClaim.KEY_ALLOWED  = "RC_ClaimAllowed" -- map: username -> {driver,passenger,mechanic,inventory = bool}
RCClaim.KEY_PUBLIC   = "RC_ClaimPublic"  -- {driver,passenger,mechanic,inventory = bool} for EVERYONE
RCClaim.KEY_USED     = "RC_ClaimUsed"    -- last-claimed stamp (os.time)
RCClaim.KEY_ID       = "RC_ClaimId"      -- stable id (getId() is not stable across reload)
RCClaim.LEGACY_OWNER = "WG_Claim_Owner"  -- VehicleClaimWG legacy read => seamless cutover

RCClaim.PERMS = { "driver", "passenger", "mechanic", "inventory" }

-- Owner username, or nil. Falls back to the legacy WG key.
function RCClaim.getOwner(vehicle)
    if not vehicle then return nil end
    local md = vehicle:getModData()
    local o = md[RCClaim.KEY_OWNER]
    if o and o ~= "" then return o end
    local legacy = md[RCClaim.LEGACY_OWNER]
    if legacy and legacy ~= "" then return legacy end
    return nil
end

function RCClaim.isClaimed(vehicle)
    return RCClaim.getOwner(vehicle) ~= nil
end

function RCClaim.getClaimId(vehicle)
    if not vehicle then return nil end
    return vehicle:getModData()[RCClaim.KEY_ID]
end

-- The whitelist as a map username -> perm-flags. Transparently upgrades the
-- legacy array form ({ "bob", "alice" } = old binary "full access") so old
-- claims keep working; the server rewrites it in the new shape on any change.
function RCClaim.getAllowedMap(vehicle)
    if not vehicle then return {} end
    local raw = vehicle:getModData()[RCClaim.KEY_ALLOWED]
    if type(raw) ~= "table" then return {} end
    if raw[1] ~= nil then -- legacy array
        local map = {}
        for _, n in ipairs(raw) do
            if type(n) == "string" then
                map[n] = { driver = true, passenger = true, mechanic = true, inventory = true }
            end
        end
        return map
    end
    return raw
end

-- Per-vehicle public (everyone) permission flags.
function RCClaim.getPublic(vehicle)
    if not vehicle then return {} end
    return vehicle:getModData()[RCClaim.KEY_PUBLIC] or {}
end

function RCClaim.getPerms(vehicle, username)
    if not username then return nil end
    return RCClaim.getAllowedMap(vehicle)[username]
end

-- Is this username on the whitelist at all (any entry)? Used by the GUI.
function RCClaim.isAllowed(vehicle, username)
    return RCClaim.getPerms(vehicle, username) ~= nil
end

function RCClaim.hasPerm(vehicle, username, perm)
    local p = RCClaim.getPerms(vehicle, username)
    return (p and p[perm] == true) or false
end

function RCClaim.publicHas(vehicle, perm)
    return RCClaim.getPublic(vehicle)[perm] == true
end

local function ownerOf(vehicle, player)
    local owner = RCClaim.getOwner(vehicle)
    local name = player.getUsername and player:getUsername()
    return owner, name
end

-- May this player perform the action gated by `perm`?
--   owner / admin / unclaimed -> always.  public[perm] -> everyone.
--   else the player's own whitelist flag.
function RCClaim.canDo(vehicle, player, perm)
    if not vehicle or not player then return true end
    if not RCShared.cfg().claimsEnabled then return true end
    local owner, name = ownerOf(vehicle, player)
    if not owner then return true end
    if name and owner == name then return true end
    if RCShared.isAdmin(player) then return true end
    if RCClaim.publicHas(vehicle, perm) then return true end
    return RCClaim.hasPerm(vehicle, name, perm)
end

-- Does this player have ANY access (owner/admin, any public perm, or any of
-- their own whitelist perms)? Drives full menu suppression for no-access
-- players; partial-access players pass here and are gated per action by canDo.
function RCClaim.canInteract(vehicle, player)
    if not vehicle or not player then return true end
    if not RCShared.cfg().claimsEnabled then return true end
    local owner, name = ownerOf(vehicle, player)
    if not owner then return true end
    if name and owner == name then return true end
    if RCShared.isAdmin(player) then return true end
    local pub = RCClaim.getPublic(vehicle)
    for _, p in ipairs(RCClaim.PERMS) do if pub[p] then return true end end
    local perms = RCClaim.getPerms(vehicle, name)
    if perms then
        for _, p in ipairs(RCClaim.PERMS) do if perms[p] then return true end end
    end
    return false
end

-- Owner/admin only (smash gate). An UNCLAIMED car is open to anyone.
function RCClaim.isOwnerOrAdmin(vehicle, player)
    if not vehicle or not player then return false end
    local owner, name = ownerOf(vehicle, player)
    if not owner then return true end
    if name and owner == name then return true end
    return RCShared.isAdmin(player)
end

-- Driver seat is index 0 in PZ (vanilla isDriver/seat-menu key off seat 0).
function RCClaim.isDriverSeat(seat)
    return seat == 0
end

-- One-line, human-readable dump of a vehicle's claim state. Used by the debug
-- traces and the on-demand dump so we can compare CLIENT vs SERVER views.
function RCClaim.describe(vehicle)
    if not vehicle then return "describe: nil vehicle" end
    local owner = RCClaim.getOwner(vehicle) or "-"
    local id = RCClaim.getClaimId(vehicle) or "-"
    local pub = RCClaim.getPublic(vehicle)
    local pubs = {}
    for _, p in ipairs(RCClaim.PERMS) do if pub[p] then pubs[#pubs + 1] = p end end
    local wl = {}
    for nm, flags in pairs(RCClaim.getAllowedMap(vehicle)) do
        local fs = {}
        for _, p in ipairs(RCClaim.PERMS) do if flags[p] then fs[#fs + 1] = p end end
        wl[#wl + 1] = nm .. "[" .. table.concat(fs, ",") .. "]"
    end
    local idn = (vehicle.getId and vehicle:getId()) or "?"
    return string.format("veh#%s owner=%s claimId=%s public={%s} allowed={%s}",
        tostring(idn), owner, id, table.concat(pubs, ","), table.concat(wl, " "))
end

-- Precondition gate for claiming (cap check is server-side via the registry).
-- Returns ok(boolean), reason(string).
function RCClaim.canClaim(vehicle, player)
    if not vehicle or not player then return false, "novehicle" end
    if not RCShared.cfg().claimsEnabled then return false, "disabled" end
    if RCShared.isWreck(vehicle) then return false, "wreck" end
    local owner, name = ownerOf(vehicle, player)
    if owner and owner ~= name then return false, "claimed" end
    return true
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
