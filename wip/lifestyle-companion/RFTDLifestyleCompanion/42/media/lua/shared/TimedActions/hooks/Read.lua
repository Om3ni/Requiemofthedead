-- ============================================================================
-- CREDIT: this file patches "Lifestyle: Hobbies" by [Angry]
--   https://steamcommunity.com/sharedfiles/filedetails/?id=3403870858
-- The patch code here is Requiem of the Dead's own work; the mod it patches is
-- theirs. All original Lifestyle content, code and design belong to its author.
-- ============================================================================

-- Read.lua  (RFTDLifestyleCompanion SHADOW of Lifestyle: Hobbies' Read hook)
-- ============================================================================
-- Shadows mods/Lifestyle/.../shared/TimedActions/hooks/Read.lua. Because the
-- Companion loads after Lifestyle, THIS file runs instead of the upstream one,
-- so `og_getDuration` below captures the true VANILLA ISReadABook.getDuration
-- (nothing else has overridden it at this point) - exactly as upstream intended.
--
-- ONLY CHANGE vs upstream: the NeuralHat scope bug is fixed. Upstream declared
-- `invData` as a local INSIDE the `if state == 1` block, then dereferenced it a
-- line later at file scope, where it resolved to a nil GLOBAL and threw
-- `attempt to index nil (global 'invData')` for every active hat state (1/3/4/5)
-- on any book with baseDuration >= 100 - i.e. reading any real book while
-- wearing an active NeuralHat failed to start. `invData` is now hoisted so it is
-- in scope for all states, with nil-safe guards on efficiencyMult and the dunce
-- moodle table. Neural / dunce behaviour is otherwise identical to upstream.
--
-- Ported from LifestyleHobbies modversion 0.4.0.
-- ============================================================================
require "TimedActions/ISReadABook"

local neuralBonus = {
    [1] = 0.9,
    [3] = 0.7,
    [4] = 0.5,
    [5] = 0.3,
}

local og_getDuration = ISReadABook.getDuration;
function ISReadABook:getDuration()
    local baseDuration = og_getDuration(self)
    if baseDuration < 100 then return baseDuration; end
    local time = baseDuration
    local headgear = self.character:getWornItems():getItem(ItemBodyLocation.HAT)
    if headgear and headgear:getType() == "NeuralHat" then -- neural hat
        local state = headgear:getVisual():getTextureChoice() or 0 -- 0 off 1 on 2 bad 3 overdrive 4 overdrive lvl2 5 overdrive lvl3
        if state == 2 then
            time = time*4
        elseif state ~= 0 then
            local readBonus = 1
            local data = headgear:getModData()                    -- FIX: hoisted out of the `if state == 1` block
            local invData = data and data['invData']              --      so it is in scope for the mult below
            if state == 1 and invData and invData['fastRead'] then readBonus = 0.5; end
            local nb = neuralBonus[state]
            if nb then
                local effMult = invData and invData['efficiencyMult'] and invData['efficiencyMult'][2]
                local mult
                if effMult and effMult ~= 0 then
                    mult = math.max(0.1, math.min(1, nb/effMult)) -- upstream formula, now nil-safe
                else
                    mult = math.max(0.1, math.min(1, nb))         -- FIX: safe fallback when hat data is absent
                end
                time = (time*readBonus)*mult
            end
        end
    else -- dunce effect
        local charData = self.character:getModData()
        local moodleLvl = charData.LSMoodles and charData.LSMoodles["Dunce"] and charData.LSMoodles["Dunce"].Level -- FIX: nil-guard LSMoodles
        if moodleLvl and moodleLvl > 0 then
            time = time+(time*moodleLvl)
        end
    end
    return math.max(time, 1)
end
