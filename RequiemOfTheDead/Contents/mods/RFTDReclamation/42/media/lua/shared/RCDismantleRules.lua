-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleRules - one shared definition of dismantle prerequisites.
--
-- The client uses these rules for immediate menu feedback. The server repeats
-- them before issuing a permit and before committing the removal; only that
-- second use is authoritative. Keep reasons as stable internal codes so UI and
-- audit surfaces can explain the same refusal without trusting client prose.

RCDismantleRules = RCDismantleRules or {}

local MIN_TORCH_USES = 10

local function isMask(item)
    return item ~= nil
        and (item:hasTag(ItemTag.WELDING_MASK) or item:getType() == "WeldingMask")
end

-- PRESENCE CHECK, NOT A GUARD. The predicate matches on tag OR type, so a
-- modded item merely TAGGED BlowTorch without being a DrainableComboItem has no
-- getCurrentUses at all, and calling it is a nil-method throw. Kahlua answers
-- that deterministically - an absent method is nil - so testing for it is exact.
-- Same idiom RCEternalTorch.refillTorches uses on the identical hazard.
--
-- This was recorded as a cosmetic inconsistency because the walk paths swallow
-- it: getFirstEvalRecurse is the one lane the engine discards silently
-- (KahluaThread.java:1261-1278), and a real torch later in the walk still
-- matched. That reading missed primaryTorch, which calls this predicate
-- DIRECTLY from RCDismantleAuthority.lua:178 - the server's authoritative
-- dismantle transaction - and from RCDismantleAction.lua:57. Nothing swallows
-- it there. A player holding such an item in their primary hand threw inside
-- the transaction rather than being told their torch was unsuitable.
local function isTorch(item)
    return item ~= nil
        and (item:hasTag(ItemTag.BLOW_TORCH) or item:getType() == "BlowTorch")
        and item.getCurrentUses ~= nil
        and item:getCurrentUses() >= MIN_TORCH_USES
end

RCDismantleRules.isMask = isMask
RCDismantleRules.isTorch = isTorch

function RCDismantleRules.findMask(character)
    local inv = character and character:getInventory()
    return inv and inv:getFirstEvalRecurse(isMask) or nil
end

function RCDismantleRules.findTorch(character)
    local inv = character and character:getInventory()
    return inv and inv:getFirstEvalRecurse(isTorch) or nil
end

function RCDismantleRules.primaryTorch(character)
    local item = character and character:getPrimaryHandItem()
    return isTorch(item) and item or nil
end

-- Validate every persistent gameplay rule. Range and primary-hand state are
-- completion-only facts and remain in the authoritative server transaction.
-- Returns nil plus useful resolved state when allowed, or a reason code.
function RCDismantleRules.check(vehicle, character)
    local c = RCShared.cfg()
    if not c.enabled then return "disabled" end
    if c.adminOnlyDismantle and not RCShared.isAdmin(character) then
        return "staff-only"
    end
    if not vehicle or vehicle:isRemovedFromWorld() then return "gone" end

    local claim = RCShared.claimDismantleBlock(vehicle, character)
    if claim == "self" then return "claim-self" end
    if claim == "other" then return "claim-other" end

    local wreck = RCShared.isWreck(vehicle)
    if not wreck and RCShared.phunZoneBlocks(vehicle:getX(), vehicle:getY()) then
        return "zone"
    end

    local blocked, engine = RCShared.engineBlocksDismantle(vehicle)
    if blocked then return "engine", { engine = engine, wreck = wreck } end

    -- BaseVehicle.hasPassenger is a bounds-checked walk of the vehicle's own
    -- passenger array (BaseVehicle.java:1775-1781). Authoritative removal must
    -- never eject an unsuspecting occupant as a side effect.
    if vehicle:hasPassenger() then return "occupied" end
    if not RCDismantleRules.findMask(character) then return "mask" end

    local torch = RCDismantleRules.findTorch(character)
    if not torch then return "torch" end
    return nil, { engine = engine, wreck = wreck, torch = torch }
end

return RCDismantleRules

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
