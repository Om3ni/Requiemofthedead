-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBLifespan - server-side old-age mitigation for tame animals.
--
-- WHY: Vanilla animal lifespan is hard-capped at ~maxAgeGeriatric real days
-- (often ~6 months), and the sandbox animalAgeModifier only makes animals age
-- FASTER, never slower - so there is no vanilla way to make livestock live
-- longer. Past ~80% of max age an animal becomes "geriatric"
-- (IsoAnimal.isGeriatric) and bleeds health every hour; at ~95% it loses a
-- flat 0.1 HP/hour and dies within ~10 game-hours (AnimalData.checkOld).
-- Same-age herds reach that cliff together → mass die-offs.
--
-- WHAT THIS DOES (sandbox-controlled, tame animals only):
--   Vanilla - does nothing; engine behavior unchanged.
--   Extended - slows aging to 1/N so animals still age and eventually die of
--              old age, just N times later. N = AnimalLifespanMultiplier.
--              Easy math: each game-day the engine ages an animal by 1 day;
--              we roll (1 - 1/N) of that back, so net aging is 1/N. N=4 means
--              ~4x lifespan (a 6-month species now lasts ~2 years).
--   Frozen - lets animals grow to adulthood, then holds their age there so
--              they never become geriatric. Immortal livestock.
--
-- HOW age is changed: IsoAnimal.setAgeDebug(n) sets age, recomputes
-- hoursSurvived (so daysSurvived follows) and clamps to the species minAge -
-- which is exactly what we need, since isGeriatric() keys off daysSurvived and
-- getGeriatricPercentage() keys off age. setAgeDebug also calls
-- AnimalData.init(), and vanilla initSize() has a bug (AnimalData.java:1215
-- unconditionally setSize(0.1f)) that would shrink the animal - so we snapshot
-- size/weight and restore them around the call. setHoursSurvived is not
-- exposed to Lua, so setAgeDebug is the only lever; the snapshot/restore is the
-- price of using it.
--
-- Per-animal state is in-memory only (resets on restart; animals resume from
-- their stored age - no save data is touched). Enumeration mirrors HBKeepAlive's
-- loose/trailer/hutch walk but is kept separate so this feature toggles
-- independently and never risks the keep-alive path. Gated solely by
-- AnimalLifespanMode (its "Vanilla" value is the off switch) - independent of
-- the mod's hunger/thirst Enable toggle.

if not isServer() then return end

print("[HB] HBLifespan loaded - server old-age mitigation")

local MODE_VANILLA = 1
local MODE_EXTEND  = 2
local MODE_FROZEN  = 3

local SCAN_RANGE = 20  -- +/- squares around each player (matches HBKeepAlive)

-- Enumerate a hutch's occupants via getAnimal(pos) over a fixed slot range -
-- NOT getMaxAnimals(), and NOT getAnimalInside():values():iterator(). Two engine
-- traps: (1) getMaxAnimals() reads IsoHutch.def, which is null on a hutch whose
-- sprite def failed to resolve, NPEing *inside the engine* past Lua pcall and
-- aborting the tick; (2) getAnimalInside():values():iterator() throws "attempted
-- index: iterator of non-table: []" because HashMap.values() returns an
-- unexposed java.util.HashMap$Values view. getAnimal(pos) is def-free
-- (`animalInside.get(index)`) and view-free. (Full rationale in HBKeepAlive.)
-- The flag is kept as a guard against a genuine (catchable) future API change:
-- in 42.20.2 getAnimalInside (IsoHutch:898) is a field return and getAnimal
-- (IsoHutch:902) a HashMap.get on a map initialised at the declaration
-- (IsoHutch:61), so neither can throw HERE - the guard exists because the B42
-- animal API is still moving and a rename in a later 42.x would. That makes it
-- a cross-build PROBE, so it runs ONCE and the verdict is cached:
-- nil = not yet probed, true = usable, false = disabled for the session.
local hutchScanOK = nil
local MAX_HUTCH_SLOTS = 64
local function visitHutchAnimals(hutch, visit)
    if hutchScanOK == false then return end
    if hutchScanOK == nil then
        -- One-shot cross-build probe: the IsoHutch animal API either exists on
        -- this build or it does not, so re-probing per hutch buys nothing.
        local ok, err = pcall(function()
            if hutch:getAnimalInside() then hutch:getAnimal(0) end
        end)
        if not ok then
            hutchScanOK = false
            print("[HB] HBLifespan hutch enumeration disabled - IsoHutch animal API "
                .. "unavailable (logged once): " .. tostring(err))
            return
        end
        hutchScanOK = true
    end
    local inside = hutch:getAnimalInside()
    if not inside then return end
    for pos = 0, MAX_HUTCH_SLOTS - 1 do
        local animal = hutch:getAnimal(pos)
        if animal then visit(animal) end
    end
end

-- In-memory per-oid state.
local lastAge   = {}   -- oid -> last observed engine age (days)
local debt      = {}   -- oid -> fractional age owed for rollback (Extended)
local matureAge = {}   -- oid -> age first seen as a grown adult (freeze point / floor)

-- ─── age write: lower age/daysSurvived without the initSize() shrink bug ───
local function setAgeSafe(animal, data, target)
    target = math.floor(target)
    -- getSize/getWeight are field returns (AnimalData:1389/1409) - no guard.
    local size   = data:getSize()
    local weight = data:getWeight()
    -- setAgeDebug (IsoAnimal:1500) reads this.adef.minAge and calls
    -- AnimalData.init(); setSize/setWeight (AnimalData:1380/1598) clamp through
    -- getMinSize/getMaxSize, which read parent.adef too. A constructor that
    -- bailed early (IsoAnimal:259-275) leaves adef null, so all three can NPE.
    pcall(animal.setAgeDebug, animal, target)
    if size   then pcall(data.setSize,   data, size)   end
    if weight then pcall(data.setWeight, data, weight) end
end

-- An adult age guaranteed below the geriatric threshold (~0.8 * maxAge).
local function safeAdultAge(animal, data, floorAge)
    -- getMaxAgeGeriatric (AnimalData:1533) reads parent.adef.maxAgeGeriatric
    -- and walks getUsedGene - NPEs on an animal whose adef never resolved.
    local ok, maxAge = pcall(data.getMaxAgeGeriatric, data)
    if ok and type(maxAge) == "number" and maxAge > 0 then
        return math.max(floorAge or 1, math.floor(maxAge * 0.6))
    end
    return math.max(floorAge or 1, 1)
end

-- ─── per-animal policy ─────────────────────────────────────────────────────
local function manageAnimal(animal, mode, mult)
    local oid = animal:getOnlineID()
    if not oid or oid == 0 then return end

    if animal:isWild() then return end  -- only manage tame livestock

    -- isBaby (IsoAnimal:1657) dereferences getData().currentStage and getAge
    -- (IsoAnimal:2101) dereferences getData(); data is null on an animal whose
    -- constructor bailed early. Failure keeps the old defaults: treat it as a
    -- baby (leave it alone) and bail when the age is unreadable.
    local okBaby, baby = pcall(animal.isBaby, animal)
    if not okBaby then baby = true end
    local okAge, age = pcall(animal.getAge, animal)
    if not okAge or type(age) ~= "number" then return end

    if baby then
        lastAge[oid] = age   -- let babies grow untouched
        return
    end

    -- First time we see it grown, remember its age as the maturity point.
    if not matureAge[oid] then matureAge[oid] = age end
    local floorAge = matureAge[oid]

    local data = animal:getData()   -- IsoAnimal:1185, `return this.data` (may be nil)
    if not data then return end

    if mode == MODE_FROZEN then
        if age > floorAge then
            setAgeSafe(animal, data, floorAge)
            age = floorAge
        end
        -- Safety: a reloaded already-old animal can be past geriatric even at
        -- its recorded maturity age; pull it firmly below the threshold.
        -- isGeriatric (IsoAnimal:1809) reads this.adef.maxAgeGeriatric with no
        -- null guard - NPEs on an animal whose adef never resolved.
        local okGer, ger = pcall(animal.isGeriatric, animal)
        if okGer and ger then
            local t = safeAdultAge(animal, data, floorAge)
            setAgeSafe(animal, data, t)
            age = t
        end
        lastAge[oid] = age
        return
    end

    -- MODE_EXTEND: slow aging to 1/N. Animals still eventually age out and die,
    -- just N times later - so no never-geriatric safety here, by design.
    if mult and mult > 1 then
        local prev = lastAge[oid]
        if prev and age > prev then
            debt[oid] = (debt[oid] or 0) + (age - prev) * (1 - 1 / mult)
            local rb = math.floor(debt[oid] or 0)
            if rb >= 1 then
                local target = math.max(floorAge, age - rb)
                debt[oid] = (debt[oid] or 0) - (age - target)
                setAgeSafe(animal, data, target)
                age = target
            end
        end
    end
    lastAge[oid] = age
end

-- ─── enumeration (mirror of HBKeepAlive: loose + trailer + hutch) ───────────
local function gatherPlayers()
    local out = {}
    -- getOnlinePlayers is an unconditional engine global (LuaManager:3823): it
    -- returns GameServer.getPlayers() on a dedi and an empty list otherwise,
    -- never null and never throwing. SP falls through to getSpecificPlayer(0).
    local op = getOnlinePlayers()
    if op then
        for i = 0, (op:size() or 0) - 1 do
            local p = op:get(i); if p then out[#out + 1] = p end
        end
    end
    if #out == 0 then local p = getSpecificPlayer(0); if p then out[#out + 1] = p end end
    return out
end

local function walk(apply, present)
    local cell = getCell(); if not cell then return end
    local seen = {}

    local function visit(animal)
        if not animal then return end
        local oid = animal:getOnlineID()
        if not oid or oid == 0 or seen[oid] then return end
        seen[oid] = true
        present[oid] = true
        apply(animal)
    end

    -- Loose animals via the cell object list. getObjectListForLua (IsoCell:2315)
    -- snapshots a final, declaration-initialised HashSet (IsoCell:165), so the
    -- read cannot throw on the nil-checked cell above.
    local objs = cell:getObjectListForLua()
    if objs and type(objs) ~= "boolean" then
        local n = objs:size() or 0
        for i = 0, n - 1 do
            local o = objs:get(i)
            if o and instanceof(o, "IsoAnimal") then visit(o) end
        end
    end

    -- Trailer + hutch animals around each connected player.
    local seenV, seenH = {}, {}
    for _, p in ipairs(gatherPlayers()) do
        local sq = p:getCurrentSquare()   -- IsoMovingObject:1819, `return this.current`
        if sq then
            local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
            for dx = -SCAN_RANGE, SCAN_RANGE do
                for dy = -SCAN_RANGE, SCAN_RANGE do
                    -- KEEP: getGridSquare (IsoCell:2791) and getVehicleContainer
                    -- (IsoGridSquare:8602) both dereference the ServerMap.instance
                    -- / IsoWorld.instance singletons and walk chunk lists - not
                    -- field returns, and a square on an unloaded chunk edge is
                    -- exactly when this scan runs.
                    pcall(function()
                        local s = cell:getGridSquare(px + dx, py + dy, pz)
                        if not s then return end

                        local v = s:getVehicleContainer()
                        if v then
                            local vid = v:getId()
                            if vid and not seenV[vid] then
                                seenV[vid] = true
                                local list = v:getAnimals()
                                if list then for j = 0, (list:size() or 0) - 1 do visit(list:get(j)) end end
                            end
                        end

                        local objs = s:getObjects()
                        if objs then
                            for k = 0, (objs:size() or 0) - 1 do
                                local o = objs:get(k)
                                if o and instanceof(o, "IsoHutch") then
                                    local key = tostring(o)
                                    if not seenH[key] then
                                        seenH[key] = true
                                        visitHutchAnimals(o, visit)
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
    end
end

-- ─── tick ───────────────────────────────────────────────────────────────────
local function tick()
    local sv = SandboxVars.RFTDHusbandry
    if not sv then return end
    local mode = sv.AnimalLifespanMode or MODE_VANILLA
    if mode == MODE_VANILLA then return end
    local mult = sv.AnimalLifespanMultiplier or 4

    local present = {}
    -- KEEP: containment. manageAnimal writes ages through setAgeDebug/setSize/
    -- setWeight, all of which read the animal's adef; one malformed animal must
    -- not take the rest of the herd's pass down with it.
    walk(function(animal) pcall(manageAnimal, animal, mode, mult) end, present)

    -- Prune state for animals no longer loaded (keeps the tables bounded).
    for oid in pairs(lastAge)   do if not present[oid] then lastAge[oid]   = nil end end
    for oid in pairs(debt)      do if not present[oid] then debt[oid]      = nil end end
    for oid in pairs(matureAge) do if not present[oid] then matureAge[oid] = nil end end
end

-- Hourly is plenty: engine age changes once per game-day, and we only need to
-- clamp before an animal crosses the geriatric threshold.
Events.EveryHours.Add(tick)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
