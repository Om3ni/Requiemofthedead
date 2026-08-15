-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCParking - "where may a car legally stand?" (server only).
--
-- The lifecycle respawner needs somewhere to put a car, and the owner's rule
-- is blunt: valid parking spots only, NEVER in grass. The engine already knows
-- where those are, so this file resolves that knowledge rather than inventing
-- a heuristic on top of it.
--
-- THE ORACLE. Map zones typed "Vehicle" or "ParkingStall" are both built into
-- VehicleZone objects (IsoMetaGrid.java:556 and :728 - two call sites, one
-- class), and IsoMetaGrid.getVehicleZoneAt(x,y,z) answers the point question
-- directly. That single call IS the never-in-grass gate: a tile with no
-- VehicleZone over it is not a parking spot, full stop.
--
-- We are deliberately STRICTER THAN VANILLA here. The engine's own placement
-- test, IsoChunk.doSpawnedVehiclesInInvalidPosition (:1244), reads:
--
--     if (vehicleZone == null && !sq.isOutside()) return false;
--
-- i.e. a missing zone only disqualifies a square that is INDOORS - any outdoor
-- square is fair game to vanilla. That is how traffic jams get strewn along
-- roads and how the occasional car ends up on a lawn. Requiring a zone hit
-- removes exactly that latitude, which is the whole point of the rule.
--
-- WHY THERE IS NO ZONE INDEX, and why the first version of this file was
-- wrong (corrected 2026-08-03 after it shipped and reported "probe mode" on a
-- live server). The obvious optimisation is to walk IsoMetaGrid's list of
-- every vehicle zone once and bucket it for cheap radius queries. That list
-- exists - `vehiclesZones`, IsoMetaGrid.java:127 - and it is public. It is
-- also an INSTANCE FIELD, and Kahlua does not expose those:
--
--   * exposeStatics (LuaJavaClassExposer.java:283) walks clazz.getFields() but
--     skips anything failing isStatic (:298), so only STATIC fields land in
--     Lua, as globals on the class table.
--   * exposeMethods (:314) walks getMethods() only. No instance field ever
--     becomes readable.
--
-- So `metaGrid.vehiclesZones` is nil from Lua and always was. Nor is there a
-- method route: getZonesIntersecting (:221) delegates to the cell's GENERAL
-- zone structures, while registerVehiclesZone (:727-738) appends only to
-- `vehiclesZones` and `metaCell.vehicleZones` - it never calls addZone. Bulk
-- enumeration of parking zones is simply not reachable from Lua in 42.20.
--
-- The lesson worth keeping: "the field is public" is not the same claim as
-- "Lua can read it", and a pcall'd field access fails as silently as a pcall'd
-- typo'd method (the getVehicleScript lesson, one file over).
--
-- SO: A BOUNDED RING SCAN. Point queries are all we have, and the search is
-- made rigorous rather than random by the geometry vanilla itself uses. Stalls
-- are laid out at stallWid = 3 by stallLen = 4-5 tiles (IsoChunk.java:978-990)
-- and a zone must hold at least one stall, so a sample lattice of 3 tiles
-- cannot step over a parking zone entirely. That makes STEP a derived bound,
-- not a guess. Rings are walked outward from the minimum distance so the
-- nearest legal stall is found first, and the whole search is capped by a
-- probe budget - a player standing beside a car park costs a few dozen
-- probes; one standing in deep forest costs the cap and correctly finds
-- nothing.
--
-- LOADED-ONLY, and why that is a feature. addVehicleDebug needs a real
-- IsoGridSquare, so a placement can only land in a streamed-in chunk. We do
-- not fight that: the search simply stops finding candidates past the loaded
-- edge, which naturally pins replacements to where players actually are. A
-- sweep that finds nowhere legal spends no token and retries next hour.

if not isServer() then return end

require "RCShared"
require "RCNoPark"

RCParking = RCParking or {}

-- Sample spacing, in tiles. Derived from vanilla's own stall geometry (see
-- header): the narrow axis of a stall is 3, so a 3-tile lattice cannot miss a
-- zone. Raising this trades a real chance of stepping over a small car park
-- for speed - do not, without re-reading AddVehicles_OnZone first.
local STEP = 3

-- Hard ceiling on candidate tiles considered in ONE search. At STEP=3 this
-- covers a generous slice of the loaded area; it exists so a player in the
-- middle of nowhere costs a predictable amount rather than scaling with the
-- search ceiling the admin happened to set.
local MAX_PROBES = 900

-- Minimum tiles between a replacement and ANY other vehicle (owner's rule,
-- 2026-08-03: two placements landed almost on top of each other).
--
-- footprintClear alone could not have prevented that, and neither could any
-- engine query. A brand-new vehicle adds itself to cell.addVehicles
-- (BaseVehicle.java:882), a PENDING set; getVehicles() returns cell.vehicles
-- (IsoCell.java:2368) and the pending set is only drained into it during the
-- cell's update pass (IsoCell.java:1875-1879). One sweep is one Lua call inside
-- one tick, so the second placement of a burst is invisible to the first
-- through every route the engine offers - which is exactly why findSpot takes
-- an explicit `avoid` list rather than trusting the world to have noticed.
local SPACING = 8

-- Last search outcome, for the Janitor view. Overwritten each search, so it
-- cannot grow.
RCParking.last = { probes = 0, found = false, dist = 0 }

-- ---------------------------------------------------------------------------
-- Legality
-- ---------------------------------------------------------------------------

-- THE never-in-grass gate. A tile is parkable only if a VehicleZone covers it.
-- getVehicleZoneAt is fully null-checked (IsoMetaGrid.java:248); only the world
-- itself can be missing, and that is a nil-check, not a guard.
function RCParking.isParkable(x, y, z)
    local world = getWorld()
    if not world then return false end
    local mg = world:getMetaGrid()
    if not mg then return false end
    local zone = mg:getVehicleZoneAt(
        math.floor(x), math.floor(y), math.floor(z or 0))
    return zone ~= nil
end

-- Is this square free of vehicles, right now? Checked over a small footprint
-- rather than the single tile, because a car is longer than one square and
-- dropping one on top of another is worse than not spawning at all.
--
-- ONE test, not two. An earlier version called getVehicleContainer() as well,
-- on the invented theory that it caught vehicles whose ORIGIN sat on the tile
-- while isVehicleIntersecting() caught mere overlap. Reading both
-- (IsoGridSquare.java:8602 and :8622) shows they are the same function with
-- different return types - identical chunk walk, identical
-- isIntersectingSquare test - so the pair was one answer computed twice, nine
-- times per probe. The distinction was never in the engine; it was in the
-- comment describing it.
-- getGridSquare returns nil for anything unloaded (ServerMap.java:627) and
-- isVehicleIntersecting null-checks each chunk (IsoGridSquare.java:8622), so
-- with a world present neither needs a guard.
local function footprintClear(x, y, z)
    local cell = getWorld() and getCell()
    if not cell then return true end
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and sq:isVehicleIntersecting() then return false end
        end
    end
    return true
end

-- Full placement test for one tile: streamed in, legally parkable, clear of
-- other vehicles, and not inside somebody's safehouse (a replacement car
-- materialising in a player base is a support ticket, not a feature).
--
-- Ordered cheapest-discriminator-first: the zone test rejects the overwhelming
-- majority of tiles and is a single Java call, so it runs before the nine
-- square lookups of the footprint check.
function RCParking.canPlace(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    if not RCParking.isParkable(x, y, z) then return false end
    -- isParkable proved the world exists; getGridSquare is nil for unloaded
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end                       -- unloaded: nothing to place on

    -- INDOOR STALLS ARE LEGAL (owner's call, 2026-08-04, replacing a blanket
    -- isOutside() gate). A painted vehicle zone inside a fire station bay or a
    -- showroom is a real parking space and vanilla uses it - its own test
    -- (IsoChunk.doSpawnedVehiclesInInvalidPosition :1244) only rejects an indoor
    -- square when there is NO zone over it. Refusing all of them cost real
    -- spots under carports and overhangs to avoid a problem nobody had yet.
    --
    -- The exception list is the answer instead: when a specific room turns out
    -- to be a bad place for a car, an admin marks that room and it is excluded
    -- from then on. Evidence beats a rule that guesses.
    if RCNoPark and RCNoPark.blocks(x, y, z) then return false end

    if not footprintClear(x, y, z) then return false end
    -- getSafeHouse null-checks the square and walks a static list with the
    -- username==null short-circuit (SafeHouse.java:148->184); cannot throw
    if SafeHouse.getSafeHouse(sq) ~= nil then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Orientation
--
-- A replacement used to take RCSpawn's uniform roll across all four headings
-- (RCSpawn.lua:70), which is how cars ended up wedged sideways between
-- buildings. The zone already knows which way its stalls run, and vanilla
-- derives exactly that before placing its own cars - so this ports vanilla's
-- rule rather than inventing a heuristic.
--
-- WHAT WE CAN AND CANNOT READ. Zone's geometry getters are METHODS and so are
-- Lua-callable: getWidth/getHeight (Zone.java:534/530), isFaceDirection
-- (VehicleZone.java:32). `VehicleZone.dir` - the explicit Direction property a
-- mapper can paint - is a public INSTANCE FIELD (VehicleZone.java:15), which
-- Kahlua never exposes (the vehiclesZones lesson, in this file's header). So a
-- hand-painted heading is unreadable and we recover the AXIS only. That is the
-- part that matters: it is facing across the stall rather than along it that
-- looks broken, not facing north instead of south.
-- ---------------------------------------------------------------------------

-- Codes match RCSpawn's spec.direction so the value passes straight through.
local DIR_W, DIR_E, DIR_N, DIR_S = 1, 2, 3, 4

-- The zone's NAME at a tile ("police", "farm", "parkingstall"...). This is what
-- VehicleZoneDistribution is keyed by, so it is how the placer asks for a car
-- that suits where it is parking. getName is a method (Zone.java:486) and so is
-- reachable, unlike the zone's dir field.
function RCParking.zoneNameAt(x, y, z)
    local world = getWorld()
    local mg = world and world:getMetaGrid()
    if not mg then return nil end
    local zone = mg:getVehicleZoneAt(
        math.floor(x), math.floor(y), math.floor(z or 0))
    -- Zone.getName is a field return (Zone.java:486)
    local name = zone and zone:getName()
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

-- Which way should a car in this zone point? Returns 1-4, or nil when the tile
-- is in no vehicle zone (the caller then leaves RCSpawn to roll, as before).
function RCParking.zoneDirection(x, y, z)
    local world = getWorld()
    local mg = world and world:getMetaGrid()
    local zone = mg and mg:getVehicleZoneAt(
        math.floor(x), math.floor(y), math.floor(z or 0))
    if not zone then return nil end

    -- field returns (Zone.java:534/530)
    local w, h = zone:getWidth(), zone:getHeight()
    if not (w and h) then return nil end

    -- Vanilla's test (IsoChunk.java:980) with its double negative resolved.
    -- The source reads:
    --     if (!(w != 4 && w != 5 && w != 6 || h > 3 && h < 6)) dir = W;
    -- De Morgan: dir is WEST when w IS one of 4/5/6 AND h is NOT 4 or 5 - i.e.
    -- the zone is exactly one stall LENGTH across, so the cars lie east-west,
    -- and its other axis is not itself a stall length (which would make the
    -- shape ambiguous and vanilla defaults those to north).
    local eastWest = (w >= 4 and w <= 6) and (h <= 3 or h >= 6)

    -- Either end of the axis, exactly as vanilla does for a zone without an
    -- explicit direction (IsoChunk.java, the setDir branch): a row of stalls
    -- holds cars nosed in both ways, and forcing one heading looks stamped.
    if eastWest then
        return (ZombRand(2) == 0) and DIR_W or DIR_E
    end
    return (ZombRand(2) == 0) and DIR_N or DIR_S
end

-- ---------------------------------------------------------------------------
-- Spacing
--
-- Kept OUT of canPlace on purpose. "Is this tile a legal place for a car" and
-- "is this a sensible place to add ANOTHER car" are different questions, and
-- only the lifecycle asks the second one: an admin placing a vehicle by hand
-- from the spawn window should be free to park it beside an existing car.
-- ---------------------------------------------------------------------------

-- Every loaded vehicle within reach of the search, as plain {x,y} points.
-- Collected ONCE per search rather than per candidate: the Java set is walked
-- with :iterator() (get(i) on it crashes - the RCSession idiom) and turned
-- straight into a Lua array, after which a spacing test is arithmetic on a
-- handful of numbers instead of an engine call.
local function vehiclePoints(x, y, maxDist)
    local out = {}
    local reach = maxDist + SPACING
    local cell = getCell and getCell()
    if not cell then return out end
    local vs = cell:getVehicles()
    if not vs then return out end
    local it = vs:iterator()
    if not it then return out end
    while it:hasNext() do
        local v = it:next()
        if v then
            local vx, vy = v:getX(), v:getY()
            -- Cheap box reject before anything is stored: a search band is
            -- a few hundred tiles across and the cell can hold cars far
            -- outside it.
            if math.abs(vx - x) <= reach and math.abs(vy - y) <= reach then
                out[#out + 1] = { x = vx, y = vy }
            end
        end
    end
    return out
end

-- Squared distance throughout: no square roots, and SPACING is a constant.
local function tooClose(tx, ty, points)
    if not points then return false end
    local limit = SPACING * SPACING
    for i = 1, #points do
        local p = points[i]
        local dx, dy = tx - p.x, ty - p.y
        if dx * dx + dy * dy < limit then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- Find a legal parking tile near (x,y), at least minDist away and no further
-- than maxDist. Walks outward in rings so the NEAREST legal stall wins, which
-- keeps a replacement in the car park down the road rather than at a random
-- point in the allowed band.
--
-- Returns x, y, z or nil. nil is a NORMAL outcome (nothing legal is loaded
-- nearby) and the caller must treat it as "try again later", never an error.
--
-- `avoid` is an optional array of {x=,y=} points the result must also stay
-- SPACING tiles clear of. Callers placing several vehicles in one pass MUST
-- pass the ones they have already placed: those cars exist in the world but not
-- yet in cell.getVehicles(), so nothing else can see them (see SPACING).
--
-- One ring walk. `crowd` is the point set to keep SPACING clear of, or nil to
-- skip that test entirely; `avoid` is enforced either way. Returns the tile
-- plus the radius it was found at, or nil plus the probes spent.
local function ringWalk(x, y, z, minDist, maxDist, crowd, avoid)
    local probes = 0
    for radius = math.max(minDist, STEP), maxDist, STEP do
        -- Arc spacing matched to the lattice: enough samples that consecutive
        -- points on this ring are about STEP apart, so the ring cannot slip
        -- between two halves of a car park. Bigger rings get more samples,
        -- which is why the probe budget rather than the ring count is what
        -- ultimately bounds this.
        local samples = math.max(8, math.floor((2 * 3.14159265 * radius) / STEP))

        -- Start each ring at a random angle. Without this every search sweeps
        -- the same compass bearing first and replacements cluster to the east
        -- of wherever players stand.
        local offset = ZombRandFloat(0, 6.2831853)

        for i = 0, samples - 1 do
            local ang = offset + (i * 6.2831853 / samples)
            local tx = x + math.floor(math.cos(ang) * radius)
            local ty = y + math.floor(math.sin(ang) * radius)

            probes = probes + 1
            if probes > MAX_PROBES then return nil, nil, probes - 1 end

            -- Spacing first: it is Lua arithmetic over a short array, where
            -- canPlace is a zone lookup plus nine square lookups. Rejecting a
            -- crowded tile here saves all of that.
            if not tooClose(tx, ty, crowd) and not tooClose(tx, ty, avoid)
                and RCParking.canPlace(tx, ty, z) then
                return tx, ty, probes, radius
            end
        end
    end
    return nil, nil, probes
end

-- TWO PASSES, and the second one is not a nicety (added 2026-08-03 after the
-- first version returned nothing at all in Louisville).
--
-- The spacing rule and the parkable rule fight each other, because they select
-- for the same tiles: a car park is BOTH the only legal ground and the place
-- cars already are. In a dense city the first pass therefore rejects almost
-- exactly the tiles that passed the zone test, and with MAX_PROBES exhausted
-- inside a ~20-tile band the search never reaches emptier ground. Three sweeps
-- with 21 tokens banked placed nothing.
--
-- So: pass one wants a genuinely uncrowded stall anywhere in range. Pass two
-- drops the requirement to stand clear of vehicles that were ALREADY THERE and
-- keeps it only against `avoid` - this sweep's own placements. That is the
-- distinction the rule was actually asked for: two replacements landing on top
-- of each other is the bug, whereas a replacement parking beside a car already
-- in a car park is what a car park looks like. `avoid` is never relaxed, and
-- canPlace still runs, so a car can never land ON another one either way.
--
-- Each pass gets its own probe budget. Sharing one would make the fallback
-- decorative, since pass one only fails by exhausting it.
--
-- Returns x, y, z or nil. nil is a NORMAL outcome (nothing legal is loaded
-- nearby) and the caller must treat it as "try again later", never an error.
function RCParking.findSpot(x, y, z, minDist, maxDist, avoid)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    minDist = math.max(math.floor(minDist or 0), 0)
    maxDist = math.max(math.floor(maxDist or 250), minDist + STEP)

    RCParking.last = { probes = 0, found = false, dist = 0 }

    local existing = vehiclePoints(x, y, maxDist)

    local tx, ty, probes, radius = ringWalk(x, y, z, minDist, maxDist, existing, avoid)
    if tx then
        RCParking.last = { probes = probes, found = true, dist = radius, relaxed = false }
        return tx, ty, z
    end

    local spent = probes
    tx, ty, probes, radius = ringWalk(x, y, z, minDist, maxDist, nil, avoid)
    if tx then
        -- Reported, not silent: "found at 47 tiles (crowded)" tells the admin
        -- the area is full and the rule was relaxed to place at all, which is
        -- a real fact about their world rather than an implementation detail.
        RCParking.last = { probes = spent + probes, found = true, dist = radius, relaxed = true }
        return tx, ty, z
    end

    RCParking.last = { probes = spent + probes, found = false, dist = 0 }
    return nil
end

-- Diagnostics for the Janitor view. Reports the LAST SEARCH rather than a
-- static index size, because there is no index to describe - what an admin can
-- actually act on is "did the last attempt find anywhere, and how hard did it
-- look".
function RCParking.status()
    local l = RCParking.last or {}
    return { probes = l.probes or 0, found = l.found and true or false,
             dist = l.dist or 0, step = STEP, cap = MAX_PROBES, spacing = SPACING,
             -- Normalised to a real boolean: the panel renders this, and a nil
             -- would read as "strictly spaced" on a search that was relaxed.
             relaxed = l.relaxed and true or false }
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
