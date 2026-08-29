-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCVehicleCheats - the right-click surfaces on the admin Vehicles tab (client).
--
-- Fills two seams the tab declares and never defines itself: showVehicleMenu
-- (right-click a list row) and showPartMenu (right-click a part on the
-- diagram). Kept out of RCVehicleTab because the tab is the inspector - it
-- shows you what is true - and this is the surface that CHANGES what is true.
-- The tab renders correctly and stays fully usable if this file never loads.
--
-- EVERY COMMAND HERE IS VANILLA'S. They travel on the "vehicle" module, not
-- RCShared.MODULE, and land in vanilla's own VehicleCommands - which applies
-- them SERVER-side and calls transmitPartCondition / transmitPartModData
-- afterwards. That matters: it is the same authoritative channel Delete uses,
-- so none of this can hit the "panel dismantle respawned the vehicle" class of
-- bug where a client-side write is quietly re-streamed away (found live
-- 2026-07-02).
--
-- GATING. Capability.UseMechanicsCheat, checked through RDAccess (Core's role
-- gate, which Reclamation hard-requires). This is the same capability vanilla
-- checks server-side on setPartCondition, so the menu shows exactly what the
-- server will actually honour rather than offering options that silently fail.
--
-- A NOTE ON WHAT VANILLA DOES NOT GATE. setContainerContentAmount, fixPart and
-- remove carry NO permission check in VehicleCommands - any client can send
-- them for any vehicle id. That hole is vanilla's and predates this menu; we
-- neither widen it nor rely on it. Everything here is gated uniformly on our
-- side regardless of which commands the server happens to check, because a
-- staff surface that mirrors vanilla's inconsistency would teach the wrong
-- thing about what is protected.
--
-- ATTRIBUTION. RCJanitor excludes every command sent here from its keeper
-- stamp (see its EXCLUDE table, 2026-08-02). Without that, an admin repairing
-- cars from this menu would become each one's RC_LastUser and the Presence Law
-- would shield the whole sweep from reclamation. Staff edits are not use.

if isServer() then return end

require "ISUI/ISTextBox"

RCVehicleTab = RCVehicleTab or {}
local T = RCVehicleTab

-- ---------------------------------------------------------------------------
-- Gate + transport
-- ---------------------------------------------------------------------------

local function canCheat()
    if not (RDAccess and Capability and Capability.UseMechanicsCheat) then return false end
    return RDAccess.roleHas(getPlayer(), Capability.UseMechanicsCheat)
end

-- Vanilla's channel, deliberately. See the header. sendClientCommand is
-- verified safe (pcall-safe.json globals) - no guard.
local function veh(cmd, args)
    sendClientCommand(getPlayer(), "vehicle", cmd, args)
end

-- Anything that mutates a car invalidates the cached part list for it, or the
-- diagram would keep drawing the shape the car was in before the edit. The
-- server's transmit updates the live object; this updates what we cached off it.
local function touched(vid, msg)
    if RCPartsView then RCPartsView.invalidate(vid) end
    if DFFeedback and msg then DFFeedback.good(msg) end
end

-- Vanilla's ISTextBox contract: the callback receives (target, button, ...the
-- trailing params), the entered text lives on button.parent.entry, and
-- button.internal is "OK" or "CANCEL".
local function prompt(title, default, onOk, ...)
    local args = { ... }
    local modal = ISTextBox:new(0, 0, 280, 180, title, tostring(default or ""), nil,
        function(_, button)
            if button.internal ~= "OK" then return end
            local text = button.parent.entry:getText()
            local n = tonumber(text)
            if not n then return end
            onOk(n, unpack(args))
        end, getPlayer():getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
end

-- ---------------------------------------------------------------------------
-- Part menu (right-click a part on the diagram)
-- ---------------------------------------------------------------------------

function T.showPartMenu(row, rec)
    if not (row and rec and row.vid) then return end
    local ctx = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    if not ctx then return end

    -- The part's own name and state as an unclickable heading, so the menu
    -- says WHICH part it is about. Right-clicking a 12-pixel sprite and
    -- getting an unlabelled menu is how you set the wrong part's condition.
    local head = string.format("%s  -  %s", tostring(rec.id),
        rec.missing and "missing" or ((rec.cond or 0) .. "%"))
    local info = ctx:addOption(head, nil, nil)
    info.notAvailable = true

    if not canCheat() then
        local o = ctx:addOption(getText("IGUI_RC_NoPermission"), nil, nil)
        o.notAvailable = true
        return
    end

    ctx:addOption("CHEAT: Repair part", nil, function()
        veh("repairPart", { vehicle = row.vid, part = rec.id })
        touched(row.vid, "Repaired " .. tostring(rec.id))
    end)

    ctx:addOption("CHEAT: Set condition...", nil, function()
        prompt("Condition (0-100):", rec.cond or 0, function(n)
            n = math.max(0, math.min(100, n))
            veh("setPartCondition", { vehicle = row.vid, part = rec.id, condition = n })
            touched(row.vid, string.format("%s -> %d%%", tostring(rec.id), n))
        end)
    end)

    -- Containers only; offering "set content amount" on a brake pad is noise.
    if rec.capacity then
        ctx:addOption(string.format("CHEAT: Set contents... (%s / %s)",
            tostring(rec.amount or 0), tostring(rec.capacity)), nil, function()
            prompt("Content amount:", rec.amount or 0, function(n)
                if n < 0 then n = 0 end
                veh("setContainerContentAmount", { vehicle = row.vid, part = rec.id, amount = n })
                touched(row.vid, string.format("%s -> %s", tostring(rec.id), tostring(n)))
            end)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle menu (right-click a list row)
-- ---------------------------------------------------------------------------

function T.showVehicleMenu(row)
    if not row then return end
    local ctx = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    if not ctx then return end

    local head = string.format("%s  #%s",
        RCShared.prettyVehicleName(row.script), tostring(row.vid or "unloaded"))
    local info = ctx:addOption(head, nil, nil)
    info.notAvailable = true

    -- Navigation works on any row with coordinates, including a registry row
    -- for a car nobody has streamed - that is the entire point of listing it.
    ctx:addOption("Teleport to", nil, function()
        if T.teleportTo then T.teleportTo(row) end
    end).notAvailable = (row.x == nil)

    -- Every mutation below needs a live object somewhere on the server, which
    -- an unloaded registry row by definition does not have.
    if not row.vid then
        local o = ctx:addOption("unloaded - nothing to edit until it streams in", nil, nil)
        o.notAvailable = true
    elseif canCheat() then
        ctx:addOption("CHEAT: Repair vehicle", nil, function()
            veh("repair", { vehicle = row.vid })
            touched(row.vid, "Repaired " .. RCShared.prettyVehicleName(row.script))
        end)

        ctx:addOption("CHEAT: Set rust...", nil, function()
            prompt("Rust (0-1):", "0", function(n)
                n = math.max(0, math.min(1, n))
                veh("setRust", { vehicle = row.vid, rust = n })
                touched(row.vid, "Rust -> " .. tostring(n))
            end)
        end)

        ctx:addOption("CHEAT: Get key", nil, function()
            veh("getKey", { vehicle = row.vid })
            if DFFeedback then DFFeedback.good("Key requested.") end
        end)

        -- addSubMenu RETURNS NOTHING - it only stamps option.subOption (see
        -- ISContextMenu.lua:1075). The submenu has to be built first and kept
        -- in its own local; assigning from the call gets nil.
        local hwOpt = ctx:addOption("CHEAT: Hotwire", nil, nil)
        local hw    = ISContextMenu:getNew(ctx)
        ctx:addSubMenu(hwOpt, hw)
        hw:addOption("Hotwired", nil, function()
            veh("cheatHotwire", { vehicle = row.vid, hotwired = true, broken = false })
            touched(row.vid, "Hotwired.")
        end)
        hw:addOption("Hotwire broken", nil, function()
            veh("cheatHotwire", { vehicle = row.vid, hotwired = true, broken = true })
            touched(row.vid, "Hotwire broken.")
        end)
        hw:addOption("Remove hotwire", nil, function()
            veh("cheatHotwire", { vehicle = row.vid, hotwired = false, broken = false })
            touched(row.vid, "Hotwire removed.")
        end)
    else
        local o = ctx:addOption(getText("IGUI_RC_NoPermission"), nil, nil)
        o.notAvailable = true
    end

    -- The family's row-action extension point. The consuming body lives in
    -- Core now (DFRegistry.addRowActions, promoted 2026-08-25) - this file's
    -- no-guard reading of it is the one the promotion adopted, so the
    -- reasoning travelled there with the code. The existence check stays:
    -- this menu builds off vanilla's context, so it must work with Dragonfly
    -- absent.
    if DFRegistry and DFRegistry.addRowActions then
        DFRegistry.addRowActions(ctx, "rcVehicles", row)
    end

    -- Destructive last, and through the tab's own confirm path so the modal,
    -- the claimed-car warning and the ledger report are identical whichever
    -- door the delete came through.
    if row.vid and T.confirmDeleteRows then
        ctx:addOption("Delete vehicle...", nil, function()
            T.confirmDeleteRows({ row })
        end)
    end
end

print("[RC] RCVehicleCheats loaded (vehicle + part context menus)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
