-- RCNoVanilla - vanilla vehicle spawn suppression, at both sources.
--
-- Successor to the NoVanillaVehicles / NoVanillaVehicleStories workshop pair
-- (2535461640), rebuilt against the 42.20 decompile because the originals
-- have real holes: the B41-era zone list nils trafficjamw but not
-- trafficjame/n/s, misses all thirteen business* zones (the ~50 B42 company
-- vans spawn untouched) and racecar; the stories mod swaps to a hardcoded
-- vehicle-pack roster this suite must not depend on.
--
-- Lives in server/ WITHOUT an isServer() guard, same as vanilla's own
-- ProfessionVehicles.lua: SP loads server lua too (GameLoadingState.java:155)
-- and vehicle spawning is server-side everywhere - MP clients never load this
-- file and never spawn vehicles (IsoChunk.AddVehicles returns for clients).
--
-- LAYER 1 - map spawns (parking stalls, traffic jams, dealerships, business
-- fleets). IsoChunk.AddVehicles -> VehicleType.getRandomVehicleType -> lazy
-- VehicleType.init() SNAPSHOTS the Lua VehicleZoneDistribution table on the
-- first spawn request of the session (VehicleType.java:147). Entries nil'd
-- before that moment never existed as far as the engine cares. Timing:
-- SandboxOptions.load() runs AFTER OnInitWorld (IsoWorld.java:1784-1787), so
-- the distribution-merge events are too early to read our option;
-- OnLoadedTileDefinitions (IsoWorld.java:1862) is after sandbox is final -
-- fresh world included: the no-save-file path is resetToDefault() +
-- updateFromLua(), i.e. the new-game screen's SandboxVars (with our default
-- true) is authoritative - and well before the first chunk streams in.
-- Lua fully reloads on exit-to-menu (IngameState.java:1052) and
-- VehicleType.Reset() clears the snapshot (:1015), so this re-decides per
-- save; nils can never leak into a world with the option off.
--
-- WHAT COUNTS AS VANILLA: not a name list. An entry is stripped when the
-- script's first loaded body came from mod id "pz-vanilla"
-- (ScriptManager.VanillaID, ScriptManager.java:638 - the engine hard-throws
-- if a workshop mod claims that id). KI5-style packs register vehicles under
-- the Base module too, so a "Base.*" prefix test would strip modded vehicles;
-- the modId test cannot. A replacer mod that overrides a vanilla vehicle
-- keeps pz-vanilla as body zero and stays stripped - correct: it is still
-- the vanilla spawn slot wearing a new skin.
--
-- WHAT SURVIVES, deliberately:
--   * Burnt/Smashed wrecks (incl. racecar, whose only entry is
--     Base.RaceCarBurnt) - scenery, not transport. Vanilla burnt-chance
--     dials stay untouched (trafficjam* 80, junkyard 40) where the donor
--     lowered them; wreck density stays vanilla.
--   * Trailers (farm Trailer/TrailerCover/Trailer_Livestock, TrailerAdvert)
--     - towables, not engines. The donor kept the farm ones too.
--   * Zone KEYS - entries are removed, never a whole zone table.
--     RandomizedWorldBase.addVehicle dereferences the zone type
--     unconditionally even when spawning a hardcoded script
--     (RandomizedWorldBase.java:167/264); a missing key is an NPE there.
--
-- LAYER 2 - story spawns. Randomized stories hardcode scripts - police
-- blockades, ambulance/trailer crashes, camps, sieges
-- (RVSPoliceBlockade.java:55, RZSSurvivalistCamp.java:82, ...) - through
-- addVehicle(scriptName), never consulting the distribution. The sanctioned
-- interception point is OnSpawnVehicleStart, fired once per BRAND-NEW
-- vehicle inside createPhysics (BaseVehicle.java:822); vanilla's own
-- ProfessionVehicles.CheckSwap swaps scripts there with setScriptName +
-- scriptReloaded(true) (spawnSwap=true suppresses re-entry). `created` is
-- serialized (save :2599 / load :2692), so isCreated() cleanly excludes
-- every vehicle loaded from disk - a swap can never re-fire on chunk reload.
-- Vanilla drivables are swapped to their BURNT hulls rather than cancelled:
-- there is no sanctioned way to abort a spawn mid-createPhysics, and a
-- blockade of burnt cruisers still reads as a scene where a missing car
-- would leave loot and zombies floating around nothing. Later
-- setSmashed() calls on a swapped hull no-op harmlessly (burnt scripts have
-- no SmashedCarDefinitions entries). Handler ORDER makes this compose with
-- profession swaps: vanilla CheckSwap registered first, us second - if a
-- swap-to-modded mod (e.g. the donor's stories mod) already redirected the
-- script, the pz-vanilla test fails and we leave it alone.
--
-- SmashedCarDefinitions is deliberately NOT stripped, diverging from the
-- donor: its only consumer is BaseVehicle.setSmashed (BaseVehicle.java:9433),
-- which converts an already-spawned story vehicle INTO its wreck variant.
-- Nil it and crash scenes keep the intact drivable car instead - the donor's
-- second file works against its own goal.
--
-- Staff spawns bypass Layer 2 via the begin/endExempt latch (RCSpawn wraps
-- its addVehicleDebug call): the latch works because OnSpawnVehicleStart
-- fires synchronously inside the spawn call, single Lua thread.

require "RCShared"

RCNoVanilla = RCNoVanilla or {}

-- ---------------------------------------------------------------------------
-- Classification (pure - exercised by tools/tests/test_rcnovanilla.lua)
-- ---------------------------------------------------------------------------

-- Names that stay even when the script is vanilla: wrecks and towables.
-- Lowercased compare, matching the engine's own wreck test
-- (IsoChunk.java:1061 lowercases and looks for burnt/smashed).
function RCNoVanilla.isExemptName(name)
    if type(name) ~= "string" then return true end
    local n = string.lower(name)
    return (string.find(n, "burnt",   1, true)
         or string.find(n, "smashed", 1, true)
         or string.find(n, "trailer", 1, true)) ~= nil
end

-- Burnt hull for a vanilla drivable. Ordered PREFIX match on the short name
-- (module stripped) - longer/specific families before their parents, so
-- PickUpVanLights lands before PickUpVan and ModernCarLights (the B42 modern
-- police liveries) before ModernCar. Every target is core-game and always
-- present. Fallback: the everyman burnt sedan.
local BURNT_MAP = {
    { "PickUpVanLights",   "Base.PickUpVanLightsBurnt" },
    { "PickUpVan",         "Base.PickUpVanBurnt" },
    { "PickUpTruckLights", "Base.PickupSpecialBurnt" },
    { "PickUpTruck",       "Base.PickupBurnt" },
    { "ModernCarLights",   "Base.NormalCarBurntPolice" },
    { "ModernCar02",       "Base.ModernCar02Burnt" },
    { "ModernCar",         "Base.ModernCarBurnt" },
    { "CarLights",         "Base.NormalCarBurntPolice" },
    { "CarTaxi",           "Base.TaxiBurnt" },
    { "CarLuxury",         "Base.LuxuryCarBurnt" },
    { "SmallCar02",        "Base.SmallCar02Burnt" },
    { "SmallCar",          "Base.SmallCarBurnt" },
    { "SportsCar",         "Base.SportsCarBurnt" },
    { "RaceCar",           "Base.RaceCarBurnt" },
    { "SUV",               "Base.SUVBurnt" },
    { "OffRoad",           "Base.OffRoadBurnt" },
    { "VanAmbulance",      "Base.AmbulanceBurnt" },
    { "VanRadio",          "Base.VanRadioBurnt" },
    { "VanSeats",          "Base.VanSeatsBurnt" },
    { "StepVan",           "Base.VanBurnt" },
    { "Van",               "Base.VanBurnt" },
}
local BURNT_DEFAULT = "Base.CarNormalBurnt"

function RCNoVanilla.burntFor(fullName)
    if type(fullName) ~= "string" then return nil end
    local short = fullName
    if string.sub(short, 1, 5) == "Base." then short = string.sub(short, 6) end
    for i = 1, #BURNT_MAP do
        local pat = BURNT_MAP[i][1]
        if string.sub(short, 1, #pat) == pat then return BURNT_MAP[i][2] end
    end
    return BURNT_DEFAULT
end

-- Walk every zone's vehicles table and nil the entries isVanillaFn approves.
-- Two-pass per zone (collect, then remove): never mutate a table mid-pairs.
-- Returns entries removed, zones touched. The resolver is injected so the
-- walker stays engine-free for the test harness.
function RCNoVanilla.strip(dist, isVanillaFn)
    local removed, zones = 0, 0
    if type(dist) ~= "table" then return removed, zones end
    for _, zoneDef in pairs(dist) do
        local vehicles = type(zoneDef) == "table" and zoneDef.vehicles or nil
        if type(vehicles) == "table" then
            local doomed = {}
            for key in pairs(vehicles) do
                if not RCNoVanilla.isExemptName(key) and isVanillaFn(key) then
                    doomed[#doomed + 1] = key
                end
            end
            if #doomed > 0 then
                for i = 1, #doomed do vehicles[doomed[i]] = nil end
                removed = removed + #doomed
                zones = zones + 1
            end
        end
    end
    return removed, zones
end

-- ---------------------------------------------------------------------------
-- Engine-side resolvers
-- ---------------------------------------------------------------------------

-- Body zero of a script is (modId, body) pair zero - who defined it first.
local function scriptIsVanilla(script)
    local ok, vanilla = pcall(function()
        local bodies = script:getLoadedScriptBodies()
        return bodies ~= nil and bodies:size() >= 1 and bodies:get(0) == "pz-vanilla"
    end)
    return ok and vanilla == true
end

-- Zone keys are script names. Vanilla ships one unprefixed key
-- ("PickUpTruckLightsRanger" in the ranger zone), so retry under the Base
-- module when the bare name doesn't resolve. Unresolvable entries are left
-- alone - they can never spawn anyway.
function RCNoVanilla.isVanillaScriptName(name)
    if type(name) ~= "string" then return false end
    local script
    pcall(function() script = getScriptManager():getVehicleScript(name) end)
    if not script and not string.find(name, ".", 1, true) then
        pcall(function() script = getScriptManager():getVehicleScript("Base." .. name) end)
    end
    if not script then return false end
    return scriptIsVanilla(script)
end

-- ---------------------------------------------------------------------------
-- Staff-spawn latch (Layer 2 bypass). Counter, not boolean: nesting-safe.
-- ---------------------------------------------------------------------------
local exemptDepth = 0
function RCNoVanilla.beginExempt() exemptDepth = exemptDepth + 1 end
function RCNoVanilla.endExempt() exemptDepth = math.max(0, exemptDepth - 1) end

-- ---------------------------------------------------------------------------
-- Layer 1: strip the zone distribution once sandbox is final
-- ---------------------------------------------------------------------------
local function applyZoneStrip()
    local c = RCShared.cfg()
    if not (c.enabled and c.noVanillaVehicles) then return end
    if type(VehicleZoneDistribution) ~= "table" then return end
    local removed, zones = RCNoVanilla.strip(
        VehicleZoneDistribution, RCNoVanilla.isVanillaScriptName)
    -- One line, always: this decides what a fresh world looks like, and the
    -- dedi log is where that gets audited after the fact.
    print(string.format(
        "[RC] NoVanilla: stripped %d vanilla map-spawn entries across %d zones",
        removed, zones))
end

Events.OnLoadedTileDefinitions.Add(applyZoneStrip)

-- ---------------------------------------------------------------------------
-- Layer 2: burn the story spawns
-- ---------------------------------------------------------------------------
local function onSpawnVehicleStart(vehicle)
    if exemptDepth > 0 then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.noVanillaStories) then return end
    if not vehicle then return end
    -- created is persisted: true here means loaded-from-disk, never touch.
    local ok, created = pcall(function() return vehicle:isCreated() end)
    if not ok or created then return end
    local script
    pcall(function() script = vehicle:getScript() end)
    if not script then return end
    local full
    pcall(function() full = script:getFullName() end)
    if type(full) ~= "string" then return end
    if RCNoVanilla.isExemptName(full) then return end
    if not scriptIsVanilla(script) then return end
    local swap = RCNoVanilla.burntFor(full)
    if not swap or swap == full then return end
    -- The CheckSwap idiom: rename, then rebuild physics/model/parts with
    -- spawnSwap=true so this event does not re-fire.
    local swapped = pcall(function()
        vehicle:setScriptName(swap)
        vehicle:scriptReloaded(true)
    end)
    if swapped then
        RCShared.dbg("NoVanilla: story spawn %s -> %s", full, swap)
    end
end

Events.OnSpawnVehicleStart.Add(onSpawnVehicleStart)
