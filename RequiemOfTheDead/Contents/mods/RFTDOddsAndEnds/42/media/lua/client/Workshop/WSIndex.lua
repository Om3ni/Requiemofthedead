-- SPDX-License-Identifier: GPL-3.0-or-later
-- WSIndex - the crafting knowledge index behind the Workshop tab
-- (client). Pure data, no UI: built once per session from whatever scripts
-- are LOADED, so recipes and teaching literature from any mod are in the
-- moment they load - the same mod-agnostic construction the Workshop's part
-- filter was built on, and the same covenant (nothing here reads any
-- third-party mod's files).
--
-- WHAT IT ANSWERS, per recipe:
--   * what it makes (output full types + display names) - and the reverse:
--     which recipes make a given item (byOutput)
--   * whether it must be learned, and every path to learning it: teaching
--     literature (Item.getLearnedRecipes - the exact walk the engine's own
--     VerifyAllCraftRecipesAreLearnable debug pass does, inverted), auto-learn
--     skill thresholds, research, and profession/trait spawn grants
--   * the skills required to CRAFT it even once known
--
-- Everything is read off public script-object methods verified against the
-- 42.20 decompile; every walk is pcall-armored per entry so one malformed
-- modded script costs its own entry, never the index.
--
-- KNOWN-NESS IS NEVER CACHED. WSIndex.known(player, rec) asks the
-- live character (the engine's own rule: !needToBeLearn or knownRecipes
-- contains it - IsoGameCharacter.isRecipeActuallyKnown), because reading a
-- magazine mid-session must flip the Journal row white on the next repaint.

if isServer() and not isClient() then return end

WSIndex = WSIndex or {}
local X = WSIndex

-- name -> { r, name, disp, cat, needLearn, outputs = {fullType...},
--           outputDisp = {str...}, autoAny = {str...}, autoAll = {str...},
--           research = level|nil, reqSkills = {str...},
--           taughtBy = { {disp, type} ... }, grantedBy = {str...} }
X.recipes  = nil
X.byOutput = nil   -- fullType -> { recipeName, ... }
X.cats     = nil   -- sorted category names

local function jlist(t)
    local out = {}
    if t then
        for i = 0, t:size() - 1 do out[#out + 1] = tostring(t:get(i)) end
    end
    return out
end

local function indexRecipe(r)
    local rec = {
        r         = r,
        name      = r:getName(),
        disp      = r:getTranslationName() or r:getName(),
        cat       = r:getCategory() or "Miscellaneous",
        needLearn = r:needToBeLearn() == true,
        outputs   = {},
        outputDisp = {},
        taughtBy  = {},
        grantedBy = {},
    }
    local outs = r:getOutputs()
    for j = 0, outs:size() - 1 do
        local res = outs:get(j):getPossibleResultItems()
        if res then
            for k = 0, res:size() - 1 do
                local it = res:get(k)
                local fn = it and it:getFullName()
                if fn then
                    rec.outputs[#rec.outputs + 1] = fn
                    rec.outputDisp[#rec.outputDisp + 1] = it:getDisplayName() or fn
                end
            end
        end
    end
    rec.autoAny = jlist(r:getAutoLearnAnySkills())
    rec.autoAll = jlist(r:getAutoLearnAllSkills())
    rec.reqSkills = jlist(r:getRequiredSkills())
    if r:canBeResearched() then rec.research = r:getResearchSkillLevel() or 0 end
    return rec
end

function X.build()
    if X.recipes then return end
    X.recipes, X.byOutput = {}, {}
    local catSet = {}

    -- 1) every loaded craft recipe. This walk and the three below stay under
    -- pcall (see header): script-object accessors vary in nullability across
    -- mods, and one malformed modded script must cost its own entry - or its
    -- own walk - never the index.
    pcall(function()
        local all = ScriptManager.instance:getAllCraftRecipes()
        for i = 0, all:size() - 1 do
            local ok, rec = pcall(indexRecipe, all:get(i))
            if ok and rec and rec.name then
                X.recipes[rec.name] = rec
                catSet[rec.cat] = true
                for _, fn in ipairs(rec.outputs) do
                    local list = X.byOutput[fn]
                    if not list then list = {}; X.byOutput[fn] = list end
                    list[#list + 1] = rec.name
                end
            end
        end
    end)

    -- 2) teaching literature, inverted: which items' LearnedRecipes name each
    -- recipe. `type` is the BARE type (containsTypeRecurse's currency) for
    -- carried checks; disp for display.
    pcall(function()
        local items = ScriptManager.instance:getAllItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local taught = it and it:getLearnedRecipes()
            if taught and taught.size and taught:size() > 0 then
                local entry = { disp = it:getDisplayName() or it:getName(), type = it:getName() }
                for j = 0, taught:size() - 1 do
                    local rec = X.recipes[tostring(taught:get(j))]
                    if rec then rec.taughtBy[#rec.taughtBy + 1] = entry end
                end
            end
        end
    end)

    -- 3) spawn grants. Professions always resolve; trait definitions may not
    -- exist yet on this side (the dedi/creation gap MMShared documents) -
    -- degrade to "professions only" rather than fail the build.
    pcall(function()
        local profs = CharacterProfessionDefinition.getProfessions()
        for i = 0, profs:size() - 1 do
            local def = profs:get(i)
            local granted = def:getGrantedRecipes()
            if granted then
                local nm = def:getUIName() or tostring(def)
                for j = 0, granted:size() - 1 do
                    local rec = X.recipes[tostring(granted:get(j))]
                    if rec then rec.grantedBy[#rec.grantedBy + 1] = nm .. " (profession)" end
                end
            end
        end
    end)
    pcall(function()
        local defs = CharacterTraitDefinition.getTraits()
        for i = 0, defs:size() - 1 do
            local def = defs:get(i)
            local granted = def:getGrantedRecipes()
            if granted and granted:size() > 0 then
                local nm = def:getLabel() or "a trait"
                for j = 0, granted:size() - 1 do
                    local rec = X.recipes[tostring(granted:get(j))]
                    if rec then rec.grantedBy[#rec.grantedBy + 1] = nm .. " (trait)" end
                end
            end
        end
    end)

    X.cats = {}
    for c in pairs(catSet) do X.cats[#X.cats + 1] = c end
    table.sort(X.cats)
end

-- All indexed recipes making this item type, as rec tables.
function X.forOutput(fullType)
    X.build()
    local out = {}
    for _, name in ipairs(X.byOutput[fullType] or {}) do
        out[#out + 1] = X.recipes[name]
    end
    return out
end

-- The engine's own known rule (IsoGameCharacter.isRecipeActuallyKnown):
-- a recipe that never needs learning is known by everyone.
function X.known(player, rec)
    if not rec.needLearn then return true end
    return player ~= nil and player:isRecipeActuallyKnown(rec.name) == true
end

-- Sorted array of every rec, for the Journal's catalogue walk.
function X.all()
    X.build()
    local out = {}
    for _, rec in pairs(X.recipes) do out[#out + 1] = rec end
    table.sort(out, function(a, b)
        if a.cat ~= b.cat then return a.cat < b.cat end
        return tostring(a.disp) < tostring(b.disp)
    end)
    return out
end

-- "PerkName N" (the format every skill-list accessor emits) -> a line with
-- the player's current level appended when the perk resolves. Display aid
-- only; an unresolvable modded perk name degrades to the bare string.
function X.skillLine(player, s)
    local pname, lvl = tostring(s):match("^(.-)%s+(%d+)$")
    if not pname then return tostring(s), nil end
    local cur
    local pt = Perks.FromString(pname)
    if pt and player then cur = player:getPerkLevel(pt) end
    if cur == nil then return tostring(s), nil end
    return string.format("%s %s (you: %d)", pname, lvl, cur), cur >= tonumber(lvl)
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
