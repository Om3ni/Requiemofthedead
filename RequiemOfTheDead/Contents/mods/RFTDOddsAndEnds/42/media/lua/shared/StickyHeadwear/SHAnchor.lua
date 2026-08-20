-- SPDX-License-Identifier: GPL-3.0-or-later
-- SHAnchor.lua - instance-level headwear pinning shared by SP and the server.
--
-- Multiplayer authority is the reason this is shared. IsoGameCharacter.helmetFall
-- returns immediately on a client (IsoGameCharacter.java:7526-7529); the server
-- reads Clothing.chanceToFall and sends ZombieHelmetFallingPacket itself. The
-- client and server therefore have different item instances, and both contexts
-- must pin the instance that owns the decision made there.
--
-- Script definitions are read only to discover relevant body locations. They
-- are never changed: IsoZombie.java:4934-4939 and PersistentOutfits.java:314
-- consult the script value when assembling zombie outfits, so changing it would
-- also change horde appearance and loot.

require "OEShared"

StickyHeadwear = StickyHeadwear or {}
local SH = StickyHeadwear

-- One record per instance changed by this module. Keeping the item reference is
-- deliberate: an id alone cannot restore an item after it leaves the worn set.
SH.original = SH.original or {}

local locations = nil

function SH.isEnabled()
    return OEShared.enabled("StickyHeadwearEnable")
end

local function chanceOf(item)
    if not item or not item.getChanceToFall then return nil end
    local chance = item:getChanceToFall()
    if type(chance) ~= "number" then return nil end
    return chance
end

local function restore(id, record)
    local item = record and record.item
    if item and item.setChanceToFall then
        -- Clothing.setChanceToFall is a plain field assignment
        -- (Clothing.java:876-878), so no exception boundary belongs here.
        item:setChanceToFall(record.chance)
    end
    SH.original[id] = nil
end

local function pin(character, item)
    local chance = chanceOf(item)
    if chance == nil then return nil end

    local id = item:getID()
    if type(id) ~= "number" then return nil end

    local record = SH.original[id]
    if record and record.item ~= item then
        -- Defensive against an id being reused after the old instance left the
        -- world. Restore the object we actually changed before adopting the id.
        restore(id, record)
        record = nil
    end

    if record then
        record.owner = character
        if chance > 0 then item:setChanceToFall(0) end
        return id
    end

    if chance <= 0 or not item.setChanceToFall then return nil end
    SH.original[id] = { item = item, chance = chance, owner = character }
    item:setChanceToFall(0)
    return id
end

-- Build a small set of slots instead of walking every worn item on every server
-- tick. ScriptManager.getAllItems returns the live post-mod registry
-- (ScriptManager.java:700-702); Item.getBodyLocation and getChanceToFall are
-- field returns (Item.java:1373-1375, 3819-3821).
function SH.indexLocations()
    if locations then return #locations end

    local manager = getScriptManager()
    local all = manager and manager:getAllItems()
    if not all then return 0 end -- world/scripts not ready; a later pass retries

    local found, seen = {}, {}
    for i = 0, all:size() - 1 do
        local script = all:get(i)
        local chance = script and script:getChanceToFall()
        local location = script and script:getBodyLocation()
        if type(chance) == "number" and chance > 0 and location then
            local key = tostring(location)
            if not seen[key] then
                seen[key] = true
                found[#found + 1] = location
            end
        end
    end
    locations = found
    return #locations
end

-- Reconcile one character's authoritative worn set. Items that disappeared
-- since the previous pass are restored here, which the old worn-only sweep
-- could not do after an unequip.
function SH.reconcile(character)
    if not character then return end

    local current = {}
    if SH.isEnabled() then
        SH.indexLocations()
        if locations then
            for _, location in ipairs(locations) do
                local item = character:getWornItem(location)
                local id = item and pin(character, item)
                if id then current[id] = true end
            end
        end
    end

    for id, record in pairs(SH.original) do
        if record.owner == character and not current[id] then
            restore(id, record)
        end
    end
end

-- Server disconnects have no usable Lua event in 42.20.2. The server runner
-- supplies the current player set each tick so stale records release both the
-- changed value and their strong item/character references.
function SH.releaseMissing(activeOwners)
    for id, record in pairs(SH.original) do
        if not activeOwners[record.owner] then restore(id, record) end
    end
end

function SH.trackedCount()
    local count = 0
    for _ in pairs(SH.original) do count = count + 1 end
    return count
end

return SH

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
