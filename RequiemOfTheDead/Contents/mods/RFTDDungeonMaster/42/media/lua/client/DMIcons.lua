-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMIcons - a contents row -> the picture and the words for it (client only).
--
-- Both kit surfaces draw the same rows: the player's claim tab and the admin
-- catalogue. One file decides what a row looks like so the two cannot describe
-- the same reward differently and leave somebody deciding which to believe -
-- the same argument that put grantLine in DMKitForm rather than in both tabs.
--
-- ---------------------------------------------------------------------------
-- WHERE THE PICTURES COME FROM, all verified against 42.20.3.
--
-- ITEM: getScriptManager():getItem(fullType):getNormalTexture(). A SCRIPT item,
-- with no instance in the world - which is our whole situation, since a kit
-- holds the string "Base.Axe" and nothing has been created yet. Vanilla does
-- exactly this at ISWidgetInput.lua:536. The texture is built at script-parse
-- time from the Icon= param and THE ENGINE ITSELF substitutes
-- media/inventory/Question_On.png when the icon file is missing
-- (Item.java:2031-2037), so a mistyped or half-installed item draws a question
-- mark rather than a nil index.
--
-- TRAIT: CharacterTraitDefinition:getTexture(), cached by DMRegistry when it
-- builds the trait list. Also engine-fallbacked - trait_generic.png
-- (CharacterTraitDefinition.java:43-46).
--
-- XP: NOTHING. There is no per-perk texture anywhere in the engine or in
-- vanilla's own UI; the skills panel is text rows. An XP row draws its words
-- only, and the surfaces reserve the icon column anyway so a mixed list still
-- lines up.
--
-- ---------------------------------------------------------------------------
-- CACHED BY REF, because these are read every frame a panel is open and
-- getItem is a registry lookup. The script set is fixed at boot, so there is
-- nothing to invalidate - the same reasoning DFItemQuery's cache carries.
--
-- A MISSING ITEM IS NOT AN ERROR HERE. The server refuses an unknown type at
-- save time, so a row reaching this file names something that existed then;
-- if it does not now, a mod was removed under a live kit and the honest answer
-- is to draw the id and let an admin see it, not to hide the row.

if isServer() then return end

require "DMKitDefs"
require "DMRegistry"

DMIcons = DMIcons or {}

local texCache  = {}   -- fullType -> Texture or false (looked up, absent)
local nameCache = {}   -- fullType -> display name

local function itemScript(fullType)
    if type(fullType) ~= "string" or fullType == "" then return nil end
    local sm = getScriptManager()
    return sm and sm:getItem(fullType) or nil
end

-- The texture for a contents row, or nil when the kind has none.
function DMIcons.texture(row)
    if type(row) ~= "table" then return nil end
    local ref = row.ref
    if row.kind == DMKitDefs.ITEM then
        if type(ref) ~= "string" then return nil end
        local hit = texCache[ref]
        if hit ~= nil then return hit or nil end
        local script = itemScript(ref)
        local tex = script and script.getNormalTexture and script:getNormalTexture()
        texCache[ref] = tex or false
        return tex
    elseif row.kind == DMKitDefs.TRAIT then
        return DMRegistry.traitTexture(ref)
    end
    return nil
end

-- The item's own display name, falling back to the type. Localised on the
-- CLIENT, which is why the wire carries types rather than names: the server's
-- language is not the reader's.
function DMIcons.itemName(fullType)
    if type(fullType) ~= "string" or fullType == "" then return "?" end
    local hit = nameCache[fullType]
    if hit then return hit end
    local script = itemScript(fullType)
    local name = script and script.getDisplayName and script:getDisplayName()
    name = (type(name) == "string" and name ~= "") and name or fullType
    nameCache[fullType] = name
    return name
end

-- The words for a contents row. Pure given the two lookups above, and the one
-- place either surface gets its wording from.
function DMIcons.label(row)
    if type(row) ~= "table" then return "?" end
    local kind = row.kind
    if kind == DMKitDefs.ITEM then
        local n = tonumber(row.count) or 1
        local name = DMIcons.itemName(row.ref)
        -- "x1" is noise on the overwhelmingly common single item; a count only
        -- earns its place when it is telling you something.
        if n > 1 then return name .. "  x" .. n end
        return name
    elseif kind == DMKitDefs.TRAIT then
        for _, t in ipairs(DMRegistry.traits() or {}) do
            if t.id == row.ref then return t.label end
        end
        -- The id, when the trait is no longer registered. See the header: an
        -- admin seeing "SomeMod:Delver" learns more than a blank row.
        return tostring(row.ref)
    elseif kind == DMKitDefs.XP then
        return tostring(row.ref) .. "  +" .. tostring(row.count or 0)
    end
    return tostring(kind)
end

-- One roulette's heading. `pick` is stated rather than folded into the odds,
-- because drawing 2 of 5 makes each branch likelier than its share of the
-- weight and that arithmetic must not hide inside a percentage.
function DMIcons.rouletteHeading(row)
    local n = #((row and row.branches) or {})
    local pick = tonumber(row and row.pick) or 1
    if pick > 1 then
        return "ONE DRAW OF " .. pick .. ", from " .. n .. ":"
    end
    return "ONE OF THESE " .. n .. ":"
end

-- A branch's odds, or "" when the surface was not given any. The player's
-- payload carries no percentages at all (owner, 2026-08-23), so this returns
-- empty for them without either surface needing to know which one it is.
function DMIcons.oddsText(branch)
    local p = branch and tonumber(branch.percent)
    if not p then return "" end
    -- Whole numbers stay whole: "25%" reads as a designed share, "25.0%" reads
    -- as a measurement of something.
    if p == math.floor(p) then return string.format("%d%%", p) end
    return string.format("%.1f%%", p)
end

return DMIcons

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
