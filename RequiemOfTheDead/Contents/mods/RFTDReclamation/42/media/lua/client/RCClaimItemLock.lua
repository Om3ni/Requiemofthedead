-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCClaimItemLock - the steal-from-loot gate (client).
--
-- Door-open gating only protects a CLOSED trunk; an open trunk exposes its
-- loot through the inventory proximity panel. The door-state-independent
-- guarantee is a TRANSFER gate: block moving an item whose SOURCE resolves to
-- a vehicle the player lacks the INVENTORY permission on.
--
-- The nested-bag fix both reference mods miss: an item inside a duffel inside
-- the trunk has the DUFFEL as its container (getVehiclePart() = nil), so a
-- one-level check lets it through. vehicleOfItem walks the container chain OUT
-- of nested bags until it hits a vehicle part (or the root). Source-only -
-- depositing INTO an open trunk is harmless.
--
-- Wraps are applied on OnGameStart, NOT at file load: the transfer action
-- classes are not guaranteed to be defined when this file first runs (an
-- earlier build wrapped at load time and the wraps silently no-op'd because
-- the class was still nil -> the gate never fired at all). A load beacon logs
-- exactly which classes got wrapped so this can't hide again.

if isServer() and not isClient() then return end

RCClaimItemLock = RCClaimItemLock or {}

-- nil if the item is not vehicle-rooted; else the BaseVehicle it lives in.
local function vehicleOfItem(item)
    local c = item and item.getContainer and item:getContainer()
    while c do
        local v = c.getVehicle and c:getVehicle()
        if v then return v end                       -- this rung is a vehicle part
        local bag = c.getContainingItem and c:getContainingItem()
        if not bag then return nil end               -- root reached, not a vehicle
        c = bag.getContainer and bag:getContainer()  -- climb out of the bag
    end
    return nil
end
RCClaimItemLock.vehicleOfItem = vehicleOfItem

-- True if this item's source is a vehicle the character lacks INVENTORY perm on.
local function blocked(item, character)
    if not item or not character then return false end
    local v = vehicleOfItem(item)
    if not v then return false end
    return not RCClaim.canDo(v, character, "inventory")
end

-- Wrap an action's isValid: deny if its item is locked-vehicle-sourced. Traces
-- every check (throttled) so we can see whether the item resolved to a vehicle
-- and what canDo returned. Returns true if it wrapped, false if the class was
-- missing.
local function wrap(klass, name, getItem)
    if not klass then return false end
    if klass.RC_itemWrapped then return true end
    klass.RC_itemWrapped = true
    local orig = klass.isValid
    klass.isValid = function(self)
        local item, char = getItem(self), self.character
        if item and char then
            local v = vehicleOfItem(item)
            if v then
                local allowed = RCClaim.canDo(v, char, "inventory")
                RCShared.trace("itemgate:" .. name, "%s me=%s allowed=%s | %s",
                    name, tostring(char.getUsername and char:getUsername()), tostring(allowed), RCClaim.describe(v))
                if not allowed then return false end
            else
                RCShared.trace("itemgate:" .. name .. ":novehicle", "%s item not vehicle-rooted (container=%s)",
                    name, tostring(item.getContainer and item:getContainer() and item:getContainer():getType()))
            end
        end
        if orig then return orig(self) end
        return true
    end
    return true
end

local function applyWraps()
    local done = {}
    if wrap(ISInventoryTransferAction, "transfer", function(s) return s.item end) then done[#done+1] = "transfer" end
    if wrap(ISGrabItemAction,          "grab",     function(s) return s.item end) then done[#done+1] = "grab" end
    if wrap(ISEquipHeavyItem,          "equip",    function(s) return s.item end) then done[#done+1] = "equip" end

    -- Bulk "transfer all by weight" hands a list straight to the queue,
    -- bypassing per-item isValid. Filter locked-vehicle-sourced items first.
    if ISInventoryPane and not ISInventoryPane.RC_weightWrapped then
        ISInventoryPane.RC_weightWrapped = true
        local orig = ISInventoryPane.transferItemsByWeight
        ISInventoryPane.transferItemsByWeight = function(self, items, container)
            local player = self.player ~= nil and getSpecificPlayer(self.player) or nil
            if player and items then
                local kept, dropped = {}, 0
                for _, it in ipairs(items) do
                    if blocked(it, player) then dropped = dropped + 1 else kept[#kept + 1] = it end
                end
                if dropped > 0 then RCShared.trace("itemgate:byweight", "byweight filtered %d locked item(s)", dropped) end
                items = kept
            end
            if orig then return orig(self, items, container) end
        end
        done[#done + 1] = "byweight"
    end

    print("[RC] RCClaimItemLock wrapped: " .. table.concat(done, ",")
        .. ((#done < 4) and " | WARNING: a class was NIL" or ""))
end

-- Wrap on game start so every transfer-action class is guaranteed defined.
Events.OnGameStart.Add(applyWraps)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
