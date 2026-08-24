-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMRegistry - what an authored id means to the engine (both sides).
--
-- A kit is text an admin typed: "Base.Axe", "base:Brave", "Woodwork". Three
-- different engine registries answer those, each with its own way of saying
-- "no such thing", and none of them the same as the others. This file is the
-- one place that crossing happens, so a kit is checked against the real world
-- exactly once and by one set of rules.
--
-- THREE CONSUMERS, WHICH IS WHY IT IS ITS OWN FILE: DMKits refuses a kit whose
-- ids do not resolve when it is SAVED, DMGrant resolves them again when a kit
-- is CLAIMED, and the authoring form lists what is available to pick from. If
-- the save-time check and the claim-time lookup ever disagreed, a kit would
-- pass authoring and hand over nothing.
--
-- WHY SAVE TIME AND NOT CLAIM TIME. Every one of these registries answers an
-- unknown id with a quiet nil rather than an error - AddItem included
-- (ItemContainer.java:511-520). A kit with a typo therefore does not fail; it
-- succeeds and hands over less than it said. The person who finds out is a
-- player who just spent a quest chain, and the person who has to work out why
-- is reading a log a week later. Refusing at save puts the failure in front of
-- the one person who can fix it, while they are looking at the field.
--
-- ---------------------------------------------------------------------------
-- THE LANDMINES, all four verified against 42.20.3
--
-- 1. A TRAIT'S NAME IS NOT ITS ID. CharacterTrait.getName() returns
--    getLocation(this).getPath() - the namespace is STRIPPED
--    (CharacterTrait.java:117-119). toString() returns the full location
--    (:121-123) and is the only unique handle. Two mods may both ship "Delver";
--    keyed by getName() one silently shadows the other, which is precisely what
--    CLAUDE.md sect. 6 exists for. Everything here keys on tostring().
--
-- 2. THE TRAIT LIST IS A JAVA COLLECTION. CharacterTraitDefinition.getTraits()
--    hands back a List, and Kahlua cannot iterate a Java collection at all
--    (CLAUDE.md sect. 3) - pairs() over it throws on a live server while
--    passing every fixture, because run-tests is real Lua 5.1. It is walked by
--    size()/get(i), zero-based, which is what vanilla itself does
--    (ISPlayerStatsChooseTraitUI.lua:24-25).
--
-- 3. THE CACHE IS BUILT LAZILY, NOT AT FILE SCOPE. Item and trait scripts load
--    during boot; a map built while this file is being read would be empty and
--    would stay empty, refusing every id forever. Building on first use puts it
--    safely after boot, and forget() exists so a fixture - or a script reload -
--    can make it rebuild.
--
-- 4. AN UNKNOWN PERK IS NOT nil. Perks.FromString returns the Perks.MAX
--    sentinel, which is a live object and therefore truthy. The engine's own
--    /addxp tests for it explicitly (AddXPCommand.java:46-47) and so does this
--    file; a plain nil check here would accept every misspelled perk on the
--    server.

require "DMKitDefs"

DMRegistry = DMRegistry or {}

local traitById   -- id (tostring form) -> CharacterTrait
local traitList   -- { { id, label }, ... }, sorted by label
local traitTex    -- id -> Texture, for surfaces that draw one

-- ---------------------------------------------------------------------------
-- Traits
-- ---------------------------------------------------------------------------

local function buildTraits()
    traitById, traitList, traitTex = {}, {}, {}

    local defs = CharacterTraitDefinition.getTraits()
    if not defs then return end

    -- size()/get(i), zero-based. See landmine 2 - this loop is not a style
    -- choice and must not become ipairs().
    for i = 0, defs:size() - 1 do
        local d = defs:get(i)
        if d then
            local trait = d:getType()
            if trait then
                -- tostring, never getName. See landmine 1.
                local id = tostring(trait)
                traitById[id] = trait
                traitList[#traitList + 1] = { id = id, label = d:getLabel() or id }
                -- Cached from the DEFINITION, which is the only thing holding
                -- it: CharacterTraitDefinition builds the texture in its
                -- constructor from media/ui/Traits/trait_<name>.png and falls
                -- back to trait_generic.png itself, so this is never nil for a
                -- registered trait and never needs a fallback of ours
                -- (CharacterTraitDefinition.java:43-46, :91-93).
                traitTex[id] = d.getTexture and d:getTexture() or nil
            end
        end
    end

    table.sort(traitList, function(a, b)
        if a.label == b.label then return a.id < b.id end
        return a.label < b.label
    end)
end

local function traits()
    if not traitById then buildTraits() end
    return traitById
end

-- Returns the CharacterTrait, or (nil, reason). The reason is shown to an
-- admin, so it says what was looked for and hints at the namespace rule - a
-- DM who typed "Brave" instead of "base:Brave" needs to be told that, not told
-- "not found".
function DMRegistry.trait(id)
    if type(id) ~= "string" or id == "" then
        return nil, "a trait id must be a non-empty string"
    end
    local t = traits()[id]
    if t then return t end
    if not id:find(":", 1, true) then
        return nil, "no trait '" .. id .. "' - trait ids carry their namespace, "
            .. "so it is probably 'base:" .. id .. "' or '<YourMod>:" .. id .. "'"
    end
    return nil, "no trait '" .. id .. "' is registered"
end

-- Every registered trait as { id, label }, sorted for display. The authoring
-- form's picker is the consumer; it must offer ids, never names, or two mods
-- shipping the same trait name become indistinguishable in the list.
function DMRegistry.traits()
    if not traitById then buildTraits() end
    local out = {}
    for i = 1, #traitList do
        out[i] = { id = traitList[i].id, label = traitList[i].label }
    end
    return out
end

-- The trait's icon, for a surface that draws one. Nil on a headless server is
-- fine and expected; nothing server-side asks.
function DMRegistry.traitTexture(id)
    if not traitById then buildTraits() end
    return traitTex and traitTex[id] or nil
end

-- ---------------------------------------------------------------------------
-- Perks
-- ---------------------------------------------------------------------------

-- Returns the Perk, or (nil, reason). Not cached: Perks.FromString is already
-- a lookup, and caching a sentinel would be worse than not caching at all.
function DMRegistry.perk(name)
    if type(name) ~= "string" or name == "" then
        return nil, "a perk name must be a non-empty string"
    end
    local p = Perks.FromString(name)
    -- See landmine 4: the miss is a sentinel object, not nil.
    if not p or p == Perks.MAX then
        return nil, "no skill called '" .. name .. "'"
    end
    return p
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

-- Returns the item script, or (nil, reason). getItem answers an unknown type
-- with nil, which is the same silence AddItem gives at claim time - checking
-- here is what turns that silence into a sentence.
function DMRegistry.item(fullType)
    if type(fullType) ~= "string" or fullType == "" then
        return nil, "an item type must be a non-empty string"
    end
    local sm = getScriptManager()
    if not sm then
        return nil, "the script manager is not available yet"
    end
    local script = sm:getItem(fullType)
    if not script then
        if not fullType:find(".", 1, true) then
            return nil, "no item '" .. fullType .. "' - item types carry their "
                .. "module, so it is probably 'Base." .. fullType .. "'"
        end
        return nil, "no item '" .. fullType .. "' exists"
    end
    return script
end

-- ---------------------------------------------------------------------------
-- One kit, checked against the world
--
-- Walks every grant a kit could ever hand over - roulette branches included,
-- because a branch that can win must be as real as one that always does - and
-- returns (true) or (nil, reason). The reason carries the grant's position, so
-- it reads the same way DMKitDefs' refusals do.
-- ---------------------------------------------------------------------------

local function checkGrant(g, where)
    if g.kind == DMKitDefs.ITEM then
        local _, why = DMRegistry.item(g.type)
        if why then return nil, where .. ": " .. why end

    elseif g.kind == DMKitDefs.TRAIT then
        local _, why = DMRegistry.trait(g.id)
        if why then return nil, where .. ": " .. why end

    elseif g.kind == DMKitDefs.XP then
        local _, why = DMRegistry.perk(g.perk)
        if why then return nil, where .. ": " .. why end

    elseif g.kind == DMKitDefs.FLAG or g.kind == DMKitDefs.COUNTER then
        -- Var definitions live in RDVars, which is server-only, so the check
        -- belongs to whoever is holding a store rather than here. DMKits does
        -- it in define(), against the same grant list.
        return true

    elseif g.kind == DMKitDefs.ROULETTE then
        for i = 1, #g.from do
            for j = 1, #g.from[i].grants do
                local ok, why = checkGrant(g.from[i].grants[j],
                    where .. " branch " .. i .. " grant " .. j)
                if not ok then return nil, why end
            end
        end
    end
    return true
end

function DMRegistry.checkGrants(grants)
    if type(grants) ~= "table" then
        return nil, "grants must be a list"
    end
    for i = 1, #grants do
        local ok, why = checkGrant(grants[i], "grant " .. i)
        if not ok then return nil, why end
    end
    return true
end

-- ---------------------------------------------------------------------------

-- Drop the caches so the next lookup rebuilds. For fixtures, and for the case
-- where scripts are reloaded under a running game.
function DMRegistry.forget()
    traitById, traitList = nil, nil
end

return DMRegistry

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
