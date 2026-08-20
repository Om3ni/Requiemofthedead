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
-- (IsoHutch.java:61, 898-904), so this exact current API is a direct read.
local MAX_HUTCH_SLOTS = 64
local function visitHutchAnimals(hutch, visit)
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
    -- The adef-null NPEs the old guards named are real - setAgeDebug
    -- (IsoAnimal:1500) reads this.adef.minAge, setSize/setWeight
    -- (AnimalData:1380/1598) clamp through parent.adef, and a constructor that
    -- bailed early (IsoAnimal:259-275) leaves adef null - but all three are
    -- exposed methods: MethodCaller swallows the fault, logs the trace, and
    -- the write silently no-ops (MethodCaller.java:33-56). The pcalls that sat
    -- here could never fire; fire-and-forget is the same contract either way,
    -- now stated honestly.
    animal:setAgeDebug(target)
    if size   then data:setSize(size)     end
    if weight then data:setWeight(weight) end
end

-- An adult age guaranteed below the geriatric threshold (~0.8 * maxAge).
local function safeAdultAge(animal, data, floorAge)
    -- getMaxAgeGeriatric (AnimalData:1533) reads parent.adef.maxAgeGeriatric -
    -- the NPE is real but arrives here as nil (exposed method, MethodCaller
    -- .java:33-56), so the type test was always the whole gate; `ok` could not
    -- be false.
    local maxAge = data:getMaxAgeGeriatric()
    if type(maxAge) == "number" and maxAge > 0 then
        return math.max(floorAge or 1, math.floor(maxAge * 0.6))
    end
    return math.max(floorAge or 1, 1)
end

-- ─── per-animal policy ─────────────────────────────────────────────────────
local function manageAnimal(animal, mode, mult)
    local oid = animal:getOnlineID()
    if not oid or oid == 0 then return end

    if animal:isWild() then return end  -- only manage tame livestock

    -- isBaby (IsoAnimal:1657) and getAge (IsoAnimal:2101) both dereference
    -- getData(), null on an animal whose constructor bailed early
    -- (IsoAnimal:259-275) - but both are exposed methods, so the fault arrives
    -- here as nil, never as an error (MethodCaller.java:33-56). A faulted
    -- animal skips the baby branch on the falsy nil and bails at the age type
    -- test, which was always the real gate. The old "treat it as a baby"
    -- fallback was dead code: its pcall could not fail.
    local baby = animal:isBaby()
    local age = animal:getAge()
    if type(age) ~= "number" then return end

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
        -- null guard - real, but swallowed to a falsy nil on a faulted animal
        -- (exposed method), which is the same "not geriatric" answer the old
        -- ok-test produced.
        if animal:isGeriatric() then
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
                    -- ServerMap is constructed at class initialization; cold grid
                    -- coordinates return nil. A vehicle scan ignores removed or
                    -- detached vehicles before consulting its polygon (IsoCell.java:
                    -- 2800-2818; ServerMap.java:595-613; IsoGridSquare.java:
                    -- 8602-8619; BaseVehicle.java:5269-5280, 9528-9530).
                    local s = cell:getGridSquare(px + dx, py + dy, pz)
                    if s then

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
                                        -- Free seed for HBFarmHand: this walk
                                        -- already found a hutch, and telling
                                        -- the registry costs one table write.
                                        if HBFarmHand then HBFarmHand.remember(o) end
                                        visitHutchAnimals(o, visit)
                                    end
                                end
                            end
                        end
                    end
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
    -- No batch guard - after the per-call corrections above, manageAnimal is
    -- total: every engine read in it is an exposed method whose fault arrives
    -- as nil, and every nil is handled, so a malformed animal no-ops its own
    -- writes and there is nothing left to contain. Should that ever stop being
    -- true, this tick runs under the event dispatcher's per-listener catch
    -- (Event.java:53-63) and retries on the next hour - loud, attributable,
    -- self-healing, which the policy prefers to a silent herd-pass shield.
    walk(function(animal) manageAnimal(animal, mode, mult) end, present)

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
