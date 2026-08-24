-- HBParts fixture - the derived watchlist and the namespace claim.
--
-- The property under test is DERIVED-NOT-AUTHORED: the watchlist must be
-- exactly what AnimalPartsDefinitions says plus the one corpse item, because
-- the predecessor design (pattern lists) is how RQD-era loggers ended up
-- matching Bandage_Head and missing modded animals. If someone reintroduces a
-- pattern, the negative controls here go red.
--
-- Engine-free: HBParts touches require, RDEvents and AnimalPartsDefinitions,
-- all stubbed; the module itself is stock Lua.

local ROOT = arg[1] or "."
local SOURCE = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/shared/HBParts.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL HBParts: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

require = function() return true end

local registered = {}
RDEvents = {
    registerNamespace = function(prefix, modId, events)
        registered[prefix] = { mod = modId, events = events }
        return true
    end,
}

AnimalPartsDefinitions = { animals = {
    doewhitetailed = { head = "Base.Deer_Doe_Head",
                       parts = { { item = "Base.Venison", minNb = 10 } } },
    cowangus       = { head = "Base.Cow_Head_Angus", skull = "Base.Cow_Skull" },
    -- a modded def with only a skull, and a def naming no parts at all
    wendigo        = { skull = "Mod.Wendigo_Skull" },
    bare           = { parts = {} },
    -- a def whose head field is junk must not poison the set
    broken         = { head = 42 },
} }

-- ---- load ----------------------------------------------------------------

HBParts = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
local P = HBParts

-- ---- namespace claim -----------------------------------------------------

check(registered.HB ~= nil, "the HB namespace was never claimed")
check(registered.HB and registered.HB.mod == "RFTDHusbandry",
    "HB claimed for the wrong mod: " .. tostring(registered.HB and registered.HB.mod))
local ev = registered.HB and registered.HB.events and registered.HB.events.PART_PLACED
check(ev ~= nil, "PART_PLACED is not registered")
check(ev and ev.scope == "p", "PART_PLACED is not player-scoped")
local hasPath = false
for _, k in ipairs(ev and ev.req or {}) do
    if k == "path" then hasPath = true end
end
check(hasPath, "req does not name `path` - the lane discriminator every "
    .. "query pivots on")

check(P.MODULE == "RFTDHusbandry", "MODULE constant drifted")
check(P.STREAM == "parts", "STREAM constant drifted")
check(P.EVENT == "HB.PART_PLACED", "EVENT constant drifted")

-- ---- watchlist: what IS watched ------------------------------------------

check(P.isWatched("Base.Deer_Doe_Head"), "a def's head is not watched")
check(P.isWatched("Base.Cow_Head_Angus"), "a second def's head is not watched")
check(P.isWatched("Base.Cow_Skull"), "a def's skull is not watched")
check(P.isWatched("Mod.Wendigo_Skull"),
    "a MODDED def's skull is not watched - deriving from the registry is the "
    .. "whole reason modded animals are covered for free")
check(P.isWatched("Base.CorpseAnimal"),
    "the corpse item is not watched - it is the one authored entry")

-- ---- watchlist: what is NOT ----------------------------------------------

check(not P.isWatched("Base.Venison"),
    "a `parts` meat item is watched - meat/bones are ordinary drops and "
    .. "watching them turns the trickle into a second guardian")
check(not P.isWatched("Base.Bandage_Head"),
    "Bandage_Head matched - a pattern crept back in; the set is exact "
    .. "fullTypes only")
check(not P.isWatched("Base.ClawhammerHead"), "a tool head matched")
check(not P.isWatched("Base.Deer_Doe_Head2"),
    "a superstring of a real head matched - matching is not exact")

-- ---- degenerate inputs ---------------------------------------------------

check(not P.isWatched(nil), "nil faulted or matched")
check(not P.isWatched(""), "empty string matched")
check(not P.isWatched(42), "a number faulted or matched")
check(not P.isWatched({}), "a table faulted or matched")

-- ---- build-once contract -------------------------------------------------
-- The set is built on FIRST use and kept: defs are load-time data. A def
-- appearing after first use is deliberately not seen - this pins that the
-- behaviour is a decision, not an accident, so a change to it is conscious.

AnimalPartsDefinitions.animals.late = { head = "Mod.Late_Head" }
check(not P.isWatched("Mod.Late_Head"),
    "the watchlist rebuilt after first use - the build-once contract changed; "
    .. "if that is intended, update HBParts' comment and this test together")

print(string.format("HBParts: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
