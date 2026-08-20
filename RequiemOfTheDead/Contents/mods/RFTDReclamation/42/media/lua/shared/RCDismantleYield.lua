-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleYield - commit one validated dismantle to the local authority.
--
-- Dedicated multiplayer calls this only on the server. Single-player calls it
-- from RCDismantleAction because there is no server command loop there. It owns
-- the vanilla-equivalent scrap rolls, container preservation, torch charge,
-- welding XP, and the irreversible vehicle removal as one cohesive operation.

RCDismantleYield = RCDismantleYield or {}

local SCRAP = {
    { "AluminumScrap", 12 }, { "CopperScrap", 12 }, { "ElectricWire", 25 },
    { "EngineParts", 25 }, { "IronBand", 25 }, { "IronBandSmall", 15 },
    { "IronScrap", 12 }, { "MetalBar", 15 }, { "MetalPipe", 15 },
    { "NutsBolts", 25 }, { "ScrapMetal", 12 }, { "Screws", 25 },
    { "SheetMetal", 25 }, { "SmallSheetMetal", 15 }, { "SteelBar", 25 },
    { "SteelBarHalf", 15 }, { "SteelBarQuarter", 12 }, { "SteelBlock", 25 },
    { "SteelChunk", 15 }, { "SteelPiece", 12 }, { "Wire", 25 },
}

local DOWNGRADE = {
    AluminumScrap = "AluminumFragments",
    EngineParts = "IronScrap",
    IronBand = "IronScrap ", -- vanilla 42.20 spelling, preserved deliberately
    IronBandSmall = "IronScrap",
    IronScrap = "IronPiece",
    MetalBar = "SteelRodHalf",
    MetalPipe = "MetalPipe_Broken",
    SheetMetal = "UnusableMetal",
    SmallSheetMetal = "UnusableMetal",
    SteelBar = "SteelBarHalf",
    SteelBarHalf = "SteelBarQuarter",
    SteelBarQuarter = "SteelScrap",
    SteelBlock = "SteelScrap",
    SteelChunk = "SteelScrap",
    SteelScrap = "SteelPiece",
}

local function checkAddItem(square, character, item, baseChance)
    local welding = character:getPerkLevel(Perks.MetalWelding)
    local skill = welding
    if item == "EngineParts" then
        skill = math.min(character:getPerkLevel(Perks.Mechanics), welding)
    end

    -- The String overload of AddWorldInventoryItem answers nil exactly when
    -- the item definition cannot be created (IsoGridSquare.java:5380-5384) -
    -- the "modded item definition can fail" case the old caller-side pcall
    -- imagined as a throw, finally detected by the value the engine was
    -- already returning. Second return: the name that failed, or nil.
    if ZombRand(baseChance - skill) == 0 then
        local created = square:AddWorldInventoryItem(item,
            ZombRandFloat(0, 0.9), ZombRandFloat(0, 0.9), 0)
        return created ~= nil, created == nil and item or nil
    end
    if ZombRand(baseChance - welding) == 0 then
        local fallback = DOWNGRADE[item]
        if fallback then
            local created = square:AddWorldInventoryItem(fallback,
                ZombRandFloat(0, 0.9), ZombRandFloat(0, 0.9), 0)
            return false, created == nil and fallback or nil
        end
    end
    return false
end

local function grantScrap(square, character, state)
    local tiers = math.max(5, character:getPerkLevel(Perks.MetalWelding))
    for _ = 1, tiers do
        for _, entry in ipairs(SCRAP) do
            for _ = 1, 2 do
                -- Bare: the roll's engine calls are exposed methods whose
                -- faults are swallowed to nil (MethodCaller.java:33-56), so
                -- the old pcall could never fire. The one real failure - an
                -- item definition that cannot be created - now comes back as
                -- a name from checkAddItem's null-return detection instead of
                -- the throw the guard waited for.
                local added, failedName = checkAddItem(
                    square, character, entry[1], entry[2])
                if added then state.xp = state.xp + 1 end
                if failedName then
                    state.scrapFailures = (state.scrapFailures or 0) + 1
                    if not state.scrapError then
                        state.scrapError = "could not create " .. failedName
                    end
                end
            end
        end
    end
end

-- The caller must finish every reversible validation before entering here.
-- Returns false only when the authoritative removal itself fails. Once it
-- succeeds, later rewards are secondary and cannot put the vehicle back.
function RCDismantleYield.commit(vehicle, character, torch, eternal)
    if not (vehicle and character and torch) then
        return false, { phase = "precondition", error = "missing commit input" }
    end
    local square = vehicle:getSquare()
    if not square then
        return false, { phase = "precondition", error = "vehicle square unavailable" }
    end

    -- The load-bearing boundary, rebuilt on a POSTCONDITION instead of an
    -- inert pcall. The teardown's NPE sites (BaseVehicle.java:7127, :7148,
    -- :7158, :7220) are Java BODY throws in an exposed method - swallowed and
    -- stack-traced by MethodCaller (MethodCaller.java:33-56) - so the old
    -- `removed` was ALWAYS true and commit() had never once refused payment.
    -- What a successful teardown observably does is set removedFromWorld at
    -- :7146 and drop cell membership at :7177 (HashSet is exposed,
    -- LuaManager.java:1667); a fault at any cited NPE site leaves at least
    -- one of the two unset, so this pair is the first real "car is gone"
    -- check this contract has had. Blind spot: a fault at the final DB
    -- delete (:7220) reads as success and the row can respawn on reload -
    -- engine-logged when it happens.
    vehicle:permanentlyRemove()
    if not (vehicle:isRemovedFromWorld()
            and not getCell():getVehicles():contains(vehicle)) then
        return false, { phase = "remove",
            error = "removal incomplete (engine trace has the fault)" }
    end

    -- VehicleParts.removeFromWorld unregisters container processing but keeps
    -- the parts and containers intact (VehicleParts.java:401-411). Pass the
    -- captured square because permanentlyRemove clears world placement.
    local result = {
        phase = "committed",
        dumped = RCShared.dumpVehicleContainers(vehicle, square),
        xp = 5,
        eternal = eternal == true,
    }

    -- Optional scrap is a secondary reward batch. Individual roll failures
    -- are recorded by grantScrap without suppressing later independent rolls.
    grantScrap(square, character, result)

    if not eternal then
        -- InventoryItem.Use(..., bNeedSync=true) updates/removes the server item
        -- and sends the corresponding field/container packet
        -- (InventoryItem.java:1152-1201; DrainableComboItem.java:308-351).
        for _ = 1, 10 do torch:Use(false, false, true) end
    end
    -- addXp is the vanilla server-side XP path (server/XpSystem/XpUpdate.lua).
    addXp(character, Perks.MetalWelding, result.xp)
    return true, result
end

return RCDismantleYield

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
