-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFRegistry - tab/action/badge registration for consumer mods.
--
-- Reaper, Husbandry, Dirge, and Ladybug all call into this if Dragonfly is
-- loaded. Each registration is just a table description; the deck (DFDeck)
-- reads it at panel-open time to build the UI. No registration means no
-- surface, which is how consumer mods stay shippable without Dragonfly.
--
-- Registration order doesn't matter; tabs are sorted by an optional `order`
-- field then alphabetically by label. A tab spec may also declare prefW /
-- prefH - the size the shell resizes itself to when the tab is shown
-- (clamped to the screen; a size the admin drags that tab to is remembered
-- per tab and wins). Same contract as the player panel's DFPlayerRegistry.

if isServer() then return end

-- Shared-tier Core, loads before any client file; required to state the
-- contract - addRowActions gates on RDAccess.roleHas.
require "RDAccess"

DFRegistry = DFRegistry or {
    tabs         = {},  -- [id] = spec
    rowActions   = {},  -- [tabId] = { spec, spec, ... }
    statusBadges = {},  -- [id] = spec
}

function DFRegistry.registerTab(spec)
    if not spec or not spec.id then
        print("[Dragonfly] registerTab refused: missing spec or id")
        return
    end
    DFRegistry.tabs[spec.id] = spec
    print("[Dragonfly] registerTab ok: " .. tostring(spec.id) .. " (" .. tostring(spec.label or "?") .. ")")
end

function DFRegistry.registerRowAction(spec)
    if not spec or not spec.tabId then return end
    local list = DFRegistry.rowActions[spec.tabId]
    if not list then list = {}; DFRegistry.rowActions[spec.tabId] = list end
    list[#list + 1] = spec
end

function DFRegistry.registerStatusBadge(spec)
    if not spec or not spec.id then return end
    DFRegistry.statusBadges[spec.id] = spec
end

function DFRegistry.getTabs()
    local out = {}
    for _, spec in pairs(DFRegistry.tabs) do
        -- supersededBy hides this tab if the named successor is also registered.
        -- Used by Dragonfly's basic Zombies tab to step aside for Reaper's Necro.
        local hide = spec.supersededBy and DFRegistry.tabs[spec.supersededBy] ~= nil
        if not hide then out[#out + 1] = spec end
    end
    table.sort(out, function(a, b)
        local oa = a.order or 100
        local ob = b.order or 100
        if oa ~= ob then return oa < ob end
        return tostring(a.label or "") < tostring(b.label or "")
    end)
    return out
end

-- PLACEHOLDER TABS. `spec.disabled = true` reserves a slot in the roster - the
-- label renders greyed and cannot be selected - without the tab having any
-- content behind it. It exists so a planned tab can take its final position in
-- the nav NOW, while the order is being settled, rather than shuffling every
-- other tab sideways on the day it ships.
--
-- Distinct from `capability`, which greys a REAL tab for a player whose role
-- lacks the permission: that one is per-player and flips live, this one is a
-- property of the build. Both shells render them the same way; only the reason
-- differs.
function DFRegistry.isSelectable(spec)
    return spec ~= nil and spec.disabled ~= true
end

-- The tab a shell should land on. NOT simply tabs[1]: a disabled tab sorted to
-- the front would leave the panel opening onto an empty content area with no
-- way to tell it apart from a tab that failed to build. Returns nil when every
-- registered tab is disabled, which callers treat as the empty state.
function DFRegistry.firstSelectable(tabs)
    for _, spec in ipairs(tabs or DFRegistry.getTabs()) do
        if DFRegistry.isSelectable(spec) then return spec.id end
    end
    return nil
end

function DFRegistry.getRowActions(tabId)
    return DFRegistry.rowActions[tabId] or {}
end

-- Add every registered row action for a tab onto a context menu. Promoted
-- 2026-08-25 from copies growing in DFPlayersTab and RPNecroTab (with a third
-- variant in RCVehicleCheats): the CONSUMING half of registerRowAction is one
-- rule, and three renditions of it had already started disagreeing about the
-- guard. Takes the CONTEXT rather than creating one, so a caller appending to
-- vanilla's own menu (RCVehicleCheats) and a caller opening a fresh
-- ISContextMenu use the same body.
--
-- Capability gate is RDAccess.roleHas - Core's own; DFCore.roleHas is a
-- delegate to it (DFCore.lua:44-46), so the behaviour every existing caller
-- had is unchanged and Core keeps not depending on Dragonfly.
--
-- NO pcall around the handler, and that is a decision with a body behind it,
-- carried from RCVehicleCheats' read: exactly one handler runs per click, so
-- there are no peers for a guard to protect, the result was never inspected,
-- and the engine writes the full Lua stack trace at throw time anyway
-- (KahluaThread.java:865, :1100). A guard here was a pure silencer.
function DFRegistry.addRowActions(context, tabId, row)
    if not context then return 0 end
    local actions = DFRegistry.getRowActions(tabId)
    for _, spec in ipairs(actions) do
        local enabled = true
        if spec.capability and RDAccess then
            enabled = RDAccess.roleHas(getPlayer(), spec.capability)
        end
        local opt = context:addOption(spec.label, row, spec.handler)
        if not enabled then opt.notAvailable = true end
    end
    return #actions
end

-- The whole right-click flow for an ISScrollingListBox row: resolve the row
-- under the cursor, refuse when no actions are registered, open a fresh
-- context menu at the mouse, add the actions. The two deck tabs' handlers
-- reduce to one line of policy each (WHICH tab id) - the mechanism was
-- identical and had already been written twice.
function DFRegistry.showRowMenu(list, x, y, tabId)
    local idx = list:rowAt(x, y)
    if idx <= 0 then return end
    local item = list.items[idx]
    if not item or not item.item then return end
    if #DFRegistry.getRowActions(tabId) == 0 then return end
    local context = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    DFRegistry.addRowActions(context, tabId, item.item)
end

function DFRegistry.getStatusBadges()
    local out = {}
    for _, spec in pairs(DFRegistry.statusBadges) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- Friendly alias for consumer mods. They write `Dragonfly.registerTab{...}`
-- rather than `DFRegistry.registerTab{...}`; reads cleaner from outside.
Dragonfly = Dragonfly or {}
Dragonfly.registerTab         = DFRegistry.registerTab
Dragonfly.registerRowAction   = DFRegistry.registerRowAction
Dragonfly.registerStatusBadge = DFRegistry.registerStatusBadge

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
