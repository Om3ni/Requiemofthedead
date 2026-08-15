-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleAction - the dismantle timed action (DESIGN §1). Shared, like
-- its vanilla base class.
--
-- Derives ISRemoveBurntVehicle and inherits for free: the BlowTorch
-- requirement, anim/sound, skill-scaled duration, the scrap table's drop
-- rates (checkAddItem), and server-synced removal. complete() is OUR OWN,
-- not vanilla's (the Nep lesson, DESIGN §References): modded (KI5) part
-- layouts throw inside unguarded vanilla teardown steps and abort the action
-- BEFORE removal - so every step here is pcall-guarded and the removal is
-- reached regardless of scrap-loop hiccups. Steps:
--   1. dump all container contents to the ground (loot is never vaporized)
--   2. roll the vanilla scrap table (inherited checkAddItem - identical loot)
--   3. torch wear + MetalWelding XP (vanilla amounts)
--   4. remove the vehicle - SERVER-side in MP (see complete(); a client-side
--      permanentlyRemove() is local-only and the server re-streams the car)
--   5. one small client command so the server writes the ledger line (and
--      prunes the claim index if this car carried a claim - the panel path)

require "Vehicles/TimedActions/ISRemoveBurntVehicle"

RCDismantleAction = ISRemoveBurntVehicle:derive("RCDismantleAction")

-- The vanilla scrap table (ISRemoveBurntVehicle:complete), rolled twice per
-- entry per skill-tier iteration via the INHERITED checkAddItem, so drop
-- rates and the downgrade fallbacks stay byte-identical to vanilla.
local SCRAP = {
    { "AluminumScrap", 12 }, { "CopperScrap", 12 }, { "ElectricWire", 25 },
    { "EngineParts", 25 }, { "IronBand", 25 }, { "IronBandSmall", 15 },
    { "IronScrap", 12 }, { "MetalBar", 15 }, { "MetalPipe", 15 },
    { "NutsBolts", 25 }, { "ScrapMetal", 12 }, { "Screws", 25 },
    { "SheetMetal", 25 }, { "SmallSheetMetal", 15 }, { "SteelBar", 25 },
    { "SteelBarHalf", 15 }, { "SteelBarQuarter", 12 }, { "SteelBlock", 25 },
    { "SteelChunk", 15 }, { "SteelPiece", 12 }, { "Wire", 25 },
}

-- Backstop only - the menus gate at click time (claim -> zone -> engine ->
-- tools). This re-checks just the claim (cheap modData reads, no allocation)
-- so a car claimed mid-action stops the teardown.
function RCDismantleAction:isValid()
    if not ISRemoveBurntVehicle.isValid(self) then return false end
    if RCShared.claimDismantleBlock(self.vehicle, self.character) then return false end
    return true
end

-- Admin-tunable teardown time. The base stays skill-scaled; 100 = vanilla.
function RCDismantleAction:getDuration()
    local base = ISRemoveBurntVehicle.getDuration(self)
    local pct = RCShared.cfg().dismantleTimePct
    if pct == 100 or base <= 10 then return base end
    return math.max(10, math.floor(base * pct / 100))
end

function RCDismantleAction:complete()
    local v = self.vehicle
    if not v then return false end

    -- Snapshot everything the ledger needs BEFORE removal destroys it.
    -- All field returns / null-checked reads (BaseVehicle.java:1593,
    -- IsoMovingObject getters, VehicleParts.java:125) - no guard needed.
    local report = { via = self.rcVia or "field" }
    report.vehicle = v:getScriptName()
    report.wreck = RCShared.isWreck(v)
    report.x = math.floor(v:getX())
    report.y = math.floor(v:getY())
    report.z = math.floor(v:getZ())
    local _, cond = RCShared.engineBlocksDismantle(v)
    report.engine = cond
    if RCClaim.isClaimed(v) then
        report.owner   = RCClaim.getOwner(v)
        report.claimId = RCClaim.getClaimId(v)
    end

    RCShared.dumpVehicleContainers(v)   -- guards its own per-item drops

    local totalXp = 5
    -- guarded: checkAddItem is vanilla LUA (ISBaseTimedAction), unverifiable
    -- against the decompile; a throw must not cost the player the teardown
    pcall(function()
        for _ = 1, math.max(5, self.character:getPerkLevel(Perks.MetalWelding)) do
            for _, e in ipairs(SCRAP) do
                if self:checkAddItem(e[1], e[2]) then totalXp = totalXp + 1 end
                if self:checkAddItem(e[1], e[2]) then totalXp = totalXp + 1 end
            end
        end
    end)
    -- guarded: InventoryItem.Use drains/deletes through engine item state and
    -- addXp is vanilla-LUA-adjacent; wear+XP must not block the removal below
    pcall(function()
        -- Eternal Torch admin cheat (client/RCEternalTorch): staff dismantles
        -- skip torch wear. Guarded existence check - this file is shared/,
        -- and the cheat module is client-only.
        if RCEternalTorch and RCEternalTorch.active(self.character) then
            report.cheat = "eternal-torch"
        else
            for _ = 1, 10 do self.item:Use(false, false, true) end
        end
        addXp(self.character, Perks.MetalWelding, totalXp)
    end)

    -- Removal is the one step that must not be swallowed silently: if it
    -- threw, the car is still there - report failure, write no ledger line.
    -- MP: permanentlyRemove() is LOCAL-ONLY (BaseVehicle.java:7300, no
    -- packet) - a client calling it deletes its own copy and the server
    -- re-streams the car ("it respawned", found live 2026-07-02). Vanilla's
    -- own idiom (ISVehicleMechanics.onCheatRemoveAux) is the fix: ask the
    -- server's built-in 'vehicle'/'remove' command; the server-side removal
    -- then propagates to every client. SP/host removes directly. (Vanilla's
    -- ISRemoveBurntVehicle:complete() has this same MP bug - ours doesn't.)
    -- guarded: permanentlyRemove cascades through exit/physics/world teardown
    -- (BaseVehicle.java:7205); a throw means the car still stands - report
    -- failure, write no ledger line
    local removed = pcall(function()
        if isClient() then
            sendClientCommand(self.character, "vehicle", "remove", { vehicle = v:getId() })
        else
            v:permanentlyRemove()
        end
    end)
    if not removed then
        RCShared.dbg("dismantle: vehicle removal threw on %s", tostring(report.vehicle))
        return false
    end

    sendClientCommand(self.character, RCShared.MODULE, "dismantled", report)
    return true
end

-- via: "field" (player, gated) or "panel" (admin tab, gates bypassed).
function RCDismantleAction:new(character, vehicle, via)
    local o = ISRemoveBurntVehicle.new(self, character, vehicle)
    o.rcVia = via or "field"
    return o
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
