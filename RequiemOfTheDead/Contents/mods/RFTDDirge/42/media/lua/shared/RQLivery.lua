-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQLivery - what each Dirge special wears, declared once for both sides.
--
-- A livery is a uniform that says what something is. Every special converts
-- into one of these persistent outfits, and the outfit IS the tell: the
-- glowing core in the chest replaces the outline colour the type used to be
-- painted with. Hard-assigned, no sandbox option - the look is the identity,
-- and clothing defence rides on the items, so an operator swapping outfits
-- would silently strip the armour while the tooltips still promised a tank.
--
-- This file is pure declaration. RQSvLivery dresses zombies with it on the
-- server; RQTailor keeps a client's local copy in step. It is `shared/`
-- because the bald rule at the bottom must be derived identically on every
-- side that dresses a zombie, and because the client's command handler
-- validates an outfit name against the same prefix the server writes.
--
-- THE BOSS BORROWS A BODY. It has no mesh of its own, so it wears one of the
-- other four bodies chosen at random when it converts, with that body's core
-- lit gold. Gold is the Boss's tell whichever body it drew. The four are
-- separate outfits over the Boss's own twin items (owner decision 2026-09-17,
-- see RQ_Boss.txt), and the roll is the caller's: this file is pure
-- declaration and never touches a random source.

RQLivery = RQLivery or {}

-- Every Dirge outfit name starts with this. Keyed on the OUTFIT rather than
-- on a registry lookup because the outfit is the one fact every liveried
-- creature carries on every side, including a client that missed the
-- zombieConverted broadcast.
RQLivery.PREFIX = "RQ_"

-- Type -> persistent outfit name, as registered in media/clothing/clothing.xml.
-- The Scavenger's entry is its PASSIVE state; it is meant to be
-- indistinguishable from the Glutton until it is hit.
RQLivery.OUTFIT = {
    Juggernaut = "RQ_Juggernaut",
    Glutton    = "RQ_Glutton",
    Scavenger  = "RQ_Scavenger",
    Screamer   = "RQ_Screamer",
    EMP        = "RQ_EMP",
}

-- The Scavenger's second state: same biped, crimson core. Applied by
-- RQSvLivery.svEnrage from the rage flip in RQSvScavenger.onPlayerHit.
RQLivery.ENRAGED_SCAVENGER = "RQ_ScavengerEnraged"

-- The Boss's four bodies, in the order the roll indexes them.
RQLivery.BOSS_OUTFITS = {
    "RQ_BossJuggernaut",
    "RQ_BossDevourer",
    "RQ_BossScreamer",
    "RQ_BossEMP",
}

-- The outfit a type converts into. `roll` is a non-negative integer the
-- caller drew (ZombRand on the server); only the Boss reads it, and any value
-- lands inside the set, so a bad roll can never produce a naked Boss.
function RQLivery.outfitFor(zType, roll)
    if zType == nil then return nil end
    if zType == "Boss" then
        local n = #RQLivery.BOSS_OUTFITS
        local r = tonumber(roll) or 0
        if r ~= math.floor(r) or r < 0 then r = 0 end
        return RQLivery.BOSS_OUTFITS[(r % n) + 1]
    end
    return RQLivery.OUTFIT[zType]
end

-- Is this outfit name one of ours? nil-safe: a zombie whose outfit has not
-- resolved yet answers nil from getOutfitName (IsoZombie.java:4844-4852),
-- and that is "no".
function RQLivery.wears(outfitName)
    if type(outfitName) ~= "string" then return false end
    return string.sub(outfitName, 1, #RQLivery.PREFIX) == RQLivery.PREFIX
end

-- ---------------------------------------------------------------------------
-- The bald rule
-- ---------------------------------------------------------------------------
-- The bipeds carry their own heads, so any hair at all is geometry pushed
-- through a face. Hair is chosen BY OUTFIT NAME when an outfit is randomized
-- (Outfit.java:71-74 -> HairStyles -> HairOutfitDefinitions.
-- getRandomMaleHaircut), and a weighted entry of "null" resolves to the empty
-- haircut (HairOutfitDefinitions.java:181-183), so "null:100" is always bald.
-- Vanilla spells its own beard rules exactly this way.
--
-- The engine reads this table straight out of the Lua environment
-- (HairOutfitDefinitions.java:39, then :56-68 for the per-outfit list), so
-- nothing calls anything. Vanilla RESETS the list when its own definitions
-- file loads (HairOutfitDefinitions.lua:39, `= {}`), which is safe only
-- because game files load before every mod file in the same tier
-- (LuaManager.java:1196-1197: mod files are appended after the sorted game
-- list) - this file's inserts land on the table vanilla just built.
--
-- It replicates for free: every client derives hair from the same persistent
-- outfit id through the same seeded RNG. There is no hair field on the wire.
HairOutfitDefinitions = HairOutfitDefinitions or {}
HairOutfitDefinitions.haircutOutfitDefinition =
    HairOutfitDefinitions.haircutOutfitDefinition or {}

local function declareBald(outfitName)
    -- The generic field, not maleHaircut/femaleHaircut: the gendered fields
    -- take precedence when present, and the generic one already answers for
    -- both (HairOutfitDefinitions.java:165-196).
    table.insert(HairOutfitDefinitions.haircutOutfitDefinition, {
        outfit  = outfitName,
        haircut = "null:100",
        beard   = "null:100",
    })
end

for _, outfitName in pairs(RQLivery.OUTFIT) do
    declareBald(outfitName)
end
declareBald(RQLivery.ENRAGED_SCAVENGER)
for i = 1, #RQLivery.BOSS_OUTFITS do
    declareBald(RQLivery.BOSS_OUTFITS[i])
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
