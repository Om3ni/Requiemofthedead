-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDClothing.lua - clothing state primitives the engine exposes but nothing wraps.
--
-- WHY THIS IS IN CORE: two consumers. Dragonfly's admin panel needs to mend holes
-- (its Repair All could not) and Wardrobe will need to reproduce holes when it
-- restores a stored outfit. Both also need the clothing sync below, and getting
-- that wrong is invisible in single-player, which is exactly the kind of mistake
-- that should be made once in one place.
--
-- THE SYNC TRAP, which is the real reason this file exists. Clothing blood, dirt,
-- holes and patches do NOT live on the InventoryItem - they live on its ItemVisual
-- (private byte[] blood / dirt arrays indexed by BloodBodyPartType). sendItemStats
-- syncs item STAT FIELDS and does not touch the visual, so a server-side write to
-- any of them lands on the server and is never seen by another client. Dragonfly's
-- Repair All had this bug: it cleared blood and dirt and synced with
-- sendItemStats, so nothing propagated. The fix is syncClothingFields, a Lua
-- global (LuaManager.java:3719) that is server-gated internally.
--
-- Clothing.fullyRestore() is the exception - it sends SyncClothing to all itself
-- (Clothing.java:1012), so callers using it do not additionally need sync(). It is
-- also the right call for a FULL restore, because it clears patches too, which we
-- cannot do from Lua: Clothing.patches is a private HashMap with no public
-- remover. mendHoles below is therefore holes-only by necessity, not by choice.
--
-- HOLES ARE REMOVE-ONLY, on purpose. ItemVisual.setHole(part) would let us punch
-- new holes in someone's coat. There is no admin task that needs that and it is a
-- clean griefing primitive, so mendHoles refuses to raise the count.
--
-- Condition math mirrors vanilla: Clothing.addPatch credits getCondLossPerHole()
-- back when it fully restores a part (Clothing.java:1029), so mending a hole here
-- credits the same amount rather than inventing a number.
--
-- ENGINE-TOUCHING, unlike RDItemKind: BloodBodyPartType, syncClothingFields and
-- instanceof are all globals. Each is reached inside a function behind a
-- nil/type() check, so loading this file costs nothing and a test only stubs
-- what it actually calls.

RDClothing = RDClothing or {}

-- Number of body-part slots the blood/dirt/hole arrays are indexed by. Read from
-- the enum rather than hardcoded because it has changed across builds.
function RDClothing.partCount()
    -- index() is ordinal() (BloodBodyPartType:44); the chain covers the
    -- global being absent under test stubs
    local maxPart = BloodBodyPartType and BloodBodyPartType.MAX
    local n = maxPart and maxPart:index() or nil
    if type(n) ~= "number" or n <= 0 then return 0 end
    return n
end

function RDClothing.isClothing(item)
    if not item then return false end
    -- instanceof (LuaManager:2837) null-checks obj and falls through to
    -- false on an unknown name; the type() covers test stubs
    if type(instanceof) ~= "function" then return false end
    return instanceof(item, "Clothing") == true
end

-- Body-part indices that currently have a hole, ascending.
function RDClothing.holeParts(item)
    local out = {}
    if not item then return out end

    -- getVisual (InventoryItem:2070) can NPE: getClothingItem:2045 derefs
    -- scriptItem.replacePrimaryHand.clothingItem unguarded on hand-replacement
    -- items, and arbitrary items land here from the admin panel - guard stays
    if type(item.getVisual) ~= "function" then return out end
    local ok, visual = pcall(item.getVisual, item)
    if not ok or not visual then return out end

    for i = 0, RDClothing.partCount() - 1 do
        -- getHole (ItemVisual:508) null-checks the holes array; FromIndex
        -- (:48) clamps, and i < MAX:index() keeps the byte index in bounds
        local hole = visual:getHole(BloodBodyPartType.FromIndex(i))
        if type(hole) == "number" and hole > 0 then
            out[#out + 1] = i
        end
    end
    return out
end

-- Mend down to targetCount holes. Returns ok, err, removed.
--
-- Removes from the HIGHEST body-part index downward. The order is arbitrary as far
-- as the player is concerned - a hole is a hole - but it has to be deterministic
-- so the test can assert an exact count, and descending keeps the loop safe
-- against any index shifting inside the visual.
function RDClothing.mendHoles(item, targetCount)
    if not item then return false, "no item", 0 end

    targetCount = tonumber(targetCount)
    if not targetCount then return false, "hole count must be a number", 0 end
    if targetCount < 0 then targetCount = 0 end

    -- same getVisual NPE path as holeParts above - guard stays
    if type(item.getVisual) ~= "function" then
        return false, "item has no visual", 0
    end
    local gotVisual, visual = pcall(item.getVisual, item)
    if not gotVisual or not visual then
        return false, "item has no visual", 0
    end

    local parts = RDClothing.holeParts(item)
    local current = #parts
    if current == 0 then
        return false, "no holes to mend", 0
    end
    if targetCount >= current then
        -- Refusal, not a silent no-op: callers surface this so an admin who typed
        -- a bigger number learns why nothing happened.
        return false, string.format(
            "holes are remove-only (currently %d, asked for %d)", current, targetCount), 0
    end

    local toRemove = current - targetCount
    local removed = 0
    for i = current, current - toRemove + 1, -1 do
        -- removeHole (ItemVisual:617) null-checks the array; indices come
        -- from holeParts so they are in bounds
        visual:removeHole(parts[i])
        removed = removed + 1
    end

    if removed > 0 then
        RDClothing.creditHoleCondition(item, removed)
    end

    return true, nil, removed
end

-- Give back the condition that the removed holes were costing, clamped to max.
-- Split out so Wardrobe can reuse it when it rebuilds an outfit's holes.
function RDClothing.creditHoleCondition(item, holesRemoved)
    if not item or not holesRemoved or holesRemoved <= 0 then return end

    -- getCondLossPerHole is Clothing's alone (Clothing:1074) - anything else
    -- that lands here bows out at the door instead of hiding behind a guard.
    -- The rest are field reads (getCondition:2502, getConditionMax:2233), and
    -- setCondition (:2506) clamps, null-checks its sound paths, and cannot hit
    -- onBreak from a credit - condition only ever goes UP here.
    if not item.getCondLossPerHole then return end

    local target = item:getCondition() + item:getCondLossPerHole() * holesRemoved
    local maxCond = item:getConditionMax()
    if target > maxCond then target = maxCond end

    item:setCondition(math.floor(target))
end

-- Push clothing FIELD state (the ItemVisual side) to other clients. Server-gated
-- inside the engine, so calling it clientside is a harmless no-op. Call this once
-- after a batch of writes, not per item.
--
-- Not needed after Clothing.fullyRestore(), which sends SyncClothing itself.
function RDClothing.sync(player)
    if not player then return false end
    if type(syncClothingFields) ~= "function" then return false end
    -- LuaManager:3720 server-gates; GameServer.syncClothingFields:2298
    -- null-checks each worn item and INetworkPacket.send:127 try/catches
    syncClothingFields(player)
    return true
end

return RDClothing

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
