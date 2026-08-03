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

-- Zone keys are script names. The lookup is getVehicle (ScriptManager.java:831)
-- - there is no getVehicleScript on ScriptManager in 42.20, and naming it that
-- made this function return false for EVERY key, so Layer 1 stripped nothing.
-- Vanilla ships one unprefixed key ("PickUpTruckLightsRanger" in the ranger
-- zone) and getVehicle resolves a dotless name against the Base module on its
-- own (ScriptBucketCollection.java:78-88), so one lookup covers both forms.
-- Unresolvable entries are left alone - they can never spawn anyway.
function RCNoVanilla.isVanillaScriptName(name)
    if type(name) ~= "string" then return false end
    local script
    pcall(function() script = getScriptManager():getVehicle(name) end)
    if not script then return false end
    return scriptIsVanilla(script)
end

-- ---------------------------------------------------------------------------
-- THE ROSTER - "what may the lifecycle spawn?" (the owner's second
-- never-spawn-vanilla function, 2026-08-03).
--
-- Layers 1 and 2 above stop the WORLD spawning vanilla cars. This stops US
-- doing it: when the respawner puts a replacement down it picks from here, so
-- a server running car mods never has its own lifecycle quietly reintroducing
-- the fleet the admin just suppressed.
--
-- SOURCE: VehicleZoneDistribution, not getAllVehicleScripts(). Both would
-- answer "which vehicles exist", but only the distribution answers "which
-- vehicles is this world configured to contain" - it carries the mod authors'
-- own spawn weights and excludes scripts that were never meant to appear on
-- their own. Better still, applyZoneStrip has already run against it by the
-- time anything asks, so on a NoVanilla server the vanilla entries are simply
-- gone and the modded-only filter below has nothing left to do. The filter
-- stays anyway, because the two options are independent dials: an admin may
-- run the lifecycle with map suppression off.
--
-- getAllVehicleScripts() is the fallback for a world with no distribution
-- table at all. It is deliberately second: it happily returns trailers,
-- wrecks and abstract parent scripts, which is why the exempt-name filter
-- runs over both paths rather than only over the fallback.
-- ---------------------------------------------------------------------------
local rosterCache, rosterModded

-- Every distinct vehicle name the distribution can spawn.
local function rosterFromDistribution()
    if type(VehicleZoneDistribution) ~= "table" then return nil end
    local seen, out = {}, {}
    for _, zoneDef in pairs(VehicleZoneDistribution) do
        local vehicles = type(zoneDef) == "table" and zoneDef.vehicles or nil
        if type(vehicles) == "table" then
            for key in pairs(vehicles) do
                if type(key) == "string" and not seen[key] then
                    seen[key] = true
                    out[#out + 1] = key
                end
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function rosterFromScripts()
    local out = {}
    pcall(function()
        local list = getScriptManager():getAllVehicleScripts()
        if not list then return end
        for i = 0, list:size() - 1 do
            local s = list:get(i)
            local full
            if s then pcall(function() full = s:getFullName() end) end
            if type(full) == "string" then out[#out + 1] = full end
        end
    end)
    if #out == 0 then return nil end
    return out
end

-- Spawnable names for the lifecycle. moddedOnly drops anything whose script
-- body zero is pz-vanilla. Wrecks and trailers are dropped either way: a
-- replacement is meant to be transport, and isExemptName already encodes
-- exactly that distinction for Layers 1 and 2.
--
-- Cached per moddedOnly value. Vehicle scripts and the distribution are both
-- fixed for a session, so rebuilding would burn a ScriptManager walk per
-- placement for an answer that cannot have changed.
function RCNoVanilla.roster(moddedOnly)
    moddedOnly = moddedOnly ~= false
    if rosterCache and rosterModded == moddedOnly then return rosterCache end

    local names = rosterFromDistribution() or rosterFromScripts() or {}
    local out = {}
    for i = 1, #names do
        local n = names[i]
        if not RCNoVanilla.isExemptName(n) then
            if not (moddedOnly and RCNoVanilla.isVanillaScriptName(n)) then
                -- Must actually resolve: a distribution key for a mod that is
                -- no longer installed would otherwise reach RCSpawn as a
                -- "badmodel" failure on every attempt.
                local script
                pcall(function() script = getScriptManager():getVehicle(n) end)
                if script then out[#out + 1] = n end
            end
        end
    end

    rosterCache, rosterModded = out, moddedOnly
    print(string.format("[RC] NoVanilla: lifecycle roster = %d vehicle(s) (%s)",
        #out, moddedOnly and "modded only" or "all"))
    return out
end

function RCNoVanilla.clearRoster() rosterCache = nil end

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
-- ---------------------------------------------------------------------------
-- LAYER 3 - the RETROFIT cleanup pass (2026-08-03).
--
-- WHY THIS IS NOT ABOUT FRESH SAVES. Layer 1 strips the distribution at
-- OnLoadedTileDefinitions, which is after sandbox is final and BEFORE the
-- first chunk streams in, and VehicleType.init() snapshots the table lazily on
-- the first spawn request (VehicleType.java:147). On a fresh save there is
-- therefore no window at all - not even the starting cell - in which a vanilla
-- car can be generated. Nothing here is needed for a new world.
--
-- What Layer 1 CANNOT do is un-generate the past. Switch NoVanilla on for a
-- save that has been played, and every chunk already visited has its vanilla
-- cars written to disk; they will keep loading forever because generation
-- already happened. That is the only hole, and this is the patch for it.
--
-- ADMIN-TRIGGERED, SURVEY FIRST. This deletes player-visible world objects, so
-- it never runs on its own. survey() reports; purge() acts, and only when
-- asked a second time. The honesty that matters: BOTH only see vehicles that
-- are currently STREAMED IN. B42 exposes no enumerator for unloaded vehicles
-- (the same wall RCRegistry.pruneOrphans documents), so a full retrofit means
-- running this while travelling, not once from spawn. survey() reports the
-- loaded count precisely so that limit is visible rather than implied.
--
-- WHAT IT SPARES, matching Layers 1 and 2 exactly - wrecks and trailers
-- (isExemptName), plus four protections the spawn-side layers never need:
-- claimed cars, occupied cars, safehouse cars, and cars still held by the
-- Presence Law. A retrofit sweep must not be a way to delete the fleet players
-- are actually driving.
-- ---------------------------------------------------------------------------

-- Classify one loaded vehicle for the retrofit. Returns a reason string:
--   "notvanilla" | "exempt" | "claimed" | "occupied" | "safehouse" | "held"
--   | "purge"
local function retrofitVerdict(vehicle)
    local script, full
    if not pcall(function() script = vehicle:getScript() end) or not script then
        return "notvanilla"
    end
    pcall(function() full = script:getFullName() end)
    if type(full) ~= "string" then return "notvanilla" end
    if not scriptIsVanilla(script) then return "notvanilla" end
    if RCNoVanilla.isExemptName(full) then return "exempt" end

    if RCClaim and RCClaim.isClaimed(vehicle) then return "claimed" end

    local occupied = false
    pcall(function()
        local seats = vehicle:getScript():getPassengerCount() or 0
        for s = 0, seats - 1 do
            if vehicle:isSeatOccupied(s) then occupied = true; return end
        end
    end)
    if occupied then return "occupied" end

    local sheltered = false
    pcall(function() sheltered = SafeHouse.getSafeHouse(vehicle:getSquare()) ~= nil end)
    if sheltered then return "safehouse" end

    -- The Presence Law, borrowed from the Janitor: a car attributed to someone
    -- who still logs in is their car, whatever script it happens to run.
    local user
    pcall(function() user = vehicle:getModData()["RC_LastUser"] end)
    if user then
        local days = RCShared.cfg().janitorDays
        local seen = RCRegistry and RCRegistry.lastSeenAny(user)
        if seen and days and days > 0 and (os.time() - seen) <= days * 86400 then
            return "held"
        end
    end

    return "purge"
end

local function forEachLoadedVehicle(fn)
    local cell = getCell and getCell()
    if not cell then return end
    local vs = cell:getVehicles()
    if not vs then return end
    -- Set, not List: get(i) crashes, :iterator() is the supported path.
    local ok, it = pcall(function() return vs:iterator() end)
    if not ok or not it then return end
    while it:hasNext() do
        local v = it:next()
        if v then pcall(fn, v) end
    end
end

-- Read-only census of what a purge would do. Writes nothing.
function RCNoVanilla.survey()
    local out = { loaded = 0, purge = 0, exempt = 0, claimed = 0,
                  occupied = 0, safehouse = 0, held = 0, notvanilla = 0, sample = {} }
    forEachLoadedVehicle(function(v)
        out.loaded = out.loaded + 1
        local verdict = retrofitVerdict(v)
        out[verdict] = (out[verdict] or 0) + 1
        if verdict == "purge" and #out.sample < 12 then
            out.sample[#out.sample + 1] = {
                name = v:getScriptName(),
                x = math.floor(v:getX()), y = math.floor(v:getY()),
            }
        end
    end)
    return out
end

-- Remove up to `budget` vanilla cars. Loot is dumped to the ground first - the
-- suite never vaporizes loot, and a retrofit is exactly the moment a player
-- would lose a stash they did not know was at risk.
function RCNoVanilla.purge(budget)
    budget = tonumber(budget) or 25
    local doomed = {}
    -- Collect first, remove after: permanentlyRemove() mutates the cell's
    -- vehicle Set, and mutating it mid-iterator is the crash this codebase
    -- already learned about the hard way.
    forEachLoadedVehicle(function(v)
        if #doomed < budget and retrofitVerdict(v) == "purge" then
            doomed[#doomed + 1] = v
        end
    end)

    local removed, dumped = 0, 0
    for i = 1, #doomed do
        local v = doomed[i]
        local name, x, y = "?", 0, 0
        pcall(function()
            name = v:getScriptName()
            x, y = math.floor(v:getX()), math.floor(v:getY())
        end)
        local okDump, n = pcall(RCShared.dumpVehicleContainers, v)
        if okDump and type(n) == "number" then dumped = dumped + n end
        if pcall(function() v:permanentlyRemove() end) then
            removed = removed + 1
            RCAudit.log("NOVANILLA-PURGE", nil, { vehicle = name, x = x, y = y })
        end
    end
    if removed > 0 then
        print(string.format(
            "[RC] NoVanilla retrofit: removed %d vanilla vehicle(s), %d item(s) dumped",
            removed, dumped))
    end
    return removed, dumped
end

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
