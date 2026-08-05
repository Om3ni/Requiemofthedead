-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCDismantleMenu - the client entry points for dismantling (DESIGN §1).
--
-- Radial is PRIMARY (controller-first; the right-click hitbox on a
-- multi-tile vehicle is narrow), right-click is parity. The radial widget
-- has no grey/disabled slice state (engine fact), so the slice always shows
-- for an eligible player and the GATES run at click time with an OOC halo on
-- a block. Right-click DOES support greying, so there the same block reason
-- becomes notAvailable + a tooltip.
--
-- Gate order (locked in DESIGN §1): claim -> phunzone -> engine -> tools.

if isServer() and not isClient() then return end

RCDismantleMenu = RCDismantleMenu or {}

-- Tool predicates. Vanilla's own (ISVehicleMenu / ISRemoveBurntVehicle) are
-- file-local, so we mirror them: tag OR type, torch needs 10 uses.
local function predicateMask(item)
    return item ~= nil and (item:hasTag(ItemTag.WELDING_MASK) or item:getType() == "WeldingMask")
end
local function predicateTorch(item)
    return item ~= nil and (item:hasTag(ItemTag.BLOW_TORCH) or item:getType() == "BlowTorch")
        and item:getCurrentUses() >= 10
end

-- Visibility vs gates: the entry is HIDDEN only for states that cannot
-- change while the menu is open (mod off, staff-only for a non-staff
-- player). Everything else stays visible and gates at click/select time.
function RCDismantleMenu.visible(vehicle, playerObj)
    local c = RCShared.cfg()
    if not c.enabled then return false end
    if c.adminOnlyDismantle and not RCShared.isAdmin(playerObj) then return false end
    return vehicle ~= nil
end

-- First blocking reason as a ready-to-display string, or nil when clear.
-- Second return marks an IN-CHARACTER thought (the engine-too-good line), so
-- the radial can float it thought-styled instead of error-red.
function RCDismantleMenu.blockReason(vehicle, playerObj)
    local claim = RCShared.claimDismantleBlock(vehicle, playerObj)
    if claim == "self" then return getText("IGUI_RC_DismReleaseFirst") end
    if claim == "other" then return getText("IGUI_RC_DismClaimed") end
    if not RCShared.isWreck(vehicle)
        and RCShared.phunZoneBlocks(vehicle:getX(), vehicle:getY()) then
        return getText("IGUI_RC_DismZoneBlocked")
    end
    if RCShared.engineBlocksDismantle(vehicle) then
        -- Admin-customizable line (sandbox EngineTooGoodText, trimmed +
        -- capped at 120 chars in RCShared.cfg); blank = the translated
        -- in-character default. {threshold} inserts the threshold number via
        -- plain gsub - NEVER getText-with-args here: an admin string with a
        -- literal % would throw inside Java String.format (engine fact).
        local c = RCShared.cfg()
        local msg = c.engineTooGoodText or getText("IGUI_RC_EngineTooGood")
        return (msg:gsub("{threshold}", tostring(c.engineThreshold))), true
    end
    local inv = playerObj:getInventory()
    if not inv:containsEvalRecurse(predicateMask) then return getText("IGUI_RC_DismNoMask") end
    if not inv:containsEvalRecurse(predicateTorch) then return getText("IGUI_RC_DismNoTorch") end
    return nil
end

function RCDismantleMenu.label(vehicle)
    return RCShared.isWreck(vehicle) and getText("IGUI_RC_DismantleWreck") or getText("IGUI_RC_Dismantle")
end

-- Queue the action, mirroring vanilla onRemoveBurntVehicle: walk adjacent,
-- auto-equip the torch, auto-wear the mask.
local function queueDismantle(playerObj, vehicle)
    if luautils.walkAdj(playerObj, vehicle:getSquare()) then
        ISWorldObjectContextMenu.equip(playerObj, playerObj:getPrimaryHandItem(), predicateTorch, true)
        local mask = playerObj:getInventory():getFirstEvalRecurse(predicateMask)
        if mask then
            ISInventoryPaneContextMenu.wearItem(mask, playerObj:getPlayerNum())
        end
        ISTimedActionQueue.add(RCDismantleAction:new(playerObj, vehicle))
    end
end

-- Radial click: gate NOW (the slice can't grey), halo the reason on a block.
-- The engine-too-good line floats thought-styled (soft blue-white); every
-- other block stays error-red.
function RCDismantleMenu.onRadialDismantle(playerObj, vehicle)
    local reason, isThought = RCDismantleMenu.blockReason(vehicle, playerObj)
    if reason then
        if isThought then
            RCShared.haloThought(playerObj, reason)
        else
            RCShared.halo(playerObj, reason, true)
        end
        return
    end
    queueDismantle(playerObj, vehicle)
end

-- Right-click select re-gates too: a menu built moments ago can be clicked
-- after the state changed (torch dropped, car claimed).
function RCDismantleMenu.onMenuDismantle(playerObj, vehicle)
    RCDismantleMenu.onRadialDismantle(playerObj, vehicle)
end

-- ---------------------------------------------------------------------------
-- Radial: register as a slice provider on RCClaimMenu's single radial wrap
-- (one wrap = one toggle/visibility dance; see RCClaimMenu). Both files
-- defensively init the table so load order can't matter.
-- ---------------------------------------------------------------------------
RCClaimMenu = RCClaimMenu or {}
RCClaimMenu.sliceProviders = RCClaimMenu.sliceProviders or {}
table.insert(RCClaimMenu.sliceProviders, function(menu, vehicle, playerObj)
    if not RCDismantleMenu.visible(vehicle, playerObj) then return end
    -- owner's torch art (64x64, matches the RC_claim/release/manage set);
    -- vanilla item icon as fallback. A nil texture renders a blank slice,
    -- never a crash.
    local tex
    pcall(function() tex = getTexture("media/ui/RC_dismantle.png") end)
    if not tex then pcall(function() tex = getTexture("Item_BlowTorch") end) end
    menu:addSlice(RCDismantleMenu.label(vehicle), tex, RCDismantleMenu.onRadialDismantle, playerObj, vehicle)
end)

-- ---------------------------------------------------------------------------
-- Right-click parity. Wrapped at OnGameStart (never file-load - the dead-wrap
-- lesson); this file loads after RCClaimMenu alphabetically, so this wrap is
-- OUTERMOST: orig() runs RCClaimMenu's suppression + KI5's wraps + vanilla
-- first, then we append.
-- ---------------------------------------------------------------------------
local function applyContextWrap()
    if not ISVehicleMenu or ISVehicleMenu.RC_dismantleWrapped then return end
    ISVehicleMenu.RC_dismantleWrapped = true
    local orig = ISVehicleMenu.FillMenuOutsideVehicle
    ISVehicleMenu.FillMenuOutsideVehicle = function(player, context, vehicle, test)
        local r = orig(player, context, vehicle, test)
        if test then return r end
        local playerObj = getSpecificPlayer(player)
        if not (vehicle and playerObj) then return r end
        -- the inner (claim) wrap suppressed the whole menu for a no-access
        -- player; match it rather than re-adding an option to a bare menu
        if not RCClaim.canInteract(vehicle, playerObj) then return r end
        if not RCDismantleMenu.visible(vehicle, playerObj) then return r end

        -- Ours subsumes vanilla's wreck-removal option (same teardown, plus
        -- the loot dump + the ledger line); drop the duplicate ONLY when we
        -- are actually adding ours - if dismantle is staff-only, players
        -- keep the vanilla option (guard above already returned).
        pcall(function() context:removeOptionByName(getText("ContextMenu_RemoveBurntVehicle")) end)

        local option = context:addOption(RCDismantleMenu.label(vehicle), playerObj, RCDismantleMenu.onMenuDismantle, vehicle)
        local reason = RCDismantleMenu.blockReason(vehicle, playerObj)
        if reason then
            option.notAvailable = true
            local tip = ISToolTip:new()
            tip:initialise()
            tip:setVisible(false)
            tip:setName(RCDismantleMenu.label(vehicle))
            tip.description = reason
            option.toolTip = tip
        end
        return r
    end
end
Events.OnGameStart.Add(applyContextWrap)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
