-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMLoot - the `lootReduce` field made real: container fills, cut by zone (S8).
--
-- WHAT THIS ENFORCES. LMCore has registered `lootReduce` since S1 with a
-- NOT_YET note admitting nothing read it. This is the module named there. The
-- grammar, the parse and the editor all stay where they are (Limes.
-- parseLootReduce owns the string; the Profiles panel edits rows over it);
-- this file only READS the resolved value where containers fill and removes
-- the stated share of what the engine just rolled.
--
-- THE SEAM, read from the decompile rather than assumed:
--   * Fills are server-side, full stop - fillContainerInternal returns
--     immediately on a network client (ItemPickerJava.java:576-578), so
--     OnFillContainer only ever fires where this file runs.
--   * In MP the request path fills and THEN ships the result -
--     RequestItemsForContainerPacket.processServer fills the container and
--     sends AddInventoryItemToContainer from its post-fill item list
--     (RequestItemsForContainerPacket.java:42-54). A removal made inside the
--     event mutates the list before it is ever serialized: no wire work, no
--     ghost items, nothing for a client to reconcile.
--   * The event itself is (roomName, containerType, container)
--     (ItemPickerJava.java:645), with one trap: the "Zombie Bag" lane passes
--     an ItemPickerContainer DISTRIBUTION as the third argument
--     (ItemPickerJava.java:603, :1030), not an ItemContainer. The
--     `instanceof` gate below is that trap made harmless, not defensiveness.
--   * Removal is ItemContainer.Remove (ItemContainer.java:1940-1973): list
--     removal, dirty flags, dead-body clothing bookkeeping. The loop walks
--     backward because Remove compacts the live ArrayList under it.
--
-- WHAT A RULE MEANS - one vocabulary, stated once:
--   * An item rule names a fullType (InventoryItem.java:1515) and beats any
--     category rule covering the same item: naming the item IS the more
--     specific statement.
--   * A category rule names a DisplayCategory. InventoryItem.getDisplayCategory
--     (InventoryItem.java:2875) returns the same raw script token
--     LMLootShared derives the picker's closed vocabulary from
--     (Item.java:528), so a rule the Profiles panel offers matches here by
--     construction, and a rule it refuses matches nothing.
--   * The percent is the chance each matching item is removed, rolled per
--     item. Within one list the last rule for a name wins - the editor
--     dedupes, so a duplicate only arrives from a hand-edited ini.
--
-- POSITION comes from the container's source grid (ItemContainer.java:2511),
-- which fillContainerInternal guarantees non-nil for every world container it
-- fills (it bails without one, :582-585). The lanes that can arrive without
-- one - a bag INSIDE a corpse's inventory - are skipped: no ground, no zone,
-- and cutting a bag's contents by where its corpse happens to fall is not a
-- rule anyone wrote.
--
-- OBSERVABILITY (design doc §14): removal is invisible by nature - the player
-- only ever sees the container's final contents - so the module keeps per-zone
-- counters since boot and prints ONE line per zone per boot on its first cut
-- there. That answers "did it run and what did it decide" without a log that
-- grows with every cupboard. Unparseable rule fragments print once per
-- distinct string, then stay quiet.
--
-- DELETE THIS FILE and `lootReduce` goes back to being stored and inert, with
-- no other edit anywhere - the removable-file idiom LMDirge and LMZeds follow.

if not isServer() then return end

require "LMCore"

LMLoot = LMLoot or {}

-- Parsed plans, keyed by the exact rule string. parseLootReduce is pure, so a
-- key can never go stale - the wipe on store change only exists to keep the
-- table bounded by the strings the store CURRENTLY holds rather than every
-- string an editing session ever produced.
local plans = {}
Limes.onChanged(function() plans = {} end)

local removedByZone = {}    -- zone name -> items removed since boot
local removedTotal  = 0
local announced     = {}    -- zone name -> true once its first-cut line printed

local function planFor(text)
    local plan = plans[text]
    if plan then return plan end
    local entries, bad = Limes.parseLootReduce(text)
    plan = { items = {}, cats = {}, n = 0 }
    for i = 1, #entries do
        local e = entries[i]
        if e.kind == "category" then plan.cats[e.name] = e.pct
        else plan.items[e.name] = e.pct end
        plan.n = plan.n + 1
    end
    if #bad > 0 then
        -- Validate names these in the editor; this covers the hand-edited ini
        -- that never went through it. Once per distinct string, not per fill.
        print("[Limes] LMLoot: ignoring unparseable rule(s) '"
            .. table.concat(bad, "', '") .. "' in: " .. tostring(text))
    end
    plans[text] = plan
    return plan
end

local function onFillContainer(_, _, container)
    -- The distribution-not-container lane (see header); everything else that
    -- reaches this event is a real ItemContainer.
    if not container or not instanceof(container, "ItemContainer") then return end

    local sq = container:getSourceGrid()
    if not sq then return end
    local zone = Limes.getLocation(sq:getX(), sq:getY())
    if not zone or not zone.fields then return end
    local text = zone.fields.lootReduce
    if not text or text == "" then return end
    local plan = planFor(text)
    if plan.n == 0 then return end

    local items = container:getItems()
    local count = items:size()
    local removed = 0
    for i = count - 1, 0, -1 do
        local item = items:get(i)
        local pct = plan.items[item:getFullType()] or plan.cats[item:getDisplayCategory()]
        if pct and ZombRand(100) < pct then
            container:Remove(item)
            removed = removed + 1
        end
    end
    if removed == 0 then return end

    local name = zone.name
    removedByZone[name] = (removedByZone[name] or 0) + removed
    removedTotal = removedTotal + removed
    if not announced[name] then
        announced[name] = true
        print(string.format(
            "[Limes] LMLoot: first cut in '%s' this boot - removed %d of %d rolled items",
            tostring(name), removed, count))
    end
end

Events.OnFillContainer.Add(onFillContainer)

-- The counters, for whatever admin surface wants them later - the census
-- pattern's cheap half. A copy, so a reader cannot become a second writer.
function LMLoot.stats()
    local byZone = {}
    for name, n in pairs(removedByZone) do byZone[name] = n end
    return { total = removedTotal, byZone = byZone }
end

return LMLoot

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
