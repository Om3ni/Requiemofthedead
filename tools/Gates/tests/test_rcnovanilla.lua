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
local HELPER = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCLoadedVehicles.lua"
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCNoVanilla.lua"

-- The whole harness: a no-op require and an Events table that swallows Add.
require = function() end
-- Handlers are kept as a LIST per event and dispatched in registration order,
-- because that is what LuaEventManager does and this file now registers two on
-- OnSpawnVehicleStart (Layer 2's story burn and Layer 4's in-place retrofit).
-- A harness that kept only the last Add would silently test the wrong one - it
-- did, the moment the second handler landed.
local handlers = {}
local captured = {}
local function fakeEvent(name)
    handlers[name] = {}
    captured[name] = function(...)
        for _, fn in ipairs(handlers[name]) do fn(...) end
    end
    return { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
end
Events = {
    OnLoadedTileDefinitions = fakeEvent("tiles"),
    OnSpawnVehicleStart     = fakeEvent("spawn"),
}

local okLoad, err = pcall(dofile, HELPER)
if okLoad then okLoad, err = pcall(dofile, SRC) end
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

-- MODDED ZONES ARE NOT OURS TO EDIT (2026-08-03). A zone a vehicle mod defined
-- is that author's curated list, and any vanilla entry in it is deliberate.
-- Stripping it is both rude and destructive: it can empty a zone the author
-- balanced, which is the permanently-failing-spawn-site state backfill exists
-- to prevent. The whitelist is derived from the game's own
-- VehicleZoneDefinition.lua, so "is this zone vanilla" is a fact, not a guess.
local modDist = {
    parkingstall  = { vehicles = { ["Base.CarNormal"] = { index = -1, spawnChance = 20 } } },
    ki5_dealership = { vehicles = { ["Base.CarNormal"] = { index = -1, spawnChance = 50 } } },
}
local mRemoved, mZones, mSkipped = RCNoVanilla.strip(modDist, isVanilla)
eq("vanilla zone is stripped",           modDist.parkingstall.vehicles["Base.CarNormal"], nil)
eq("modded zone is left completely alone",
    modDist.ki5_dealership.vehicles["Base.CarNormal"] ~= nil, true)
eq("only the vanilla zone counted",      mRemoved, 1)
eq("...as one zone touched",             mZones, 1)
eq("...and the modded one is reported skipped, not silently ignored", mSkipped, 1)
eq("every vanilla zone key the donor mod missed is in our set",
    (RCNoVanilla.VANILLA_ZONES.racecar and RCNoVanilla.VANILLA_ZONES.trafficjamn
     and RCNoVanilla.VANILLA_ZONES.trafficjame and RCNoVanilla.VANILLA_ZONES.business12)
    and true or false, true)

-- ---------------------------------------------------------------------------
-- BACKFILL. The strip leaves a zone REGISTERED but empty, and an empty zone is
-- not inert - VehicleType.init() still puts it in the map, so hasTypeForZone
-- answers true and every spawn attempt reaches RandomizeModel's
-- "no vehicle definition found" bail (IsoChunk.java:1316). A stripped-empty
-- zone is therefore a permanently failing spawn site, which is exactly the
-- "suppress vanilla and the world has no cars" report this pass came from.
--
-- The entry shape is pinned against the parser at VehicleType.java:69:
--   index       SKIN index; -1 means roll a random skin (IsoChunk.java:1335
--               only calls setSkinIndex when index > -1). Any other value would
--               pin every backfilled car to one paint job.
--   spawnChance normalised by the engine (100/sum), so equal values = equal
--               share and there are no weights to get wrong.
-- ---------------------------------------------------------------------------
local ROSTER = { "Base.87gmcS15", "Base.StepVan" }

local bf = {
    empty    = { vehicles = {} },
    populated = { vehicles = { ["Base.SomeModdedCar"] = { index = -1, spawnChance = 10 } } },
    wrecks   = { vehicles = { ["Base.RaceCarBurnt"] = { index = -1, spawnChance = 5 } } },
}
local added, filled = RCNoVanilla.backfill(bf, ROSTER)

eq("backfill added count", added, 2)      -- roster size x 1 empty zone
eq("backfill zones filled", filled, 1)    -- only `empty`
eq("empty zone got roster entry 1", bf.empty.vehicles["Base.87gmcS15"] ~= nil, true)
eq("empty zone got roster entry 2", bf.empty.vehicles["Base.StepVan"] ~= nil, true)
eq("backfilled index is -1 (random skin)",
    bf.empty.vehicles["Base.87gmcS15"].index, -1)
eq("backfilled spawnChance is a number",
    type(bf.empty.vehicles["Base.87gmcS15"].spawnChance), "number")

-- A zone a vehicle mod populated itself keeps ITS curation. Drowning an
-- author's weighted list in the whole roster would be worse than doing nothing.
eq("populated zone untouched",
    bf.populated.vehicles["Base.87gmcS15"], nil)
eq("populated zone keeps its own entry",
    bf.populated.vehicles["Base.SomeModdedCar"] ~= nil, true)

-- Wreck zones survive the strip via isExemptName, so they are never empty and
-- this rule spares them for free - no separate wreck check needed.
eq("wreck zone untouched", bf.wrecks.vehicles["Base.StepVan"], nil)

eq("backfill with an empty roster is a no-op", (function()
    local d = { z = { vehicles = {} } }
    local a, f = RCNoVanilla.backfill(d, {})
    return a == 0 and f == 0 and d.z.vehicles["anything"] == nil
end)(), true)

eq("backfill of a non-table is a no-op", (function()
    local a, f = RCNoVanilla.backfill(nil, ROSTER)
    return a == 0 and f == 0
end)(), true)

-- Both event hooks must have registered at load.
eq("zone-strip hook registered",  type(captured.tiles), "function")
eq("story hook registered",       type(captured.spawn), "function")

-- ---------------------------------------------------------------------------
-- LAYER 2 MUST NOT TOUCH MAP SPAWNS. The regression that produced a world of
-- nothing but burnt-out husks.
--
-- OnSpawnVehicleStart is not a story event: BaseVehicle.java:822 fires it in
-- createPhysics for EVERY brand-new vehicle, so without a story test the
-- handler burnt every vanilla car IsoChunk.AddVehicles placed in a parking
-- stall or traffic jam. It was worst with NoVanillaVehicles OFF, because then
-- the zones still had vanilla cars to spawn and all of them came through here.
--
-- The discriminator reads inverted: a ZONE spawn has a zone (setZone at
-- IsoChunk.java:1030), a STORY spawn does not (RandomizedWorldBase.addVehicle
-- never calls setZone).
-- ---------------------------------------------------------------------------
RCShared = { cfg = function() return { enabled = true, noVanillaStories = true } end,
             dbg = function() end }

local function fakeVehicle(fullName, zone)
    local v = { swappedTo = nil, reloaded = false }
    function v:isCreated() return false end
    function v:getZone() return zone end
    function v:getScript()
        return {
            getFullName = function() return fullName end,
            -- body zero "pz-vanilla" is the vanilla test (ScriptManager.VanillaID)
            getLoadedScriptBodies = function()
                return { size = function() return 1 end,
                         get = function(_, i) return "pz-vanilla" end }
            end,
        }
    end
    function v:setScriptName(n) self.swappedTo = n end
    function v:scriptReloaded(b) self.reloaded = b end
    return v
end

local zoned = fakeVehicle("Base.CarNormal", "parkingstall")
captured.spawn(zoned)
eq("MAP spawn (has a zone) is left alone", zoned.swappedTo, nil)

local zonedEmpty = fakeVehicle("Base.CarNormal", "")
captured.spawn(zonedEmpty)
eq("empty-string zone counts as zoneless", zonedEmpty.swappedTo ~= nil, true)

local story = fakeVehicle("Base.CarNormal", nil)
captured.spawn(story)
eq("STORY spawn (no zone) is burnt", story.swappedTo, "Base.CarNormalBurnt")
eq("burnt swap rebuilds with spawnSwap=true", story.reloaded, true)

-- The exemptions still hold on the story path.
local wreck = fakeVehicle("Base.CarNormalBurnt", nil)
captured.spawn(wreck)
eq("already-burnt story vehicle untouched", wreck.swappedTo, nil)

local trailer = fakeVehicle("Base.Trailer", nil)
captured.spawn(trailer)
eq("trailer story vehicle untouched", trailer.swappedTo, nil)

-- And the option still gates it.
RCShared.cfg = function() return { enabled = true, noVanillaStories = false } end
local off = fakeVehicle("Base.CarNormal", nil)
captured.spawn(off)
eq("story swap respects NoVanillaStoryVehicles = false", off.swappedTo, nil)

-- ---------------------------------------------------------------------------
-- Loaded scan isolation. A malformed/half-streamed foreign vehicle must not
-- stop later valid vehicles from reaching the census, nor can it be collected
-- for destructive purge without a completed classification.
-- ---------------------------------------------------------------------------
local realPrint = print
local diagnostics = {}
function print(message) diagnostics[#diagnostics + 1] = tostring(message) end
RCClaim = { isClaimed = function() return false end }
SafeHouse = { getSafeHouse = function() return nil end }
RCShared.cfg = function() return { janitorDays = 0 } end

local bad = {}
function bad:getScript() error("simulated classification fault") end
local good = {}
function good:getScript()
    return {
        getFullName = function() return "Base.CarNormal" end,
        getLoadedScriptBodies = function()
            return { size = function() return 1 end,
                     get = function() return "pz-vanilla" end }
        end,
        getPassengerCount = function() return 0 end,
    }
end
function good:isSeatOccupied() return false end
function good:getSquare() return nil end
function good:getModData() return {} end
function good:getScriptName() return "Base.CarNormal" end
function good:getX() return 10 end
function good:getY() return 20 end

local loaded = { bad, good }
function getCell()
    local index = 0
    return { getVehicles = function()
        return { iterator = function()
            return {
                hasNext = function() return index < #loaded end,
                next = function()
                    index = index + 1
                    return loaded[index]
                end,
            }
        end }
    end }
end

local survey = RCNoVanilla.survey()
eq("survey counts physical loaded vehicles despite one classification fault", survey.loaded, 2)
eq("later valid vehicle is still classified", survey.purge, 1)
eq("survey emits one bounded failure diagnostic", #diagnostics, 1)
eq("survey diagnostic names the failed count",
    diagnostics[1]:find("skipped 1 of 2 vehicle%(s%)", 1) ~= nil, true)
eq("survey diagnostic retains the failure", diagnostics[1]:find("simulated classification fault", 1, true) ~= nil, true)

realPrint(string.format("RCNoVanilla: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
