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

RCParking = RCParking or {}

-- Sample spacing, in tiles. Derived from vanilla's own stall geometry (see
-- header): the narrow axis of a stall is 3, so a 3-tile lattice cannot miss a
-- zone. Raising this trades a real chance of stepping over a small car park
-- for speed - do not, without re-reading AddVehicles_OnZone first.
local STEP = 3

-- Hard ceiling on getVehicleZoneAt calls for ONE search. At STEP=3 this covers
-- a generous slice of the loaded area; it exists so a player in the middle of
-- nowhere costs a predictable amount rather than scaling with the search
-- ceiling the admin happened to set.
local MAX_PROBES = 900

-- Last search outcome, for the Janitor view. Overwritten each search, so it
-- cannot grow.
RCParking.last = { probes = 0, found = false, dist = 0 }

-- ---------------------------------------------------------------------------
-- Legality
-- ---------------------------------------------------------------------------

-- THE never-in-grass gate. A tile is parkable only if a VehicleZone covers it.
function RCParking.isParkable(x, y, z)
    local zone
    local ok = pcall(function()
        zone = getWorld():getMetaGrid():getVehicleZoneAt(
            math.floor(x), math.floor(y), math.floor(z or 0))
    end)
    return ok and zone ~= nil
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
local function footprintClear(x, y, z)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq
            pcall(function() sq = getCell():getGridSquare(x + dx, y + dy, z) end)
            if sq then
                local busy = false
                pcall(function() busy = sq:isVehicleIntersecting() end)
                if busy then return false end
            end
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
    local sq
    pcall(function() sq = getCell():getGridSquare(x, y, z) end)
    if not sq then return false end                       -- unloaded: nothing to place on
    if not footprintClear(x, y, z) then return false end
    local sheltered = false
    pcall(function() sheltered = SafeHouse.getSafeHouse(sq) ~= nil end)
    if sheltered then return false end
    return true
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
function RCParking.findSpot(x, y, z, minDist, maxDist)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    minDist = math.max(math.floor(minDist or 0), 0)
    maxDist = math.max(math.floor(maxDist or 250), minDist + STEP)

    local probes = 0
    RCParking.last = { probes = 0, found = false, dist = 0 }

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
            if probes > MAX_PROBES then
                RCParking.last = { probes = probes - 1, found = false, dist = 0 }
                return nil
            end

            if RCParking.canPlace(tx, ty, z) then
                RCParking.last = { probes = probes, found = true, dist = radius }
                return tx, ty, z
            end
        end
    end

    RCParking.last = { probes = probes, found = false, dist = 0 }
    return nil
end

-- Diagnostics for the Janitor view. Reports the LAST SEARCH rather than a
-- static index size, because there is no index to describe - what an admin can
-- actually act on is "did the last attempt find anywhere, and how hard did it
-- look".
function RCParking.status()
    local l = RCParking.last or {}
    return { probes = l.probes or 0, found = l.found and true or false,
             dist = l.dist or 0, step = STEP, cap = MAX_PROBES }
end
