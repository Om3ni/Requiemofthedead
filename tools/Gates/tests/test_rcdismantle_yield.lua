-- test_rcdismantle_yield.lua - authoritative removal before dismantle rewards.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/shared/RCDismantleYield.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

local removed, dumpCalls, wear, xpCalls = false, 0, 0, 0
local failRemoval, failScrap = false, false
-- BOTH FAILURE MODES ARE NIL RETURNS, NOT THROWS (corrected 2026-08-19).
-- These are exposed methods, so a fault inside either is a Java body throw that
-- MethodCaller swallows and stack-traces, pushing no return value
-- (MethodCaller.java:33-56). The fixture used to call error() for both, which
-- modelled an impossible event and held production to two guards that could
-- never fire. Production now detects each failure by the value the engine was
-- already returning, which is the only thing Lua can actually observe.
local square = {}
function square:AddWorldInventoryItem()
    -- The String overload answers nil exactly when the item definition cannot
    -- be created (IsoGridSquare.java:5380-5384) - the modded-definition failure
    -- the old caller-side pcall imagined as a throw.
    if failScrap then return nil end
    return {}
end

local cellVehicles = {}
function cellVehicles:contains() return not removed end
local cell = {}
function cell:getVehicles() return cellVehicles end
function getCell() return cell end

local vehicle = {}
function vehicle:getSquare() return square end
function vehicle:permanentlyRemove()
    -- A faulted teardown leaves removedFromWorld unset (IsoVehicle:7146) and
    -- leaves the car in the cell (:7177) - it does not raise. That pair is the
    -- precondition RCDismantleYield.lua:117-119 checks, and the first real
    -- "car is gone" test this contract has had: `removed` used to be a flag we
    -- set ourselves, which was always true, so commit() had never once refused.
    if failRemoval then return end
    removed = true
end
function vehicle:isRemovedFromWorld() return removed end

local character = {}
function character:getPerkLevel() return 0 end
local torch = {}
function torch:Use()
    eq("torch wear occurs after removal", removed, true)
    wear = wear + 1
end

Perks = { MetalWelding = "welding", Mechanics = "mechanics" }
function ZombRand() return failScrap and 0 or 1 end
function ZombRandFloat() return 0.5 end
function addXp(_, perk, amount)
    eq("XP occurs after removal", removed, true)
    eq("XP uses welding perk", perk, Perks.MetalWelding)
    xpCalls = xpCalls + 1
    _G.lastXp = amount
end
RCShared = {
    dumpVehicleContainers = function(_, capturedSquare)
        eq("dump receives pre-removal square", capturedSquare, square)
        eq("container dump occurs after removal", removed, true)
        dumpCalls = dumpCalls + 1
        return 3
    end,
}

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local function reset()
    removed, dumpCalls, wear, xpCalls = false, 0, 0, 0
    failRemoval, failScrap, _G.lastXp = false, false, nil
end

reset()
local ok, result = RCDismantleYield.commit(vehicle, character, torch, false)
eq("normal commit succeeds", ok, true)
eq("normal commit removes vehicle", removed, true)
eq("normal commit dumps containers once", dumpCalls, 1)
eq("normal commit charges ten uses", wear, 10)
eq("normal commit grants XP once", xpCalls, 1)
eq("normal commit grants base XP", _G.lastXp, 5)
eq("normal commit reports dump count", result.dumped, 3)

reset()
failRemoval = true
local removeOk, removeResult = RCDismantleYield.commit(vehicle, character, torch, false)
eq("remove failure is returned", removeOk, false)
eq("remove failure phase is explicit", removeResult.phase, "remove")
eq("remove failure grants no dump", dumpCalls, 0)
eq("remove failure charges no torch", wear, 0)
eq("remove failure grants no XP", xpCalls, 0)

reset()
failScrap = true
local scrapOk, scrapResult = RCDismantleYield.commit(vehicle, character, torch, false)
eq("optional scrap failure preserves commit", scrapOk, true)
eq("optional scrap failure is visible", scrapResult.scrapError ~= nil, true)
eq("optional scrap failure counts every isolated failed roll", scrapResult.scrapFailures, 210)
eq("optional scrap failure still charges torch", wear, 10)
eq("optional scrap failure still grants base XP", _G.lastXp, 5)

reset()
local eternalOk, eternalResult = RCDismantleYield.commit(vehicle, character, torch, true)
eq("eternal commit succeeds", eternalOk, true)
eq("eternal commit skips torch wear", wear, 0)
eq("eternal state is returned", eternalResult.eternal, true)

print(string.format("RCDismantleYield: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
