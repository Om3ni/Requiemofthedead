-- test_mmtraitkeys.lua - trait/profession identity keys must survive a mod that
-- shadows a vanilla registry path.
--
-- THE BUG THIS PINS (live, 2026-08-09, player "Mox"): CharacterTrait.getName()
-- returns ResourceLocation.getPath() - namespace stripped, lowercased - so
-- base:Organized and SeinarExtendedProfessions:Organized BOTH answer "organized".
-- MMShared's lookup was a name-keyed table built by walking every trait
-- definition, and vanilla scripts always parse before mod scripts, so the mod's
-- entry overwrote vanilla's. A memoir read stripped the player's real
-- base:organized and re-added the mod's inert placeholder in its place. The
-- container bonus (keyed in Java to CharacterTrait.ORGANIZED alone) vanished,
-- and because CAPTURE also stored getName(), the next snapshot recorded
-- "organized" again - the forensic record agreed with the player that nothing
-- had happened. Twelve vanilla trait paths were shadowed on that server.
--
-- Everything here runs on stock Lua: the engine surface (registry, resource
-- locations, definition tables) is stubbed below, because the property under
-- test is "which object does a stored key resolve to", which is pure lookup
-- logic. The stubs mirror the decompiled semantics that matter:
--   * ResourceLocation lowercases namespace AND path (ResourceLocation.java:24)
--   * getName() = path only; toString() = "namespace:path" (CharacterTrait:118,122)
--   * a stale object has no location, so toString() throws (Registry.getLocation
--     returns null after a reset -> NPE); fqid() must see that and rebuild
--   * CharacterTraitDefinition.getTraits() is insertion-ordered, base first
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_mmtraitkeys.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua"

-- Failures accumulate rather than printing inline: `print` is hooked further down
-- to capture the module's own warnings, so anything written during the checks
-- would land in that buffer instead of on the console.
local failures, checks = {}, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures[#failures + 1] = string.format("FAIL: %s\n        got:  %s\n        want: %s",
            label, tostring(got), tostring(want))
    end
end
local function checkTrue(label, got) check(label, not not got, true) end

-- =====================================================================
--  Engine stubs
-- =====================================================================

local traitRegistry, profRegistry = {}, {}

local function javaList(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

-- ResourceLocation.of, faithful to ResourceLocation.java:29-38 delegating to the
-- constructor's two checks at :17-23. It refuses an empty id, an empty namespace
-- and an empty path; it defaults a bare id to the "base" namespace (:34-36) and
-- lowercases both halves (:24-25). Nothing ELSE throws - the split takes the
-- FIRST colon only (limit 2), and no character is illegal, not even a space:
-- vanilla registers "Very Underweight" itself (CharacterTrait.java:103).
--
-- The empty-namespace and empty-path throws are what the resolvers' shape
-- precondition exists to keep out, so this stub has to be able to raise them.
ResourceLocation = {
    of = function(id)
        if type(id) ~= "string" or id == "" then error("Identifier cannot be null or empty") end
        local ns, path = id:match("^([^:]*):(.*)$")
        if not ns then ns, path = "base", id end
        if ns == "" then error("Namespace cannot be null or empty") end
        if path == "" then error("Path cannot be null or empty") end
        return (ns .. ":" .. path):lower()
    end,
}

local function register(reg, id)
    id = id:lower()
    local o = { __id = id, __reg = reg }
    o.getName = function(self) return self.__id:match("^[^:]+:(.+)$") end
    setmetatable(o, { __tostring = function(self)
        -- Stale object: dropped from the registry, so getLocation() is null and
        -- the real toString() NPEs. pcall in fqid() is what catches this.
        if self.__reg[self.__id] ~= self then error("no location for stale object") end
        return self.__id
    end })
    reg[id] = o
    return o
end

CharacterTrait = { get = function(id) return traitRegistry[id] end }
CharacterProfession = { get = function(id) return profRegistry[id] end }

-- Definition tables: insertion-ordered, exactly like the LinkedHashMaps.
local traitDefs, profDefs = {}, {}
local function addTraitDef(trait, cost, isProf)
    local def = { getType = function() return trait end,
                  getCost = function() return cost end,
                  isFree = function() return isProf == true end }
    traitDefs[#traitDefs + 1] = def
    return def
end
local function addProfDef(prof, cost)
    local def = { getType = function() return prof end,
                  getCost = function() return cost end,
                  getUIName = function() return "UI:" .. prof:getName() end }
    profDefs[#profDefs + 1] = def
    return def
end
CharacterTraitDefinition = {
    getTraits = function() return javaList(traitDefs) end,
    getCharacterTraitDefinition = function(t)
        for _, d in ipairs(traitDefs) do if d.getType() == t then return d end end
    end,
}
CharacterProfessionDefinition = {
    getProfessions = function() return javaList(profDefs) end,
    getCharacterProfessionDefinition = function(p)
        for _, d in ipairs(profDefs) do if d.getType() == p then return d end end
    end,
}

-- The world: vanilla first, then the mod - the order ScriptManager actually loads.
local T_BASE_ORG   = register(traitRegistry, "base:organized")
local T_BASE_DEX   = register(traitRegistry, "base:dextrous")
local T_BASE_UNDER = register(traitRegistry, "base:underweight")
local T_MOD_ORG    = register(traitRegistry, "seinarextendedprofessions:organized")
local T_MOD_SLICER = register(traitRegistry, "seinarextendedprofessions:slicer")
addTraitDef(T_BASE_ORG, 4, false)     -- vanilla Organized: costs 4, not a profession trait
addTraitDef(T_BASE_DEX, 2, false)
addTraitDef(T_BASE_UNDER, 0, false)
addTraitDef(T_MOD_ORG, 0, true)       -- Seinar's placeholder: free profession trait
addTraitDef(T_MOD_SLICER, 0, true)

local P_BASE_UNEMP = register(profRegistry, "base:unemployed")
local P_MOD_WRITER = register(profRegistry, "seinarextendedprofessions:writer")
addProfDef(P_BASE_UNEMP, 0)
addProfDef(P_MOD_WRITER, 0)

-- Globals MMSvShared touches at load: the weight-trait constants the codec reads,
-- the RDShared registration, the event table, and the side predicates.
CharacterTrait.UNDERWEIGHT      = T_BASE_UNDER
CharacterTrait.VERY_UNDERWEIGHT = nil
CharacterTrait.EMACIATED        = nil
CharacterTrait.OVERWEIGHT       = nil
CharacterTrait.OBESE            = nil
BaseGameCharacterDetails = {}
SandboxVars = { RFTDMemoir = {} }
function isServer() return true end
function isClient() return false end

-- PZ's event table is called with a DOT (Events.OnGameBoot.Add(fn)), so the stub
-- takes one argument. A colon-style stub silently records nothing.
local hooked = {}
local function evt() return { Add = function(f) hooked[#hooked + 1] = f end } end
Events = { OnGameBoot = evt(), OnServerStarted = evt() }

RDShared = { registerMod = function() end, EXT_DOC = ".json.txt", EXT_DOC_LEGACY = ".json" }
local realRequire = require
require = function(name)
    if name == "RDShared" then return RDShared end
    if name == "MMSvShared" then return MMShared end
    return realRequire(name)
end

-- Capture the unconditional warnings so the collision report can be asserted.
-- The hook STAYS installed: the lookup caches build lazily on first use, so the
-- collision report fires during the checks below, not at load. Unhooking after
-- load would assert against an empty list and pass vacuously.
local warned = {}
local realPrint = print
print = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
assert(loadfile(SRC .. "/shared/MMSvShared.lua"))()
assert(loadfile(SRC .. "/shared/MMSnapshotCodec.lua"))()

local function warnedMatching(pat)
    for _, w in ipairs(warned) do if w:find(pat) then return w end end
    return nil
end

-- =====================================================================
--  1. THE REGRESSION. A legacy bare name must resolve to VANILLA.
-- =====================================================================
-- This is Mox's bug in one line. Before the fix findTraitByName("organized")
-- returned the mod's trait, because it was registered second and won the key.
check("legacy bare name resolves vanilla-first",
    MMShared.findTrait("organized"), T_BASE_ORG)
check("the ambiguous name map still resolves mod-last (documented, fallback only)",
    MMShared.findTraitByName("organized"), T_MOD_ORG)

-- =====================================================================
--  2. Fully-qualified ids are exact in both directions.
-- =====================================================================
check("explicit base id", MMShared.findTrait("base:organized"), T_BASE_ORG)
check("explicit mod id",  MMShared.findTrait("seinarextendedprofessions:organized"), T_MOD_ORG)
check("id lookup is case-insensitive",
    MMShared.findTrait("SeinarExtendedProfessions:Organized"), T_MOD_ORG)
check("fqid round-trips", MMShared.fqid(T_BASE_ORG), "base:organized")
check("fqid of a mod trait keeps its namespace",
    MMShared.fqid(T_MOD_ORG), "seinarextendedprofessions:organized")

-- =====================================================================
--  3. Mod-only traits still resolve. Vanilla-first must not mean vanilla-only:
--     a bare "slicer" has no base:slicer, so it falls through to the scan.
-- =====================================================================
check("mod-only bare name falls back to the scan",
    MMShared.findTrait("slicer"), T_MOD_SLICER)
check("unknown key resolves to nothing", MMShared.findTrait("no_such_trait"), nil)
check("empty key is refused, not guessed", MMShared.findTrait(""), nil)
check("non-string key is refused", MMShared.findTrait(nil), nil)

-- =====================================================================
--  4. Canonical keys: a v4 book and a v5 book must compare equal.
-- =====================================================================
check("legacy and id keys canonicalise together",
    MMShared.canonTraitKey("organized"), MMShared.canonTraitKey("base:organized"))
check("shadowed pair does NOT canonicalise together",
    MMShared.canonTraitKey("base:organized") ~= MMShared.canonTraitKey("seinarextendedprofessions:organized"), true)
check("unresolvable key canonicalises to itself, not nil",
    MMShared.canonTraitKey("ghost_trait"), "ghost_trait")

-- =====================================================================
--  5. The collision is REPORTED at cache build, not discovered by a player.
-- =====================================================================
checkTrue("collision warning names the trait path", warnedMatching("TRAIT NAME COLLISIONS"))
checkTrue("collision warning names both namespaces",
    warnedMatching("seinarextendedprofessions:organized"))

-- =====================================================================
--  6. Cost is read off the RIGHT definition. Vanilla Organized costs 4;
--     the placeholder costs 0. budgetCost picking the wrong one is how a
--     restore would have mis-scored a build's legality.
-- =====================================================================
check("budgetCost uses vanilla's cost for a legacy bare name",
    MMSnapshotCodec.budgetCost(nil, { "organized" }), 4)
check("budgetCost uses vanilla's cost for an explicit base id",
    MMSnapshotCodec.budgetCost(nil, { "base:organized" }), 4)
check("budgetCost uses the mod's cost when the mod trait is what was saved",
    MMSnapshotCodec.budgetCost(nil, { "seinarextendedprofessions:organized" }), 0)
check("budgetCost sums across a build",
    MMSnapshotCodec.budgetCost(nil, { "base:organized", "base:dextrous" }), 6)

-- =====================================================================
--  7. Weight traits are recognised by id AND by legacy bare name, so a v4
--     snapshot's "underweight" is still excluded from identity.
-- =====================================================================
checkTrue("weight trait by id", MMSnapshotCodec.isWeightTrait("base:underweight"))
checkTrue("weight trait by legacy bare name", MMSnapshotCodec.isWeightTrait("underweight"))
check("a normal trait is not a weight trait",
    MMSnapshotCodec.isWeightTrait("base:organized"), false)

-- =====================================================================
--  8. Professions: same defect, same key, same guarantees.
-- =====================================================================
check("profession id resolves exactly",
    MMShared.findProfessionDef("base:unemployed").getType(), P_BASE_UNEMP)
check("legacy bare profession resolves vanilla-first",
    MMShared.findProfessionDef("unemployed").getType(), P_BASE_UNEMP)
check("mod profession resolves by id",
    MMShared.findProfessionDef("seinarextendedprofessions:writer").getType(), P_MOD_WRITER)
check("profession canonical keys agree across schema versions",
    MMShared.canonProfessionKey("unemployed"), MMShared.canonProfessionKey("base:unemployed"))
check("professionUIName resolves through the id", MMShared.professionUIName("base:unemployed"), "UI:unemployed")

-- =====================================================================
--  8b. Malformed stored keys. ResourceLocation.of is the ONLY throwing step in
--      either resolution chain; the registry reads are bare map lookups that
--      return null on a miss. So the resolvers test the key SHAPE as a
--      precondition rather than wrapping the call, and a snapshot carrying a
--      half-written id resolves to nil instead of raising - while a genuine
--      registry fault stays loud.
-- =====================================================================
check("empty-namespace trait key resolves to nil", MMShared.findTrait(":organized"), nil)
check("empty-path trait key resolves to nil", MMShared.findTrait("base:"), nil)
check("lone colon resolves to nil", MMShared.findTrait(":"), nil)
check("empty-namespace profession key resolves to nil",
    MMShared.findProfessionDef(":unemployed"), nil)
check("empty-path profession key resolves to nil", MMShared.findProfessionDef("base:"), nil)
check("a well-formed mod key is still reached", MMShared.findTrait("seinarextendedprofessions:organized"), T_MOD_ORG)

-- =====================================================================
--  8c. A profession definition with no CharacterProfession= line. Its type is
--      null and LinkedHashMap accepts the null key, so getProfessions() hands
--      the broken definition back (CharacterProfessionDefinition.java:45-49,
--      51-53). Calling getName() on it used to take the whole index build down
--      and surface to an admin as an opaque restore preflight failure whose
--      real cause was ANOTHER mod's malformed script.
--
--      The trait side cannot reach this case - its constructor derefs the type
--      to build the icon path (CharacterTraitDefinition.java:43) - which is why
--      only the profession loop carries the skip.
-- =====================================================================
profDefs[#profDefs + 1] = { getType = function() return nil end,
                            getUIName = function() return "UI:broken" end }
MMShared.resetLookups()
-- Must go through a MOD-ONLY profession: a bare key that resolves as base:<path>
-- never reaches the by-name index, so it would not exercise the loop at all.
check("a null-typed profession definition does not break the index",
    MMShared.findProfessionDef("writer").getType(), P_MOD_WRITER)
checkTrue("the skipped definition is named, not swallowed",
    warnedMatching("no CharacterProfession="))
profDefs[#profDefs] = nil
MMShared.resetLookups()

-- =====================================================================
--  9. Staleness self-heal. ScriptManager.Reset() drops every non-base registry
--     entry and Load() re-registers NEW objects, so a cached mod trait can
--     outlive its registry. fqid() sees the dead object and the cache rebuilds
--     rather than handing back a ghost that throws on use.
-- =====================================================================
check("fqid of a live object", MMShared.fqid(T_MOD_SLICER), "seinarextendedprofessions:slicer")
traitRegistry["seinarextendedprofessions:slicer"] = nil          -- the reset
check("fqid of a stale object is nil, not a crash", MMShared.fqid(T_MOD_SLICER), nil)
local T_MOD_SLICER2 = register(traitRegistry, "seinarextendedprofessions:slicer") -- the reload
traitDefs[#traitDefs] = nil
addTraitDef(T_MOD_SLICER2, 0, true)
check("the scan cache rebuilds and returns the NEW object",
    MMShared.findTraitByName("slicer"), T_MOD_SLICER2)

-- =====================================================================
--  10. resetLookups is wired to a boot event, so a script reload does not
--      leave a whole session resolving against a dead registry.
-- =====================================================================
check("both boot hooks registered", #hooked, 2)
checkTrue("resetLookups is exported", type(MMShared.resetLookups) == "function")

-- =====================================================================

print = realPrint -- release the warning capture; results go to the console

if #failures > 0 then
    for _, f in ipairs(failures) do print(f) end
    print(string.format("test_mmtraitkeys: %d/%d checks FAILED", #failures, checks))
    os.exit(1)
end
print(string.format("test_mmtraitkeys: %d checks passed", checks))
