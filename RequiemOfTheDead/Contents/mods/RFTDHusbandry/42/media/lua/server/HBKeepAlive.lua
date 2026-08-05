-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBKeepAlive - automated keep-alive for animals.
--
-- Two coverage tracks:
--
-- TRACK A: EveryTenMinutes refill loop. Walks loaded loose animals (cell
-- object list) and animals in nearby trailers (grid-square getVehicleContainer
-- scan around each connected player). For each, sets HUNGER=0, THIRST=0 and
-- resets the elapsed-time clock via updateLastTimeSinceUpdate(). This is the
-- normal-operation keep-alive - animals never accumulate need while loaded.
-- (Need rises over in-game hours, so a 10-minute cadence is ample; see tick().)
--
-- TRACK B: Vehicles.Update.TrailerAnimalFood override. Vanilla's meta-time
-- drain function fires when a parked trailer's chunk reloads after long
-- absence and applies elapsedHours of hunger/thirst depletion via
-- updateStatsAway() to each animal in the trailer (Vehicles.lua:444-450).
-- When the mod is enabled we replace it with a zero-stats refill, so a
-- trailer left for days doesn't return with starved animals.
--
-- Both gated by SandboxVars.RFTDHusbandry.Enable. When the toggle is off,
-- vanilla behavior is preserved - vanilla drain function still in place,
-- no refill tick.

if not isServer() then return end

print("[HB] HBKeepAlive loaded - server tick + trailer override")

local TRAILER_SCAN_RANGE = 20  -- ±squares around each player for trailer scan

-- Diagnostic instrumentation. Read-only state exposed for optional consumers
-- (e.g. HBErrorMagnifier). If you want to fully de-instrument the keep-alive
-- when the mod stabilises, deleting this table and the four `HBKeepAlive.*`
-- writes below removes it cleanly - no other module reads these fields
-- beyond HBErrorMagnifier.lua.
HBKeepAlive = HBKeepAlive or {}
HBKeepAlive.tickCount            = 0
HBKeepAlive.lastTickAt           = 0
HBKeepAlive.lastLooseRefilled    = 0
HBKeepAlive.lastTrailerRefilled  = 0
HBKeepAlive.lastHutchRefilled    = 0
HBKeepAlive.trailerOverrideCalls = 0
HBKeepAlive.hutchScanOK          = true   -- flips false only if getAnimalInside() ever raises a real Lua error
HBKeepAlive.verbose              = false  -- set true to log per-tick refill counts

-- Core primitive: zero hunger/thirst, reset elapsed-time clock.
-- Same write path the debug panel's Refill button uses.
local function refillAnimal(animal)
    pcall(function()
        animal:getStats():set(CharacterStat.HUNGER, 0)
        animal:getStats():set(CharacterStat.THIRST, 0)
        animal:updateLastTimeSinceUpdate()
    end)
end

-- Pass 1: loose animals via cell object list. Returns count refilled.
local function refillLoose(cell, seen)
    local ok, objs = pcall(function() return cell:getObjectListForLua() end)
    if not ok or not objs or type(objs) == "boolean" then return 0 end
    local count = 0
    pcall(function() count = objs:size() or 0 end)
    local refilled = 0
    for i = 0, count - 1 do
        pcall(function()
            local obj = objs:get(i)
            if not obj then return end
            if not instanceof(obj, "IsoAnimal") then return end
            local oid = obj:getOnlineID()
            if not oid or oid == 0 or seen[oid] then return end
            seen[oid] = true
            if HBData and HBData.seen then HBData.seen[oid] = true end
            refillAnimal(obj)
            refilled = refilled + 1
        end)
    end
    return refilled
end

-- Read a hutch's occupants via getAnimal(pos) over a fixed slot range - NOT
-- getMaxAnimals(), and NOT getAnimalInside():values():iterator().
--
-- Two distinct engine traps to avoid here:
--
--  1. def-NPE: getMaxAnimals() (and most slot/def accessors) read the hutch's
--     script definition (IsoHutch.def). A hutch whose sprite def failed to
--     resolve - an orphaned coop sprite from a removed mod, or a build whose
--     hutch defs shifted - has def == null, so getMaxAnimals() NPEs *inside
--     the engine* (def.rawgetInt). PZ's Lua pcall does NOT catch that Java
--     NPE: it propagates past the pcall, dumps a stack trace, and aborts the
--     tick. So we must never call getMaxAnimals() to bound the loop.
--
--  2. unexposed-view: getAnimalInside() returns the animalInside HashMap
--     (always initialised, never touches def - safe), BUT chaining
--     :values():iterator() fails with "attempted index: iterator of non-table:
--     []". HashMap.values() returns a java.util.HashMap$Values view whose class
--     PZ's Kahlua bridge doesn't expose, so :iterator() indexes a non-table.
--     This bit all three hutch scanners (here, HBLifespan, the debug panel);
--     pcall caught it, but it disabled the scan on the first hutch every run.
--
-- Fix: getAnimal(pos) is def-free (it's literally `animalInside.get(index)`),
-- so we scan a generous fixed slot range and collect non-nil occupants. Slots
-- are assigned via Rand.Next(0, maxAnimals) so real positions are always < a
-- small maxAnimals; MAX_HUTCH_SLOTS covers any sane hutch at trivial cost
-- (HashMap.get is O(1)). Hutch animals do drain (IsoHutch.update →
-- updateHungerAndThirst), so this refill is load-bearing, not cosmetic.
--
-- The capability flag is kept as a genuine guard: getAnimal()/getAnimalInside()
-- won't NPE, so a failure here would be a real, catchable Lua error (e.g. the
-- method renamed in a future build) - the first one disables hutch scanning and
-- logs once instead of per-square.
local hutchScanOK = true
local MAX_HUTCH_SLOTS = 64

-- Caller owns per-hutch dedup (see the hutch loop below), so this just
-- refills the occupants of one hutch and returns the count.
local function refillHutch(hutch, seen)
    local count = 0
    local ok, err = pcall(function()
        local inside = hutch:getAnimalInside()
        if not inside then return end
        for pos = 0, MAX_HUTCH_SLOTS - 1 do
            local animal = hutch:getAnimal(pos)
            if animal then
                local oid = animal:getOnlineID()
                if oid and oid ~= 0 and not seen[oid] then
                    seen[oid] = true
                    if HBData and HBData.seen then HBData.seen[oid] = true end
                    refillAnimal(animal)
                    count = count + 1
                end
            end
        end
    end)
    if not ok then
        hutchScanOK = false
        HBKeepAlive.hutchScanOK = false
        print("[HB] hutch keep-alive disabled - IsoHutch animal API unavailable "
            .. "(logged once): " .. tostring(err))
    end
    return count
end

-- Pass 2: animals in trailers (vehicle container) AND hutches (rabbit /
-- chicken coops). Both store animals in their own per-container list, not in
-- the cell's general object list, so we walk grid squares around the player
-- and pull from each container we find.
--   sq:getVehicleContainer() → BaseVehicle, then v:getAnimals() (ArrayList)
--   sq:getObjects()          → IsoHutch instances, then refillHutch() above
local function refillContainersAround(cell, player, seen, seenVehicles, seenHutches)
    if not player then return 0, 0 end
    local sq = player:getCurrentSquare()
    if not sq then return 0, 0 end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local trailerRefilled, hutchRefilled = 0, 0

    local function refillFromAnimalsList(animalsList, tracker)
        if not animalsList then return 0 end
        local n = animalsList:size() or 0
        local count = 0
        for j = 0, n - 1 do
            local animal = animalsList:get(j)
            if animal then
                local oid = animal:getOnlineID()
                if oid and oid ~= 0 and not seen[oid] then
                    seen[oid] = true
                    if HBData and HBData.seen then HBData.seen[oid] = true end
                    refillAnimal(animal)
                    count = count + 1
                end
            end
        end
        return count
    end

    for dx = -TRAILER_SCAN_RANGE, TRAILER_SCAN_RANGE do
        for dy = -TRAILER_SCAN_RANGE, TRAILER_SCAN_RANGE do
            pcall(function()
                local s = cell:getGridSquare(px + dx, py + dy, pz)
                if not s then return end

                -- Trailer animals
                local v = s:getVehicleContainer()
                if v then
                    local vid = v:getId()
                    if vid and not seenVehicles[vid] then
                        seenVehicles[vid] = true
                        trailerRefilled = trailerRefilled + refillFromAnimalsList(v:getAnimals(), seenVehicles)
                    end
                end

                -- Hutches: enumerate once per square, dedup across players,
                -- then do two independent jobs per hutch:
                --   • HBBedding.applyBedding - def-free dirt cleaning; runs
                --     even if the animal API is disabled (it never calls it).
                --   • refillHutch - animal keep-alive; gated by hutchScanOK,
                --     which trips off if the IsoHutch animal API ever vanishes.
                local objs = s:getObjects()
                if objs then
                    for k = 0, objs:size() - 1 do
                        local obj = objs:get(k)
                        if obj and instanceof(obj, "IsoHutch") then
                            local hkey = tostring(obj)
                            if not seenHutches[hkey] then
                                seenHutches[hkey] = true
                                if HBBedding then HBBedding.applyBedding(obj) end
                                if hutchScanOK then
                                    hutchRefilled = hutchRefilled + refillHutch(obj, seen)
                                end
                            end
                        end
                    end
                end
            end)
        end
    end

    return trailerRefilled, hutchRefilled
end

-- Resolve the player set to scan around. SP: getSpecificPlayer(0). MP: walk
-- getOnlinePlayers().
local function gatherPlayers()
    local out = {}
    local ok, op = pcall(function() return getOnlinePlayers() end)
    if ok and op and op.size then
        local n = 0
        pcall(function() n = op:size() or 0 end)
        for i = 0, n - 1 do
            local p = op:get(i)
            if p then out[#out + 1] = p end
        end
    end
    if #out == 0 then
        local p = getSpecificPlayer(0)
        if p then out[#out + 1] = p end
    end
    return out
end

-- ─── Track A: keep-alive tick ────────────────────────────────────────────

-- Runs on EveryTenMinutes. Animal hunger/thirst rise over in-game HOURS, so
-- 10-minute resolution pins loaded animals at zero need with no gameplay
-- difference from a faster cadence - at ~1/10th the cost of EveryOneMinute,
-- which re-zeroed need far more often than the stat itself moved. Trailers
-- that sat through meta-time are handled separately by Track B below, so this
-- loop only services currently-loaded animals and needs no fast reaction time.
local function tick()
    local sv = SandboxVars.RFTDHusbandry
    if not sv or not sv.Enable then return end

    local cell = getCell()
    if not cell then return end

    HBKeepAlive.tickCount  = (HBKeepAlive.tickCount or 0) + 1
    HBKeepAlive.lastTickAt = getTimestamp()

    local seen = {}

    -- Loose animals: single cell-list walk.
    local nLoose = refillLoose(cell, seen)

    -- Trailers + hutches: ±20 grid-square scan per player.
    local nTrailer, nHutch = 0, 0
    local seenVehicles, seenHutches = {}, {}
    for _, p in ipairs(gatherPlayers()) do
        local t, h = refillContainersAround(cell, p, seen, seenVehicles, seenHutches)
        nTrailer = nTrailer + t
        nHutch   = nHutch + h
    end

    HBKeepAlive.lastLooseRefilled   = nLoose
    HBKeepAlive.lastTrailerRefilled = nTrailer
    HBKeepAlive.lastHutchRefilled   = nHutch

    -- Logging is opt-in (HBKeepAlive.verbose) - the instrumentation fields
    -- above carry the same state without spamming the server log.
    if HBKeepAlive.verbose and (nLoose + nTrailer + nHutch) > 0 then
        print(string.format("[HB] keep-alive tick: refilled %d loose, %d trailer, %d hutch",
            nLoose, nTrailer, nHutch))
    end
end

Events.EveryTenMinutes.Add(tick)

-- ─── Track B: Vehicles.Update.TrailerAnimalFood override ─────────────────
-- Replace vanilla's meta-time drain. Vanilla calls
-- vehicle:getAnimals():get(i):updateStatsAway(hours) to apply elapsed-hours
-- of depletion when a chunk reloads after meta time. With the mod enabled,
-- we zero the stats instead. With the mod disabled, vanilla runs unchanged.

if Vehicles and Vehicles.Update then
    local _origTrailerAnimalFood = Vehicles.Update.TrailerAnimalFood

    Vehicles.Update.TrailerAnimalFood = function(vehicle, part, elapsedMinutes)
        local sv = SandboxVars.RFTDHusbandry
        if not sv or not sv.Enable then
            if _origTrailerAnimalFood then
                return _origTrailerAnimalFood(vehicle, part, elapsedMinutes)
            end
            return
        end

        HBKeepAlive.trailerOverrideCalls = (HBKeepAlive.trailerOverrideCalls or 0) + 1

        pcall(function()
            if not vehicle then return end
            local animals = vehicle:getAnimals()
            if not animals then return end
            local n = animals:size()
            if not n or n == 0 then return end
            for i = 0, n - 1 do
                local animal = animals:get(i)
                if animal then refillAnimal(animal) end
            end
        end)
    end

    print("[HB] Vehicles.Update.TrailerAnimalFood override installed")
else
    print("[HB] Vehicles.Update not available at load - trailer override skipped")
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
