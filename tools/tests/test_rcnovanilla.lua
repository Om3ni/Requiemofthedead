-- test_rcnovanilla.lua - vanilla-spawn suppression classification and walker.
--
-- WHY THIS IS TESTABLE AT ALL: RCNoVanilla.lua touches engine globals at file
-- scope only through require (stubbed to a no-op) and two Events
-- registrations (stubbed to capture). The classification (isExemptName,
-- burntFor) is pure string logic, and strip() takes its vanilla-resolver as a
-- PARAMETER precisely so this harness can inject one - the real resolver
-- (ScriptManager + pz-vanilla body test) is engine-only by design.
--
-- WHAT IT PINS:
--   * the exemption rule - wrecks and trailers must SURVIVE the strip; the
--     racecar zone's only entry is Base.RaceCarBurnt and a sloppy rule that
--     strips it leaves an empty zone spamming "no vehicle definition".
--   * the burnt mapping's PREFIX ORDER - PickUpVanLights before PickUpVan,
--     ModernCarLights (B42 police liveries) before ModernCar: get the order
--     wrong and a burnt police van becomes a civilian hull, silently.
--   * the walker - zone KEYS must survive even when every entry dies
--     (RandomizedWorldBase.addVehicle NPEs on a missing zone type), modded
--     entries (resolver says false) must survive, and counts must be honest.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rcnovanilla.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCNoVanilla.lua"

-- The whole harness: a no-op require and an Events table that swallows Add.
require = function() end
local captured = {}
local function fakeEvent(name)
    return { Add = function(fn) captured[name] = fn end }
end
Events = {
    OnLoadedTileDefinitions = fakeEvent("tiles"),
    OnSpawnVehicleStart     = fakeEvent("spawn"),
}

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

if type(RCNoVanilla) ~= "table"
    or type(RCNoVanilla.isExemptName) ~= "function"
    or type(RCNoVanilla.burntFor) ~= "function"
    or type(RCNoVanilla.strip) ~= "function" then
    print("FAIL RCNoVanilla surface is not exposed - suppression is untestable")
    print("RCNoVanilla: 0 passed, 1 failed")
    os.exit(1)
end

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

-- ---------------------------------------------------------------------------
-- Exemption rule: wrecks and towables survive, drivables do not
-- ---------------------------------------------------------------------------

eq("burnt hull is exempt",        RCNoVanilla.isExemptName("Base.CarNormalBurnt"), true)
eq("smashed variant is exempt",   RCNoVanilla.isExemptName("Base.PickUpTruckSmashedFront"), true)
eq("trailer is exempt",           RCNoVanilla.isExemptName("Base.Trailer_Livestock"), true)
eq("advert trailer is exempt",    RCNoVanilla.isExemptName("Base.TrailerAdvert"), true)
eq("drivable car is not exempt",  RCNoVanilla.isExemptName("Base.CarNormal"), false)
eq("unprefixed key is not exempt (the vanilla ranger typo)",
    RCNoVanilla.isExemptName("PickUpTruckLightsRanger"), false)
eq("non-string key is exempt (skip, never strip)",
    RCNoVanilla.isExemptName(42), true)

-- ---------------------------------------------------------------------------
-- Burnt mapping: family prefix order decides the hull
-- ---------------------------------------------------------------------------

eq("police car burns to the police hull",
    RCNoVanilla.burntFor("Base.CarLightsPolice"), "Base.NormalCarBurntPolice")
eq("B42 modern police livery burns to the police hull, not a civilian ModernCar",
    RCNoVanilla.burntFor("Base.ModernCarLightsMeadeSheriff"), "Base.NormalCarBurntPolice")
eq("lights van before plain van",
    RCNoVanilla.burntFor("Base.PickUpVanLightsFire"), "Base.PickUpVanLightsBurnt")
eq("lights truck gets the special burnt pickup",
    RCNoVanilla.burntFor("Base.PickUpTruckLightsFire"), "Base.PickupSpecialBurnt")
eq("plain pickup gets the plain burnt pickup",
    RCNoVanilla.burntFor("Base.PickUpTruck_Camo"), "Base.PickupBurnt")
eq("ambulance burns to AmbulanceBurnt",
    RCNoVanilla.burntFor("Base.VanAmbulance"), "Base.AmbulanceBurnt")
eq("prison bus burns to VanSeatsBurnt",
    RCNoVanilla.burntFor("Base.VanSeats_Prison"), "Base.VanSeatsBurnt")
eq("company step van burns to VanBurnt",
    RCNoVanilla.burntFor("Base.StepVan_Heralds"), "Base.VanBurnt")
eq("company van burns to VanBurnt",
    RCNoVanilla.burntFor("Base.Van_MassGenFac"), "Base.VanBurnt")
eq("SmallCar02 before SmallCar",
    RCNoVanilla.burntFor("Base.SmallCar02"), "Base.SmallCar02Burnt")
eq("ModernCar02 before ModernCar",
    RCNoVanilla.burntFor("Base.ModernCar02"), "Base.ModernCar02Burnt")
eq("taxi burns to TaxiBurnt",
    RCNoVanilla.burntFor("Base.CarTaxi2"), "Base.TaxiBurnt")
eq("drivable race car burns back to RaceCarBurnt (the CheckSwap unique-vehicle path)",
    RCNoVanilla.burntFor("Base.RaceCar12"), "Base.RaceCarBurnt")
eq("station wagon falls through to the everyman sedan",
    RCNoVanilla.burntFor("Base.CarStationWagon2"), "Base.CarNormalBurnt")
eq("unknown vanilla falls through to the everyman sedan",
    RCNoVanilla.burntFor("Base.SomethingNew43"), "Base.CarNormalBurnt")

-- ---------------------------------------------------------------------------
-- The walker: what dies, what survives, what gets counted
-- ---------------------------------------------------------------------------

-- Resolver stand-in: "vanilla" is membership in this set - the real one asks
-- the ScriptManager for the script's body-zero mod id.
local VANILLA = {
    ["Base.CarNormal"] = true,
    ["Base.SmallCar"] = true,
    ["Base.RaceCarBurnt"] = true,          -- vanilla AND exempt: must survive
    ["Base.Trailer"] = true,               -- vanilla AND exempt: must survive
    ["PickUpTruckLightsRanger"] = true,    -- the unprefixed vanilla typo
}
local function isVanilla(k) return VANILLA[k] == true end

local dist = {
    parkingstall = { vehicles = {
        ["Base.CarNormal"] = { index = -1, spawnChance = 20 },
        ["Base.SmallCar"]  = { index = -1, spawnChance = 10 },
        ["Base.87gmcS15"]  = { index = -1, spawnChance = 30 },  -- KI5-style Base.* mod vehicle
    }},
    racecar = { vehicles = {
        ["Base.RaceCarBurnt"] = { index = -1, spawnChance = 100 },
    }},
    farm = { vehicles = {
        ["Base.Trailer"]  = { index = -1, spawnChance = 10 },
        ["Base.CarNormal"] = { index = -1, spawnChance = 5 },
    }},
    ranger = { vehicles = {
        ["PickUpTruckLightsRanger"] = { index = -1, spawnChance = 50 },
    }},
    junkyard = { chanceToSpawnBurnt = 40 },  -- zone with no vehicles table: tolerated
    weird = 7,                               -- non-table zone value: tolerated
}

local removed, zones = RCNoVanilla.strip(dist, isVanilla)

eq("removed count", removed, 4)   -- CarNormal x2, SmallCar, the ranger typo
eq("zones touched", zones, 3)     -- parkingstall, farm, ranger
eq("vanilla car stripped",        dist.parkingstall.vehicles["Base.CarNormal"], nil)
eq("modded Base.* vehicle kept",  dist.parkingstall.vehicles["Base.87gmcS15"] ~= nil, true)
eq("burnt racecar kept",          dist.racecar.vehicles["Base.RaceCarBurnt"] ~= nil, true)
eq("farm trailer kept",           dist.farm.vehicles["Base.Trailer"] ~= nil, true)
eq("unprefixed ranger key stripped", dist.ranger.vehicles["PickUpTruckLightsRanger"], nil)
eq("emptied zone KEY survives",   dist.ranger ~= nil and dist.ranger.vehicles ~= nil, true)
eq("strip of a non-table is a no-op", (function()
    local r, z = RCNoVanilla.strip(nil, isVanilla)
    return r == 0 and z == 0
end)(), true)

-- Both event hooks must have registered at load.
eq("zone-strip hook registered",  type(captured.tiles), "function")
eq("story hook registered",       type(captured.spawn), "function")

print(string.format("RCNoVanilla: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
