-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- LAYER 2 - story spawns. NOTE THE TRAP FIRST: OnSpawnVehicleStart is not a
-- story event and never was. It fires for EVERY brand-new vehicle, map spawns
-- included, so this layer needs its own story test (the zone check at the
-- handler) or it burns the whole vanilla fleet. It shipped without one and did
-- exactly that. Randomized stories hardcode scripts - police
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
-- THE VANILLA ZONE SET, derived from the game's own VehicleZoneDefinition.lua
-- rather than transcribed: every `VehicleZoneDistribution.<key>` it declares,
-- 55 of them. Written out because it cannot be computed at runtime - by the
-- time we run, mods have already added their zones to the same table and the
-- two are indistinguishable by inspection.
--
-- WHY IT MATTERS (adopted 2026-08-03 from the convention two vehicle-mod
-- libraries follow independently). A zone a mod DEFINED is that author's
-- curated spawn list, and any vanilla entries in it are there on purpose.
-- Stripping them is both rude and destructive - it can empty a zone the author
-- balanced, which is the permanently-failing-spawn-site state that backfill
-- exists to prevent. So the strip stays inside vanilla's own zones.
--
-- Note the entries the donor NoVanillaVehicles pair (workshop 2535461640) is
-- missing and this is not: racecar, all four trafficjam* variants, and
-- business2 through business12.
local VANILLA_ZONES = {}
for _, z in ipairs{
    "advertising", "airportservice", "airportshuttle", "ambulance", "bad",
    "business", "business2", "business3", "business4", "business5", "business6",
    "business7", "business8", "business9", "business10", "business11",
    "business12", "carpenter", "delivery", "evacuee", "farm", "fire", "fossoil",
    "good", "junkyard", "knoxdisti", "kyheralds", "lectromax", "luxuryDealership",
    "massgenfac", "mccoy", "medium", "middleClass", "network3", "normalburnt",
    "parkingstall", "police", "postal", "prison", "professional", "racecar",
    "radio", "ranger", "scarlet", "specialburnt", "spiffo", "sport",
    "struggling", "trades", "trafficjame", "trafficjamn", "trafficjams",
    "trafficjamw", "trailerpark", "transit",
} do VANILLA_ZONES[z] = true end

RCNoVanilla.VANILLA_ZONES = VANILLA_ZONES

-- Returns removed, zones, skipped. `skipped` counts modded zones left alone,
-- and is reported at boot so "it stripped less than I expected" has an answer
-- in the log instead of needing a bug report.
function RCNoVanilla.strip(dist, isVanillaFn)
    local removed, zones, skipped = 0, 0, 0
    if type(dist) ~= "table" then return removed, zones, skipped end
    for zoneName, zoneDef in pairs(dist) do
        local vehicles = type(zoneDef) == "table" and zoneDef.vehicles or nil
        if type(vehicles) == "table" and not VANILLA_ZONES[zoneName] then
            skipped = skipped + 1
        elseif type(vehicles) == "table" then
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
    return removed, zones, skipped
end

-- BACKFILL - repopulate the zones the strip emptied (2026-08-03).
--
-- WHY THIS IS NOT OPTIONAL. Removing a zone's last entry does NOT make that
-- zone inert, which is the trap. VehicleType.init() registers the zone anyway
-- (VehicleType.java:74, `vehicles.put(zoneType, type)` runs regardless of how
-- many cars the list ended up with), so hasTypeForZone keeps answering TRUE and
-- every spawn attempt reaches RandomizeModel, which bails at
--
--     if (type.vehiclesDefinition.isEmpty())
--         System.out.println("no vehicle definition found for " + name);
--
-- (IsoChunk.java:1316). So a stripped-empty zone is a permanently failing spawn
-- site, not an absent one: the map produces no cars AND logs about it forever.
-- That is exactly the "suppress everything and the world has nothing" state.
--
-- WHAT GOES IN. RCNoVanilla.roster(true) - the modded, non-wreck, non-trailer
-- scripts that actually resolve in the ScriptManager. Two fields per entry,
-- both verified against the parser at VehicleType.java:69:
--
--   index       SKIN index. -1 means "roll a random skin" (IsoChunk.java:1335
--               takes setSkinIndex(index) only when index > -1). Anything else
--               would pin every backfilled car to one paint job.
--   spawnChance NORMALISED by the engine - it computes 100/sum and rescales
--               (VehicleType.java:72-79) - so equal values give equal share and
--               there are no weights to invent here.
--
-- ONLY EMPTY ZONES. A zone that still holds entries after the strip is one a
-- vehicle mod populated itself, and its author's weights are a better answer
-- than ours. Filling those too would drown their curation in the whole roster.
-- This rule is also self-limiting for wrecks: burnt/smashed zones survive the
-- strip via isExemptName, so they are never empty and never backfilled.
--
-- Roster injected as a parameter, same as strip() takes its resolver, so the
-- walker stays engine-free for the test harness.
-- Returns entries added, zones filled.
function RCNoVanilla.backfill(dist, roster)
    local added, zones = 0, 0
    if type(dist) ~= "table" or type(roster) ~= "table" or #roster == 0 then
        return added, zones
    end
    for _, zoneDef in pairs(dist) do
        local vehicles = type(zoneDef) == "table" and zoneDef.vehicles or nil
        if type(vehicles) == "table" then
            local empty = true
            for _ in pairs(vehicles) do empty = false; break end
            if empty then
                for i = 1, #roster do
                    vehicles[roster[i]] = { index = -1, spawnChance = 1 }
                    added = added + 1
                end
                zones = zones + 1
            end
        end
    end
    return added, zones
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

    local function filter(names)
        local out = {}
        for i = 1, #(names or {}) do
            local n = names[i]
            if not RCNoVanilla.isExemptName(n) then
                if not (moddedOnly and RCNoVanilla.isVanillaScriptName(n)) then
                    -- Must actually resolve: a distribution key for a mod that
                    -- is no longer installed would otherwise reach RCSpawn as a
                    -- "badmodel" failure on every attempt.
                    local script
                    pcall(function() script = getScriptManager():getVehicle(n) end)
                    if script then out[#out + 1] = n end
                end
            end
        end
        return out
    end

    -- FALL BACK ON AN EMPTY RESULT, not merely on a nil source. The
    -- distribution can be non-empty and still yield nothing usable: after a
    -- full strip on a server whose vehicle mods do not register themselves into
    -- VehicleZoneDistribution, the only surviving keys are burnt hulls and
    -- trailers - every one of which isExemptName then removes. The old
    -- `rosterFromDistribution() or rosterFromScripts()` saw a non-nil first
    -- source, never consulted the second, and produced an empty roster on
    -- exactly the server that most needs one.
    local out = filter(rosterFromDistribution())
    if #out == 0 then out = filter(rosterFromScripts()) end

    rosterCache, rosterModded = out, moddedOnly
    print(string.format("[RC] NoVanilla: lifecycle roster = %d vehicle(s) (%s)",
        #out, moddedOnly and "modded only" or "all"))
    return out
end

function RCNoVanilla.clearRoster() rosterCache = nil end

-- CONTEXT-APPROPRIATE SELECTION (2026-08-03).
--
-- A flat roster puts a fire truck in a suburban driveway. VVR solves this with
-- IsoGridSquare:getSquareRegion() (:9237, the zone of type "Region" covering a
-- square) indexing a hand-authored region -> vehicle table. We do not have that
-- table and building one is content work - but we do not need it, because the
-- game already ships a finer-grained answer: VehicleZoneDistribution is keyed
-- by ZONE, and a parking stall's zone name IS its character ("police", "farm",
-- "spiffo", "luxuryDealership"). Zone beats region here because the mapping
-- already exists and is a tighter fit.
--
-- Reachable because Zone:getName() is a METHOD (Zone.java:486); we get the
-- zone object straight off the tile the placer chose.
--
-- Falls back to the global roster when the tile has no zone, when the zone
-- holds nothing usable, or when the zone is one whose flavour we would not want
-- to concentrate. Never returns an empty list without saying so - the caller
-- treats nil as "use the general roster".
function RCNoVanilla.rosterForZone(zoneName, moddedOnly)
    if type(zoneName) ~= "string" or zoneName == "" then return nil end
    if type(VehicleZoneDistribution) ~= "table" then return nil end
    -- LOWERCASE, because the engine does: VehicleType.hasTypeForZone and
    -- getRandomVehicleType both call zoneName.toLowerCase() before the lookup
    -- (VehicleType.java:137). It matters far more than it looks - 7,663 of the
    -- base map's 9,693 ParkingStall zones carry no name at all, and
    -- IsoChunk.AddVehicles substitutes the zone TYPE for an empty name, so the
    -- string arriving here is literally "ParkingStall" while the distribution
    -- key is "parkingstall". A raw lookup silently misses four fifths of the
    -- map's parking and falls back to the general roster every time.
    local zoneDef = VehicleZoneDistribution[string.lower(zoneName)]
    local vehicles = type(zoneDef) == "table" and zoneDef.vehicles or nil
    if type(vehicles) ~= "table" then return nil end

    moddedOnly = moddedOnly ~= false
    local out = {}
    for name in pairs(vehicles) do
        -- Same three gates the general roster applies: no wrecks, no trailers,
        -- optionally no vanilla, and it must actually resolve.
        if type(name) == "string" and not RCNoVanilla.isExemptName(name) then
            if not (moddedOnly and RCNoVanilla.isVanillaScriptName(name)) then
                local script
                pcall(function() script = getScriptManager():getVehicle(name) end)
                if script then out[#out + 1] = name end
            end
        end
    end
    if #out == 0 then return nil end
    return out
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

    -- ACCOUNT FOR THE NO-OP, always. This used to return in silence, which
    -- makes "the option is off" and "the pass crashed" look identical in a
    -- log - and the only way to tell them apart was to go read SandboxVars.
    -- One line at boot removes that ambiguity permanently. Deliberately print
    -- and not dbg(): Debug is off on every real server, which is exactly where
    -- the question gets asked.
    if not (c.enabled and c.noVanillaVehicles) then
        print(string.format(
            "[RC] NoVanilla: map-spawn suppression OFF (%s) - vanilla vehicles spawn normally",
            (not c.enabled) and "mod disabled" or "NoVanillaVehicles = false"))
        return
    end
    if type(VehicleZoneDistribution) ~= "table" then
        print("[RC] NoVanilla: VehicleZoneDistribution missing - nothing to strip")
        return
    end
    local removed, zones, skipped = RCNoVanilla.strip(
        VehicleZoneDistribution, RCNoVanilla.isVanillaScriptName)
    -- One line, always: this decides what a fresh world looks like, and the
    -- dedi log is where that gets audited after the fact.
    print(string.format(
        "[RC] NoVanilla: stripped %d vanilla map-spawn entries across %d zones"
        .. " (%d modded zone(s) left to their authors)",
        removed, zones, skipped))

    -- Backfill IMMEDIATELY after, inside the same OnLoadedTileDefinitions
    -- window - the last moment before VehicleType.init() snapshots the table on
    -- the first spawn request (VehicleType.java:147). Miss this window and the
    -- edit is decorative: the engine is already working from its own copy.
    --
    -- Unconditional, with no sandbox dial of its own, because a zone the strip
    -- emptied is BROKEN rather than merely quiet (see backfill's header) - and
    -- an admin who wants no cars at all gets that for free: with no vehicle
    -- mods installed the roster is empty and this is a no-op.
    local added, filled = RCNoVanilla.backfill(
        VehicleZoneDistribution, RCNoVanilla.roster(true))
    if filled > 0 then
        print(string.format(
            "[RC] NoVanilla: backfilled %d modded entr(ies) into %d emptied zone(s)",
            added, filled))
    elseif zones > 0 then
        -- Stripped something but filled nothing. Either every zone still holds
        -- a modded entry (fine, mod authors curated them) or there are no
        -- modded vehicles installed at all (the map will now spawn no cars).
        -- Worth one line either way: this is the state that reads as "the mod
        -- broke my world" if it is not stated.
        print("[RC] NoVanilla: no zone needed backfilling"
            .. " (mods populate their own, or none are installed)")
    end
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
--
-- MINTS A REPLACEMENT TOKEN PER REMOVAL (2026-08-03). Until this, purge and
-- RCRespawn were two systems that never spoke: an admin could empty the map of
-- vanilla cars and then wait forever, because the pool the respawner spends
-- from was still zero. That made the retrofit a ONE-WAY DOOR, which is the
-- opposite of what the pair is for - the whole premise is replacing the vanilla
-- fleet with a modded one, not deleting it.
--
-- A purged car is a vehicle that left the world exactly like a reclaimed one,
-- so it funds a replacement exactly like one. Admins who want removal WITHOUT
-- replacement already have the levers and need no third one here: RespawnEnabled
-- off stops placement entirely, and RespawnPerSweep 0 banks the tokens for later
-- without spending any.
--
-- Category is always "vehicle": trailers and wrecks never reach here, because
-- retrofitVerdict returns "exempt" for them via isExemptName.
--
-- Returns removed, dumped, minted.
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

    local removed, dumped, minted = 0, 0, 0
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
            -- Minted only on a CONFIRMED removal, inside the same branch as the
            -- count. A token for a car still standing would inflate the fleet.
            if RCRegistry and RCRegistry.addToken then
                if pcall(RCRegistry.addToken, "vehicle") then minted = minted + 1 end
            end
            RCAudit.log("NOVANILLA-PURGE", nil, { vehicle = name, x = x, y = y })
        end
    end
    if removed > 0 then
        local tv = RCRegistry and RCRegistry.tokens and RCRegistry.tokens() or 0
        print(string.format(
            "[RC] NoVanilla retrofit: removed %d vanilla vehicle(s), %d item(s) dumped, %d token(s) minted (pool now %d)",
            removed, dumped, minted, tv))
    end
    return removed, dumped, minted
end

local function onSpawnVehicleStart(vehicle)
    if exemptDepth > 0 then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.noVanillaStories) then return end
    if not vehicle then return end
    -- created is persisted: true here means loaded-from-disk, never touch.
    local ok, created = pcall(function() return vehicle:isCreated() end)
    if not ok or created then return end

    -- THE STORY TEST - and the bug this file shipped without it (2026-08-03).
    --
    -- OnSpawnVehicleStart is NOT a story event. BaseVehicle.java:822 triggers it
    -- inside createPhysics for EVERY brand-new vehicle, which includes every car
    -- IsoChunk.AddVehicles puts in a parking stall, traffic jam or dealership.
    -- Without this check the handler burnt the entire vanilla map fleet, and did
    -- it most visibly when Layer 1 was OFF - because then the zones still had
    -- vanilla cars to spawn and every one of them arrived here and left as a
    -- husk. A world of nothing but burnt-out shells, from the option that was
    -- supposed to be the gentle one.
    --
    -- The discriminator is the ZONE, and it reads inverted from what you would
    -- guess: a zone spawn HAS one, a story spawn does not.
    --   * IsoChunk.AddVehicles_OnZone calls v.setZone(zoneName) at :1030, before
    --     RandomizeModel sets the script - so it is already set by the time
    --     createPhysics fires here.
    --   * RandomizedWorldBase.addVehicle (all overloads) sets script, direction
    --     and position but NEVER calls setZone - the zoneName argument it takes
    --     only picks a VehicleType, it is not stamped on the vehicle.
    -- So "no zone" means the spawn bypassed the distribution, which is exactly
    -- the population this layer exists for. Staff spawns also have no zone and
    -- are covered separately by the exemptDepth latch above.
    local zone
    pcall(function() zone = vehicle:getZone() end)
    if zone ~= nil and zone ~= "" then return end   -- map spawn: not ours

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
        RCShared.dbg("NoVanilla: zoneless (story) spawn %s -> %s", full, swap)
    end
end

Events.OnSpawnVehicleStart.Add(onSpawnVehicleStart)

-- ---------------------------------------------------------------------------
-- Layer 4: convert vanilla vehicles ALREADY IN THE SAVE, in place.
--
-- THE FACT THIS RESTS ON, verified in the decompile rather than assumed:
-- OnSpawnVehicleStart is not only a spawn event. IsoChunk.doLoadGridsquare
-- (:3373) walks the chunk's saved vehicles and calls v.addToWorld() for each
-- one not yet added (:3441), addToWorld calls createPhysics() (:7091), and that
-- no-arg overload passes spawnSwap = false - so the event fires (:821-822) for
-- every vehicle streaming in off disk. The whole path sits behind
-- !GameClient.client, i.e. server-side only, which matches this file's gating.
--
-- isCreated() is the discriminator and it is serialized (:2599/:2692): FALSE
-- means brand-new (Layer 2's population), TRUE means loaded from the save -
-- this layer's.
--
-- WHY THIS IS BETTER THAN THE PURGE. The retrofit we shipped first removes the
-- car with permanentlyRemove, dumps its contents on the ground, mints a token
-- and places a different car somewhere else entirely. This renames the script
-- underneath the same vehicle object: it keeps its position, its condition, its
-- blood and rust, and it costs nothing. No token economy, no admin sweep, no
-- irreversible deletion. The purge remains for the cases this cannot touch.
--
-- WHAT IT REFUSES TO TOUCH, and why that is stricter than the mod this idea
-- came from. scriptReloaded rebuilds the part list (BaseVehicle.java:1628-1632
-- clears every part's inventory item), so a swap can lose what is IN the car.
-- Reference implementations restore fluid amounts and accept the rest. We
-- simply do not convert a vehicle that holds anything: an untouched background
-- car becomes modded, a car someone has loaded with loot is left exactly as it
-- is. Eligibility otherwise reuses retrofitVerdict, so claimed, occupied,
-- safehoused and recently-used cars are spared by the same Presence Law that
-- governs the Janitor - one implementation, not two.
-- ---------------------------------------------------------------------------

-- Is every container on this vehicle empty? Cheap: most vehicles have two or
-- three container parts and we stop at the first item found.
local function holdsNothing(vehicle)
    local empty = true
    pcall(function()
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part and part:isContainer() then
                local cont = part:getItemContainer()
                if cont and cont:getItems() and cont:getItems():size() > 0 then
                    empty = false
                    return
                end
            end
        end
    end)
    return empty
end

-- Per-part condition, keyed by part id, plus the body-wide cosmetics. Captured
-- BEFORE the swap because scriptReloaded rebuilds the parts.
local function captureState(vehicle)
    local s = { parts = {}, n = 0, total = 0 }
    pcall(function()
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part then
                local cond = part:getCondition()
                if cond then
                    s.parts[part:getId()] = cond
                    s.n, s.total = s.n + 1, s.total + cond
                end
            end
        end
    end)
    pcall(function() s.rust = vehicle:getRust() end)
    pcall(function()
        s.blood = {
            Front = vehicle:getBloodIntensity("Front"),
            Rear  = vehicle:getBloodIntensity("Rear"),
            Left  = vehicle:getBloodIntensity("Left"),
            Right = vehicle:getBloodIntensity("Right"),
        }
    end)
    return s
end

-- Put it back on the NEW part list, and transmit. The transmit calls are not
-- optional here the way they are in Layer 2: that layer runs on a vehicle no
-- client has seen yet, whereas this one edits a car that is streaming in to
-- players right now. Without them clients keep the pre-swap appearance.
local function restoreState(vehicle, s)
    local avg = (s.n > 0) and (s.total / s.n) or nil
    pcall(function()
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part then
                local cond = s.parts[part:getId()] or avg
                if cond then
                    part:setCondition(math.floor(cond))
                    vehicle:transmitPartCondition(part)
                end
            end
        end
    end)
    if s.rust then pcall(function() vehicle:setRust(s.rust); vehicle:transmitRust() end) end
    if s.blood then
        pcall(function()
            for side, amount in pairs(s.blood) do
                if amount then vehicle:setBloodIntensity(side, amount) end
            end
            vehicle:transmitBlood()
        end)
    end
    -- A modded script has its own skin list, so the old index means nothing.
    -- Roll a valid one rather than leaving every converted car on skin 0.
    pcall(function()
        local script = getScriptManager():getVehicle(vehicle:getScriptName())
        local count = script and script:getSkinCount() or 0
        if count > 1 then
            vehicle:setSkinIndex(ZombRand(count))
            vehicle:transmitSkinIndex()
        end
    end)
end

RCNoVanilla.retrofitted = 0   -- session counter, for the boot/status line

local function retrofitLoaded(vehicle)
    if exemptDepth > 0 then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.noVanillaRetrofit) then return end
    if not vehicle then return end

    -- Loaded-from-disk only. Brand-new vehicles are Layers 1 and 2' business.
    local ok, created = pcall(function() return vehicle:isCreated() end)
    if not ok or not created then return end

    -- One implementation of "may this vanilla car be replaced", shared with the
    -- admin purge (see retrofitVerdict's header).
    if retrofitVerdict(vehicle) ~= "purge" then return end
    if not holdsNothing(vehicle) then return end

    local full
    pcall(function() full = vehicle:getScript():getFullName() end)
    if type(full) ~= "string" then return end

    -- Prefer the zone's own list so a police car becomes a modded police car,
    -- exactly as the placer does.
    local zoneName
    pcall(function() zoneName = vehicle:getZone() end)
    local pick = (zoneName and RCNoVanilla.rosterForZone(zoneName, true))
        or RCNoVanilla.roster(true)
    if not pick or #pick == 0 then return end
    local swap = pick[ZombRand(#pick) + 1]
    if not swap or swap == full then return end

    local state = captureState(vehicle)
    local done = pcall(function()
        vehicle:setScriptName(swap)
        vehicle:scriptReloaded(true)   -- true: do not re-enter this event
    end)
    if not done then return end
    restoreState(vehicle, state)

    RCNoVanilla.retrofitted = RCNoVanilla.retrofitted + 1
    RCAudit.log("RETROFIT", nil, {
        from = full, to = swap, zone = tostring(zoneName or "-"),
        x = math.floor(vehicle:getX()), y = math.floor(vehicle:getY()),
    })
    RCShared.dbg("NoVanilla: retrofit %s -> %s in place", full, swap)
end

Events.OnSpawnVehicleStart.Add(retrofitLoaded)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
