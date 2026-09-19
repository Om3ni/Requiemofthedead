-- RQLivery fixture - the declaration both sides dress from.
--
-- Pure data, no engine surface. What is at risk is the CONTRACT other files
-- read: five liveried types plus the Boss's four borrowed bodies, the Scavenger's passive outfit being
-- the Glutton's twin rather than the crimson one, the prefix the client's
-- command handler validates against, and the bald rule reaching every outfit
-- including the enraged one. A typo in any of these is invisible to every
-- other gate and renders as a naked or hairy zombie in front of players.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQLivery.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQLivery: " .. message) end
end

-- Vanilla's definitions file has already built the table when a mod's shared
-- file loads; model that, with one vanilla row in it that must survive.
HairOutfitDefinitions = { haircutOutfitDefinition = { { outfit = "Police", haircut = "random:100" } } }

RQLivery = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- The type table
-- ---------------------------------------------------------------------------
check(RQLivery.outfitFor("Juggernaut") == "RQ_Juggernaut", "Juggernaut wears RQ_Juggernaut")
check(RQLivery.outfitFor("Glutton") == "RQ_Glutton", "Glutton wears RQ_Glutton")
check(RQLivery.outfitFor("Scavenger") == "RQ_Scavenger",
    "a converting Scavenger wears its PASSIVE outfit, never the crimson one")
check(RQLivery.outfitFor("Screamer") == "RQ_Screamer", "Screamer wears RQ_Screamer")
check(RQLivery.outfitFor("EMP") == "RQ_EMP", "EMP wears RQ_EMP")
-- The Boss borrows a body: any roll lands inside its four outfits, in order.
check(RQLivery.outfitFor("Boss", 0) == "RQ_BossJuggernaut", "Boss roll 0 is the Juggernaut body")
check(RQLivery.outfitFor("Boss", 1) == "RQ_BossDevourer", "Boss roll 1 is the Devourer body")
check(RQLivery.outfitFor("Boss", 2) == "RQ_BossScreamer", "Boss roll 2 is the Screamer body")
check(RQLivery.outfitFor("Boss", 3) == "RQ_BossEMP", "Boss roll 3 is the EMP body")
check(RQLivery.outfitFor("Boss", 4) == "RQ_BossJuggernaut", "a roll past the set wraps rather than falling off it")
check(RQLivery.outfitFor("Boss") == "RQ_BossJuggernaut", "no roll at all still dresses the Boss - never naked")
check(RQLivery.outfitFor("Boss", -3) == "RQ_BossJuggernaut" and RQLivery.outfitFor("Boss", 1.5) == "RQ_BossJuggernaut",
    "a negative or fractional roll is treated as 0, not as an index")
check(RQLivery.outfitFor("Juggernaut", 3) == "RQ_Juggernaut", "the roll is ignored for every other type")
check(#RQLivery.BOSS_OUTFITS == 4, "four Boss bodies")
for i = 1, #RQLivery.BOSS_OUTFITS do
    check(RQLivery.wears(RQLivery.BOSS_OUTFITS[i]), RQLivery.BOSS_OUTFITS[i] .. " carries the prefix")
end
check(RQLivery.outfitFor(nil) == nil, "no type, no outfit")
check(RQLivery.ENRAGED_SCAVENGER == "RQ_ScavengerEnraged", "the rage outfit is named")
check(RQLivery.ENRAGED_SCAVENGER ~= RQLivery.outfitFor("Scavenger"),
    "the rage outfit is a different outfit from the passive one")

local count = 0
for _ in pairs(RQLivery.OUTFIT) do count = count + 1 end
check(count == 5, "exactly five types are liveried: " .. count)

-- Every declared outfit carries the prefix the client validates against.
for zType, outfitName in pairs(RQLivery.OUTFIT) do
    check(RQLivery.wears(outfitName), zType .. "'s outfit carries the prefix")
end
check(RQLivery.wears(RQLivery.ENRAGED_SCAVENGER), "the rage outfit carries the prefix")

-- ---------------------------------------------------------------------------
-- wears: the one question the client asks per zombie per frame
-- ---------------------------------------------------------------------------
check(RQLivery.wears("Police") == false, "a vanilla outfit is not ours")
check(RQLivery.wears(nil) == false, "an unresolved outfit (nil name) is not ours")
check(RQLivery.wears(42) == false, "a non-string is not ours")
check(RQLivery.wears("") == false, "an empty name is not ours")
check(RQLivery.wears("RQ_") == true, "the bare prefix counts - the test is the prefix, nothing more")
check(RQLivery.wears("rq_juggernaut") == false, "the prefix is case-sensitive, as outfit names are")

-- ---------------------------------------------------------------------------
-- The bald rule
-- ---------------------------------------------------------------------------
local defs = HairOutfitDefinitions.haircutOutfitDefinition
check(defs[1] and defs[1].outfit == "Police", "vanilla's own rows are appended to, not replaced")

local bald = {}
for _, row in ipairs(defs) do
    if row.haircut == "null:100" and row.beard == "null:100" then
        bald[row.outfit] = (bald[row.outfit] or 0) + 1
    end
end
for zType, outfitName in pairs(RQLivery.OUTFIT) do
    check(bald[outfitName] == 1, zType .. "'s outfit is declared bald exactly once")
end
check(bald[RQLivery.ENRAGED_SCAVENGER] == 1, "the rage outfit is declared bald too")
for i = 1, #RQLivery.BOSS_OUTFITS do
    check(bald[RQLivery.BOSS_OUTFITS[i]] == 1, RQLivery.BOSS_OUTFITS[i] .. " is declared bald exactly once")
end
check(bald["Police"] == nil, "vanilla outfits are not touched")

-- The generic field, never the gendered ones: those take precedence when
-- present and would need declaring twice.
for _, row in ipairs(defs) do
    if RQLivery.wears(row.outfit) then
        check(row.maleHaircut == nil and row.femaleHaircut == nil,
            row.outfit .. " declares only the generic haircut field")
    end
end

print(string.format("RQLivery: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
