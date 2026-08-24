-- DMRegistry fixture - authored ids crossed against the engine's registries.
--
-- WHAT IS ACTUALLY AT RISK. Every registry this file touches answers an unknown
-- id with a QUIET MISS rather than an error, and two of them do not even answer
-- with nil. So the failure being guarded against is never a crash: it is a kit
-- that saves clean, claims clean, and hands over less than it promised. The
-- assertions here are almost entirely about refusing, because accepting is what
-- goes unnoticed.
--
-- THE FIXTURES IMPLEMENT THE VERIFIED SURFACE AND NOTHING ELSE. The trait list
-- is a fake Java List exposing only size() and get(i) - no pairs, no ipairs,
-- no length - so a rewrite that reaches for Lua iteration fails here instead of
-- on a live server. Perks.FromString returns the MAX sentinel for a miss, as
-- the real one does (AddXPCommand.java:46-47), rather than the nil a careless
-- stub would return and a careless implementation would then pass.

local ROOT = arg[1] or "."
local MOD = ROOT .. "/RequiemOfTheDead/Contents/mods"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMRegistry: " .. message) end
end

-- ---- engine stubs ---------------------------------------------------------

-- A Java List as Kahlua sees one: indexed access only. Deliberately hostile to
-- ipairs and to #, so landmine 2 in the module header is enforced rather than
-- merely described.
local function javaList(items)
    return setmetatable({}, {
        __index = function(_, k)
            if k == "size" then return function() return #items end end
            if k == "get" then
                return function(_, i) return items[i + 1] end   -- zero-based
            end
            return nil
        end,
        __len = function() error("a Java collection has no length in Kahlua", 2) end,
    })
end

local function traitDef(id, label)
    local trait = setmetatable({}, { __tostring = function() return id end })
    return {
        getType  = function() return trait end,
        getLabel = function() return label end,
        -- Present precisely so a rewrite that reaches for it is caught: the
        -- namespace is stripped, which is the whole of CLAUDE.md sect. 6.
        getName  = function() return (id:match(":(.+)$") or id) end,
    }, trait
end

local braveDef  = traitDef("base:Brave", "Brave")
local delverDef = traitDef("RFTDDungeonMaster:Delver", "Delver")
-- The collision: same bare name, different namespace. Keyed by getName() these
-- overwrite each other and one becomes unreachable.
local modBrave  = traitDef("SomeOtherMod:Brave", "Brave (theirs)")

local traitDefs = { braveDef, delverDef, modBrave }
CharacterTraitDefinition = {
    getTraits = function() return javaList(traitDefs) end,
}

local MAX_SENTINEL = { name = "MAX" }
Perks = {
    MAX = MAX_SENTINEL,
    FromString = function(s)
        if s == "Woodwork" then return { name = "Woodwork" } end
        if s == "Fitness"  then return { name = "Fitness"  } end
        return MAX_SENTINEL
    end,
}

local items = { ["Base.Axe"] = { t = "axe" }, ["Base.Crowbar"] = { t = "crowbar" } }
local scriptManager = { getItem = function(_, ft) return items[ft] end }
function getScriptManager() return scriptManager end

require = function() return true end
RDVarDefs, DMRoll, DMKitDefs, DMRegistry = nil, nil, nil, nil
local ok, err = pcall(dofile, MOD .. "/RFTDCore/42/media/lua/shared/RDVarDefs.lua")
check(ok, "RDVarDefs loads: " .. tostring(err))
ok, err = pcall(dofile, MOD .. "/RFTDDungeonMaster/42/media/lua/shared/DMRoll.lua")
check(ok, "DMRoll loads: " .. tostring(err))
ok, err = pcall(dofile, MOD .. "/RFTDDungeonMaster/42/media/lua/shared/DMKitDefs.lua")
check(ok, "DMKitDefs loads: " .. tostring(err))
ok, err = pcall(dofile, MOD .. "/RFTDDungeonMaster/42/media/lua/shared/DMRegistry.lua")
check(ok, "DMRegistry loads: " .. tostring(err))

local G = DMRegistry

-- ---- traits ---------------------------------------------------------------

check(G.trait("base:Brave") ~= nil, "the base trait did not resolve")
check(G.trait("RFTDDungeonMaster:Delver") ~= nil, "the mod trait did not resolve")

-- The collision, which is the entire reason ids are keyed on tostring: both
-- traits are called "Brave" and BOTH must remain reachable.
check(G.trait("SomeOtherMod:Brave") ~= nil,
    "a second mod's same-named trait was shadowed")
check(G.trait("base:Brave") ~= G.trait("SomeOtherMod:Brave"),
    "two differently-namespaced traits resolved to the same object")

-- The bare name must NOT resolve. If it does, the map is keyed on getName()
-- and one of the two Braves above is unreachable.
check(G.trait("Brave") == nil, "a bare trait name resolved - the map is keyed "
    .. "on getName(), which strips the namespace")

local _, braveWhy = G.trait("Brave")
check(type(braveWhy) == "string" and braveWhy:find("base:Brave", 1, true) ~= nil,
    "the refusal for a bare name did not suggest the namespaced form: "
    .. tostring(braveWhy))

check(G.trait("base:Nonexistent") == nil, "an unregistered id resolved")
check(G.trait("") == nil, "an empty trait id resolved")
check(G.trait(nil) == nil, "a nil trait id resolved")
check(G.trait(7) == nil, "a numeric trait id resolved")
local _, missWhy = G.trait("base:Nonexistent")
check(type(missWhy) == "string" and missWhy ~= "",
    "an unregistered trait was refused with no reason")

-- ---- the trait list, for the authoring picker ------------------------------

local list = G.traits()
check(#list == 3, "the trait list held " .. #list .. " entries, expected 3")
-- Sorted by label, so the picker is alphabetical rather than registry order.
check(list[1].label == "Brave", "the trait list was not sorted by label")
check(list[1].id == "base:Brave", "the sorted list lost the namespace")
-- Every entry must carry the ID, not just the label - a picker offering labels
-- alone cannot distinguish the two Braves.
for i = 1, #list do
    check(type(list[i].id) == "string" and list[i].id ~= "",
        "trait list entry " .. i .. " carried no id")
end

-- The returned list is a copy: a caller sorting or trimming it for display must
-- not reshape the cache every other caller reads.
local again = G.traits()
check(again ~= list, "traits() handed back its own cached table")
list[1] = nil
check(#G.traits() == 3, "mutating the returned list changed the cache")

-- ---- perks ----------------------------------------------------------------

check(G.perk("Woodwork") ~= nil, "a real perk did not resolve")
-- The sentinel. A nil check alone accepts this, which would put every
-- misspelled skill straight onto the server.
check(G.perk("Wodwork") == nil, "a misspelled perk resolved to the MAX sentinel")
check(G.perk("") == nil, "an empty perk name resolved")
check(G.perk(nil) == nil, "a nil perk name resolved")
local _, perkWhy = G.perk("Wodwork")
check(type(perkWhy) == "string" and perkWhy:find("Wodwork", 1, true) ~= nil,
    "the perk refusal did not quote what was typed: " .. tostring(perkWhy))

-- ---- items ----------------------------------------------------------------

check(G.item("Base.Axe") ~= nil, "a real item did not resolve")
check(G.item("Base.Nonexistent") == nil, "an unknown item resolved")
check(G.item("Axe") == nil, "an item type without its module resolved")
check(G.item("") == nil, "an empty item type resolved")
local _, itemWhy = G.item("Axe")
check(type(itemWhy) == "string" and itemWhy:find("Base.Axe", 1, true) ~= nil,
    "the refusal for a module-less type did not suggest one: " .. tostring(itemWhy))

-- ---- a whole kit's grants, checked against the world -----------------------

local function grantsOk(grants, why)
    local out, reason = G.checkGrants(grants)
    check(out ~= nil, (why or "grants") .. " were refused: " .. tostring(reason))
end
local function grantsBad(grants, why)
    local out, reason = G.checkGrants(grants)
    check(out == nil, "ACCEPTED " .. (why or "bad grants"))
    check(out ~= nil or (type(reason) == "string" and reason ~= ""),
        "refused " .. (why or "") .. " with no reason")
    return reason
end

grantsOk({
    { kind = "item", type = "Base.Axe", count = 1 },
    { kind = "trait", id = "base:Brave" },
    { kind = "xp", perk = "Woodwork", amount = 10 },
    { kind = "flag", name = "cryptdelver" },
    { kind = "counter", name = "samples", add = 1 },
}, "a kit whose every id resolves")

grantsBad({ { kind = "item", type = "Base.Nonexistent", count = 1 } },
    "a kit naming an item that does not exist")
grantsBad({ { kind = "trait", id = "base:Nope" } },
    "a kit naming a trait that does not exist")
grantsBad({ { kind = "xp", perk = "Wodwork", amount = 10 } },
    "a kit naming a skill that does not exist")

-- Var grants pass here on purpose - their registry is RDVars, which is
-- server-only, so DMKits checks them where it holds the store.
grantsOk({ { kind = "flag", name = "anything" } },
    "a flag grant, which this file deliberately does not judge")

-- The position must survive into the reason, or a DM with a full form is
-- hunting by hand.
local posReason = grantsBad({
    { kind = "item", type = "Base.Axe" },
    { kind = "item", type = "Base.Ghost" },
}, "a bad id in the second grant")
check(type(posReason) == "string" and posReason:find("grant 2", 1, true) ~= nil,
    "the refusal did not name the offending grant: " .. tostring(posReason))

-- A branch that can win must be as real as a grant that always fires. This is
-- the case a save-time check exists for: the kit works nine claims in ten.
grantsOk({ { kind = "roulette", pick = 1, from = {
    { weight = 1, grants = { { kind = "item", type = "Base.Axe" } } },
    { weight = 9, grants = { { kind = "item", type = "Base.Crowbar" } } },
} } }, "a roulette whose branches all resolve")

local branchReason = grantsBad({ { kind = "roulette", pick = 1, from = {
    { weight = 1, grants = { { kind = "item", type = "Base.Axe" } } },
    { weight = 9, grants = { { kind = "item", type = "Base.Ghost" } } },
} } }, "a roulette with an unresolvable branch")
check(type(branchReason) == "string"
    and branchReason:find("branch 2", 1, true) ~= nil,
    "the refusal did not name the offending branch: " .. tostring(branchReason))

grantsBad({ { kind = "roulette", pick = 1, from = {
    { weight = 1, grants = { { kind = "trait", id = "Brave" } } },
} } }, "a bare trait name inside a branch")

check(G.checkGrants("nope") == nil, "checkGrants accepted a non-list")

-- ---- the cache rebuilds ---------------------------------------------------
-- Built lazily because scripts load during boot; a map built at file scope
-- would be empty forever. forget() is what makes that testable, and what lets
-- a script reload take effect.

traitDefs[#traitDefs + 1] = traitDef("Late:Arrival", "Arrival")
check(G.trait("Late:Arrival") == nil,
    "a trait registered after the cache was built resolved without a rebuild")
G.forget()
check(G.trait("Late:Arrival") ~= nil, "forget() did not rebuild the trait cache")
check(#G.traits() == 4, "the rebuilt list did not pick up the new trait")

print(string.format("DMRegistry: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
