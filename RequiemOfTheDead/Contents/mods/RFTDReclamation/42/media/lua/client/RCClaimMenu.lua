-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCClaimMenu - menu suppression + the Claim/Release/Manage RADIAL slices.
--
-- Per-vehicle claim actions live on the vehicle RADIAL (controller-friendly, and
-- it dodges the narrow right-click hitbox on a multi-tile vehicle). Right-click
-- keeps ONLY the non-owner lock (suppression) + the debug dump - no claim options.
--
-- Two jobs:
--  1. SUPPRESS both vehicle menus for a player with no access to a claimed car.
--     The radial widget has no per-slice disable (only addSlice/clear), so we
--     short-circuit the populator: return before vanilla fills it and the whole
--     radial is gone. Right-click is short-circuited the same way.
--  2. APPEND our Claim / Release / Manage Access slices to the radial (after
--     vanilla builds it) for a player who owns / can claim the car.

if isServer() and not isClient() then return end

RCClaimMenu = RCClaimMenu or {}

-- Other RC files add their own per-vehicle radial slices through this list
-- (RCDismantleMenu registers here) so the mod keeps ONE radial wrap - one
-- toggle/visibility dance - instead of stacking fragile wrappers. Providers
-- run AFTER the claim slices, only for a canInteract vehicle, pcall-guarded.
RCClaimMenu.sliceProviders = RCClaimMenu.sliceProviders or {}
local providerFaults = {}

local M = RCShared.MODULE

local function lockedHalo(playerObj)
    RCShared.halo(playerObj, getText("IGUI_RC_Locked"), true)
end

-- Radial slice icons live in media/ui (64x64, to match the vanilla car radial).
-- getTexture catches its own load failures and returns nil for a missing file
-- (Texture.java:406-416), so a blank slice needs no guard.
local function rcTex(name)
    return getTexture("media/ui/" .. name .. ".png")
end

function RCClaimMenu.sendClaim(vehicle, playerObj)
    sendClientCommand(playerObj, M, "claim", { vehicleId = vehicle:getId() })
end

function RCClaimMenu.sendUnclaim(vehicle, playerObj)
    sendClientCommand(playerObj, M, "unclaim", { vehicleId = vehicle:getId() })
end

function RCClaimMenu.openManage(vehicle, playerObj)
    if RCClaimGUI and RCClaimGUI.open then RCClaimGUI.open(vehicle, playerObj) end
end

-- Radial slice callbacks. addSlice invokes them as cb(arg1, arg2) = (player, veh).
function RCClaimMenu.onRadialClaim(playerObj, vehicle)   RCClaimMenu.sendClaim(vehicle, playerObj) end
function RCClaimMenu.onRadialRelease(playerObj, vehicle) RCClaimMenu.sendUnclaim(vehicle, playerObj) end
function RCClaimMenu.onRadialManage(playerObj, vehicle)  RCClaimMenu.openManage(vehicle, playerObj) end

-- Append our slices to an already-built radial for an interactable car.
function RCClaimMenu.addRadialSlices(menu, vehicle, playerObj)
    if not RCShared.cfg().claimsEnabled then return end

    local owner   = RCClaim.getOwner(vehicle)
    local name    = playerObj:getUsername()
    local isOwner = owner and owner == name
    local isAdmin = RCShared.isAdmin(playerObj)

    if not owner then
        if RCClaim.canClaim(vehicle, playerObj) then
            menu:addSlice(getText("IGUI_RC_Claim"), rcTex("RC_claim"), RCClaimMenu.onRadialClaim, playerObj, vehicle)
        end
    elseif isOwner or isAdmin then
        menu:addSlice(getText("IGUI_RC_Release"), rcTex("RC_release"), RCClaimMenu.onRadialRelease, playerObj, vehicle)
        -- whitelist management is owner-only (admins can release, not re-permission)
        if isOwner then
            menu:addSlice(getText("IGUI_RC_Manage"), rcTex("RC_manage"), RCClaimMenu.onRadialManage, playerObj, vehicle)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Apply the menu wraps on OnGameStart (NOT file-load): KI5/damnlib wrap these
-- same vanilla functions at load to add THEIR radial slices. Wrapping later
-- makes OUR wrap the OUTERMOST link - a non-owner denial short-circuits before
-- the inner wrappers run (their slices never appear either), and our appended
-- slices are added AFTER all inner wraps + vanilla have populated the wheel.
-- ---------------------------------------------------------------------------
local function applyMenuWraps()
    if not ISVehicleMenu then return end

    -- Radial (outside-vehicle): suppress for no-access players; for everyone
    -- else, let the whole chain build the wheel, then append our slices.
    if ISVehicleMenu.showRadialMenuOutside and not ISVehicleMenu.RC_radialWrapped then
        ISVehicleMenu.RC_radialWrapped = true
        local orig = ISVehicleMenu.showRadialMenuOutside
        ISVehicleMenu.showRadialMenuOutside = function(playerObj)
            local v = ISVehicleMenu.getVehicleToInteractWith and ISVehicleMenu.getVehicleToInteractWith(playerObj)
            if v and not RCClaim.canInteract(v, playerObj) then
                lockedHalo(playerObj)
                return -- suppress the entire radial (ours + vanilla + KI5 slices)
            end
            -- Capture visibility BEFORE orig. showRadialMenuOutside is a toggle:
            -- if the wheel was already showing, orig CLOSES it (don't append);
            -- if it wasn't, orig OPENS it (append our slices). We must test this
            -- beforehand - `isReallyVisible()` reads a Java flag the render pass
            -- sets, so it's still false in the same frame right AFTER orig opens
            -- the menu (which is why the earlier post-check silently no-op'd).
            local pi = playerObj:getPlayerNum()
            local menu = getPlayerRadialMenu(pi)
            local wasVisible = menu and menu:isReallyVisible()
            orig(playerObj)
            if v and menu and not wasVisible and not menu:isEmpty() then
                RCClaimMenu.addRadialSlices(menu, v, playerObj)
                for index, provider in ipairs(RCClaimMenu.sliceProviders) do
                    -- KEEP: this registry is an extension boundary. One foreign
                    -- provider must not suppress later independent slices.
                    local ok, err = pcall(provider, menu, v, playerObj)
                    if not ok and not providerFaults[provider] then
                        providerFaults[provider] = true
                        print("[RC] radial slice provider " .. tostring(index)
                            .. " failed: " .. tostring(err))
                    end
                end
                -- re-center: added slices may have changed the wheel size
                -- (mirrors vanilla's own positioning at the end of orig).
                -- Vanilla width/height instantiate their backing object when
                -- needed; setX/setY then update normal UI geometry
                -- (ISUIElement.lua:195-215, 259-271).
                menu:setX(getPlayerScreenLeft(pi) + getPlayerScreenWidth(pi) / 2 - menu:getWidth() / 2)
                menu:setY(getPlayerScreenTop(pi) + getPlayerScreenHeight(pi) / 2 - menu:getHeight() / 2)
            end
        end
    end

    -- Right-click (outside-vehicle): keep ONLY the non-owner suppression + the
    -- debug dump. Claim actions moved to the radial (owner's UX call).
    if ISVehicleMenu.FillMenuOutsideVehicle and not ISVehicleMenu.RC_fillWrapped then
        ISVehicleMenu.RC_fillWrapped = true
        local orig = ISVehicleMenu.FillMenuOutsideVehicle
        ISVehicleMenu.FillMenuOutsideVehicle = function(player, context, vehicle, test)
            local playerObj = getSpecificPlayer(player)
            -- Debug dump is offered REGARDLESS of access (even on a fully locked
            -- car) so a locked-out tester can inspect why.
            if vehicle and playerObj and not test and RCShared.cfg().debug then
                context:addOption("RC: Dump Claim Info", playerObj, function() RCClaimMenu.dump(vehicle, playerObj) end)
            end
            if vehicle and playerObj and not RCClaim.canInteract(vehicle, playerObj) then
                return -- no vanilla vehicle options, no KI5 options
            end
            orig(player, context, vehicle, test)
        end
    end
end

Events.OnGameStart.Add(applyMenuWraps)

-- Debug: print THIS client's full view of a vehicle's access, then ask the
-- server to print its authoritative view. Run it on the locked-out account.
function RCClaimMenu.dump(vehicle, playerObj)
    local parts = {}
    for _, perm in ipairs(RCClaim.PERMS) do
        parts[#parts + 1] = perm .. "=" .. tostring(RCClaim.canDo(vehicle, playerObj, perm))
    end
    print("[RC][cl] DUMP me=" .. tostring(playerObj:getUsername())
        .. " admin=" .. tostring(RCShared.isAdmin(playerObj))
        .. " canInteract=" .. tostring(RCClaim.canInteract(vehicle, playerObj))
        .. " canDo{" .. table.concat(parts, ",") .. "} | " .. RCClaim.describe(vehicle))
    sendClientCommand(playerObj, M, "dumpclaim", { vehicleId = vehicle:getId() })
end

-- Print the server's authoritative view next to the client view.
local function onServerCommand(module, command, args)
    if module ~= M then return end
    if command == "DumpReply" then
        print("[RC][cl] SERVER-VIEW " .. tostring(args and args.text))
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
