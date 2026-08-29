-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMLootShared - the loot category vocabulary: one meaning for "category".
--
-- lootReduce's cat: rules name a CATEGORY, and that word must mean exactly
-- one thing in the picker that offers it (the Profiles panel, S6) and the
-- fill hook that enforces it (LMLoot, since S8) - or a rule can be typed that
-- never matches anything, silently, which is the failure the closed
-- vocabulary exists to prevent. The one meaning: the item SCRIPT's
-- DisplayCategory - a field return on the script object (Item.java:528,
-- `return this.displayCategory`), the raw script token and never the
-- translated label the inventory paints over it, because translations vary
-- by client and stored rules must not.
--
-- The vocabulary is DERIVED from the live post-mod script registry, never
-- written down here: modded categories are offered automatically and a typo
-- cannot invent one. Enumerated once and cached as plain strings, the
-- DFItemQuery idiom (same registry, same reasoning - the script set is fixed
-- at boot); an unbuilt registry returns empty and the next call retries.

require "LMCore"

LMLootShared = LMLootShared or {}

local cats, catSet = nil, nil

function LMLootShared.categories()
    if cats then return cats end
    if not (ScriptManager and ScriptManager.instance) then return {} end
    local items = ScriptManager.instance:getAllItems()
    if not items or items:size() == 0 then return {} end
    local seen, out = {}, {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local c = it and it.getDisplayCategory and it:getDisplayCategory() or nil
        if c and c ~= "" and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    if #out == 0 then return {} end      -- nothing usable; retry next call
    table.sort(out)
    cats, catSet = out, seen
    return cats
end

-- Membership, for validating a typed rule against the same set the picker
-- offers. An unbuilt registry answers false - default deny, and the picker
-- path never produces the case.
function LMLootShared.isCategory(name)
    LMLootShared.categories()
    return catSet ~= nil and catSet[name] == true
end

return LMLootShared

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
