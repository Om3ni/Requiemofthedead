-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRDangerQuips.lua  (client)
--
-- Over-head "thought bubble" lines for the temperature danger indicator, and a
-- shuffle-bag picker so each line feels fresh (every line in a pool is shown
-- once before any repeats, and a freshly-refilled bag never re-shows the line
-- that was just spoken).
--
-- Pools are keyed by "<signal>_<tier>": signal = cold|hot, tier = onset (the
-- moodle first appears), worsening (it climbs), critical (it's hurting you /
-- act now). The controller (LRDanger) maps a moodle level to a tier and asks
-- for a line on each escalation.
--
-- Lines are first-person interior monologue. Kept inline (not translation keys)
-- because tuning ~150 short lines as a flat Lua table is far more maintainable
-- than the equivalent JSON; can be wrapped for localization later.

LRDangerQuips = LRDangerQuips or {}

local POOLS = {
    cold_onset = {
        "It's starting to feel cold.",
        "Brrr. The temperature's falling.",
        "There's a chill creeping in.",
        "Getting nippy out here.",
        "I should keep an eye on the cold.",
        "Bit of a bite to the air now.",
        "My fingers are starting to stiffen.",
        "Cold's setting in.",
        "I can see my breath.",
        "A shiver just ran through me.",
        "Feels like the warmth is draining out of me.",
        "The cold's finding its way in.",
        "Starting to feel that frost in my bones.",
        "Better not let this chill get worse.",
        "Goosebumps. The cold's here.",
        "That wind cuts right through.",
        "I'm losing heat.",
        "Need to mind the cold before it bites.",
        "A little colder than I'd like.",
        "The air's gone sharp and cold.",
        "My toes are going numb already.",
        "Cold enough to notice now.",
        "Should think about warming up soon.",
        "There's a frost settling over everything.",
    },
    cold_worsening = {
        "This is miserable. So cold.",
        "I can't stop shivering.",
        "My teeth are chattering.",
        "The cold's gone right to my core.",
        "I'm freezing. Really freezing.",
        "Everything aches from the cold.",
        "Can barely feel my hands.",
        "This cold is sinking its teeth in.",
        "I need to get warm. Soon.",
        "My whole body's trembling.",
        "It's so cold it hurts.",
        "I'm chilled to the bone.",
        "Hard to think straight, I'm so cold.",
        "The shivering won't stop.",
        "My lips are going numb.",
        "I can't get warm no matter what.",
        "This is dangerous cold.",
        "Every breath is ice.",
        "My muscles are seizing up.",
        "I'm shaking too hard to hold still.",
        "The cold's wearing me down.",
        "Feels like I'll never be warm again.",
        "I have to do something about this cold.",
        "My fingers won't work properly anymore.",
    },
    cold_critical = {
        "I need to get inside. Now.",
        "Find a fire. Anything. Warmth.",
        "I need a jacket, something, anything warm.",
        "If I don't warm up I'm going to die out here.",
        "Get out of the cold before it kills me.",
        "I can't survive much more of this.",
        "Light a fire or I'm finished.",
        "Shelter. I need shelter immediately.",
        "My body's shutting down from the cold.",
        "This cold is going to be the end of me.",
        "I have to warm up or it's over.",
        "Get indoors, get dry, get warm. Move.",
        "I'm freezing to death.",
        "Layers. Fire. Heat. Right now.",
        "Everything's going numb. This is bad.",
        "I can barely move. I have to get warm.",
        "The cold is killing me, plain and simple.",
        "Find heat or this is where I fall.",
        "Strip the wet clothes, get warm, hurry.",
        "I won't last out here much longer.",
        "My heart feels slow. I need warmth now.",
        "Inside. Fire. Blankets. No time to waste.",
        "If I pass out in this cold I won't wake up.",
        "Warm up immediately or accept the end.",
    },
    hot_onset = {
        "It's starting to feel warm.",
        "Ugh. Sweat.",
        "Getting hot out here.",
        "I'm starting to overheat.",
        "The heat's creeping up on me.",
        "Bit too warm for comfort.",
        "I can feel myself sweating.",
        "This heat is building.",
        "Starting to feel flushed.",
        "Too warm. I should watch this.",
        "The sun's really beating down.",
        "I'm getting clammy.",
        "Heat's settling over me.",
        "My shirt's already sticking to me.",
        "Feeling the warmth a little too much.",
        "Getting toasty.",
        "The air's gone thick and hot.",
        "Sweat's beading on my forehead.",
        "I should keep an eye on this heat.",
        "Starting to feel the burn of it.",
        "Warmer than I'd like.",
        "I'm running hot.",
        "Could do with some shade soon.",
        "The heat's making itself known.",
    },
    hot_worsening = {
        "This is miserable. So hot.",
        "I'm drenched in sweat.",
        "I'm boiling alive out here.",
        "The heat's unbearable.",
        "I can't stop sweating.",
        "My head's pounding from the heat.",
        "Everything's a blur of heat.",
        "I'm baking.",
        "Feel like I'm cooking from the inside.",
        "So hot I can barely think.",
        "The heat's wearing me down.",
        "My skin feels like it's burning.",
        "I'm parched and overheating.",
        "This heat is dangerous.",
        "I need to cool down. Badly.",
        "My heart's racing from the heat.",
        "Dizzy. The heat's getting to me.",
        "I'm dripping. Completely soaked.",
        "Can't catch my breath in this heat.",
        "The sun is relentless.",
        "I feel sick from the heat.",
        "Too hot. Far too hot.",
        "My whole body's flushed and aching.",
        "The heat's smothering me.",
    },
    hot_critical = {
        "I need to find shade. Now.",
        "Get inside, out of this heat.",
        "Lose the jacket, lose the layers, cool down.",
        "If I don't cool off I'm going to drop.",
        "Water. Shade. Now. Or I'm done.",
        "I'm going to collapse from this heat.",
        "Get out of the sun before it kills me.",
        "My body's overheating to the point of failure.",
        "This heat is going to be the end of me.",
        "I have to cool down or it's over.",
        "Strip down, find water, get out of the sun.",
        "Heatstroke. I can feel it coming.",
        "I'm cooking alive. I need shade immediately.",
        "Everything's spinning. I need to cool off.",
        "Get somewhere cool or I won't make it.",
        "I'm burning up from the inside out.",
        "If I stay in this heat I'll die.",
        "Find cold water and get out of the sun. Move.",
        "My body can't take much more of this heat.",
        "Shade, water, rest. Right now.",
        "I'm one step from passing out in this heat.",
        "Cool down immediately or accept the end.",
        "The heat is killing me, plain and simple.",
        "Drop everything and get out of this sun.",
    },
}

-- Per-pool shuffle-bag state: a working copy of indices we draw from, plus the
-- last line spoken so a refill can't immediately repeat it.
local bags = {}      -- poolKey -> { remaining indices }
local lastLine = {}  -- poolKey -> last returned string

local function refill(poolKey, pool)
    local bag = {}
    for i = 1, #pool do bag[i] = i end
    bags[poolKey] = bag
end

-- pick(poolKey): returns a fresh line from the pool, or nil if the pool is
-- empty/unknown. Draws without replacement; refills when empty, avoiding an
-- immediate repeat of the just-spoken line across the refill boundary.
function LRDangerQuips.pick(poolKey)
    local pool = POOLS[poolKey]
    if not pool or #pool == 0 then return nil end

    local bag = bags[poolKey]
    if not bag or #bag == 0 then
        refill(poolKey, pool)
        bag = bags[poolKey]
    end

    -- Draw a random index out of the bag (swap-remove for O(1)).
    local pos = ZombRand(#bag) + 1
    local idx = bag[pos]
    bag[pos] = bag[#bag]
    bag[#bag] = nil

    local line = pool[idx]
    -- Single-pass guard against the refill-boundary repeat: if we just drew the
    -- same line we last spoke and there's still another option in the bag, take
    -- a different one and put this index back.
    if line == lastLine[poolKey] and #bag > 0 then
        local pos2 = ZombRand(#bag) + 1
        local idx2 = bag[pos2]
        bag[pos2] = idx
        idx = idx2
        line = pool[idx]
    end

    lastLine[poolKey] = line
    return line
end

-- Exposed for tests / inspection.
LRDangerQuips.pools = POOLS

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
