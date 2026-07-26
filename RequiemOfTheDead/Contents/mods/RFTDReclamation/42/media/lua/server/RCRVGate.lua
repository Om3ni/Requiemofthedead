-- RCRVGate - claim gate for the RV Interior mod's "enter interior" teleport.
-- Server-only, soft-dep, INERT if the RV mod isn't present.
--
-- THE HOLE: the RV Interior mod (modPROJECTRVInterior / workshop 3543229299)
-- teleports a player into a claimed RV's separate interior "room" - a space full
-- of WORLD containers (IsoObjects) that our vehicle-part loot gate
-- (RCClaimItemLock) does NOT protect, because it only guards vehicle-PART
-- containers. So a non-owner could walk into your RV's living space and rob it
-- blind. Door/loot gating on the vehicle itself can't help - the loot isn't in
-- the vehicle, it's in a teleported-to room. The only defense is gating ENTRY.
--
-- THE CHOKEPOINT: in MP the mod routes every entry through the SERVER-side global
-- `GetInToRV(player, vehicle)` (its `enterRV` OnClientCommand handler resolves the
-- vehicle, then calls it). We wrap that single function and deny the enter when
-- the player lacks access to the RV. Because it runs on the SERVER, a modified
-- client that fires a raw `enterRV` command can't get around it.
--
-- Wrapped on OnServerStarted, NOT at file-load: RFTDReclamation loads BEFORE the
-- RV mod, so `GetInToRV` doesn't exist yet when this file first runs.

if not isServer() then return end

RCRVGate = RCRVGate or {}

local M = RCShared.MODULE

-- Which permission entering the RV interior requires. `inventory` = the "may
-- access this vehicle's stuff" tier, which matches the theft concern (the
-- interior IS a storage space). Owner / admin / unclaimed / claims-disabled all
-- pass through `canDo` automatically. Change this one constant to retier (e.g.
-- "passenger" if riding should grant interior access).
local ENTER_PERM = "inventory"

local function notify(player, key, isError)
    if player and sendServerCommand then
        sendServerCommand(player, M, "Notify", { key = key, error = isError and true or false })
    end
end

local function applyGate()
    if type(GetInToRV) ~= "function" then return end   -- RV mod absent => stay inert
    if RCRVGate.wrapped then return end
    RCRVGate.wrapped = true

    local orig = GetInToRV
    GetInToRV = function(player, vehicle, ...)
        -- canDo covers every allow case (owner, admin, unclaimed, claims-off,
        -- public[perm], or the player's own whitelist flag). Only a genuine
        -- no-access player on a claimed RV is denied.
        if vehicle and player and not RCClaim.canDo(vehicle, player, ENTER_PERM) then
            notify(player, "IGUI_RC_RVLocked", true)
            pcall(function()
                RCAudit.log("RV-DENY", player, { vehicle = vehicle:getScriptName() })
            end)
            return  -- blocked: no teleport into the interior
        end
        return orig(player, vehicle, ...)
    end
    print("[RC] RCRVGate: RV interior entry gated (perm=" .. ENTER_PERM .. ")")
end

Events.OnServerStarted.Add(applyGate)
