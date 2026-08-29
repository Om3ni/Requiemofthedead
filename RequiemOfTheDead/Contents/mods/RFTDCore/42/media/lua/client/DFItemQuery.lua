-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFItemQuery - type-ahead item lookup for any field that takes an item type.
--
-- Requested 2026-08-18: "begin typing and it populates a list of assets that
-- narrows as you complete", replacing exact-fullType-or-nothing entry.
--
-- IT LIVES IN CORE because it has two consumers (CLAUDE.md sect. 5): Dragonfly's
-- Add Item field, and the kit editor's item grant. It was written in Dragonfly
-- when only the first existed and moved here when the second arrived, rather
-- than copied - a satellite cannot require Dragonfly, so the alternatives were
-- a second copy of the ranker or an item field with no search, and the second
-- copy is what check-helpers exists to stop.
--
-- Nothing about it is Dragonfly-shaped: it enumerates a registry and ranks
-- strings, which is the "decides rather than draws" test RDItemKind and
-- RDSelect are already in Core for. The UI stays with whoever is drawing -
-- DFEntry hosts the shared one now (see its `suggest` option).
--
-- The registry is enumerated ONCE per session and cached as plain Lua strings:
-- ScriptManager.instance:getAllItems() returns the live post-mod script list
-- (the WSIndex/LJWeight idiom), and the script set is fixed at boot, so there
-- is nothing to invalidate. Per keystroke we scan the cache - a few thousand
-- plain string.find calls - never the Java list.
--
-- Engine surface, all verified: ScriptManager.getAllItems is safe-listed;
-- Item.getFullName is `return this.moduleDotType` (Item.java:907),
-- getDisplayName is trivial on script items, and getObsolete is a field
-- return (Item.java:3848). Obsolete scripts are excluded because AddItem
-- refuses them server-side (ItemContainer.java:514-516) - offering one would
-- manufacture a guaranteed "AddItem refused".

require "DFTypeAhead"

DFItemQuery = DFItemQuery or {}

-- Items are dot-namespaced ("Base.Axe"). Passed explicitly so the ranker
-- never has to guess which registry it is looking at.
local ITEM_SEPS = { "." }

local cache = nil   -- array of { full, disp, lfull, ldisp, lbare }

local function ensure()
    if cache then return cache end
    if not (ScriptManager and ScriptManager.instance) then return nil end
    local items = ScriptManager.instance:getAllItems()
    if not items or items:size() == 0 then return nil end

    local built = {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and not (it.getObsolete and it:getObsolete()) then
            local full = it:getFullName()
            local disp = (it.getDisplayName and it:getDisplayName()) or full
            -- The bare type is what admins remember ("Axe", not "Base.Axe");
            -- prefix matches against it rank highest. DFTypeAhead owns that
            -- rule and skips an unusable row itself.
            local e = DFTypeAhead.entry(full, disp, ITEM_SEPS)
            if e then built[#built + 1] = e end
        end
    end
    if #built == 0 then return nil end   -- nothing usable; retry next call
    cache = built
    return cache
end

-- Kept as a named surface because fixtures and the two UI consumers call it;
-- the ranking ITSELF moved to DFTypeAhead 2026-08-25 (it was never
-- item-shaped - see that file's header). This is the item source on top.
function DFItemQuery.rank(entries, query, limit)
    return DFTypeAhead.rank(entries, query, limit)
end

-- The live entry point. An empty result set for a non-empty query is a real
-- answer ("nothing matches"); an unbuilt cache just means scripts are not
-- loaded yet and the next keystroke retries.
function DFItemQuery.search(query, limit)
    local entries = ensure()
    if not entries then return {} end
    return DFItemQuery.rank(entries, query, limit)
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
-- ---------------------------------------------------------------------------
