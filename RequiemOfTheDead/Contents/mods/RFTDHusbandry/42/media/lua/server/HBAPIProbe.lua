-- HBAPIProbe — runtime verification of IsoAnimal API surface.
--
-- Given an animal OID, the probe empirically confirms the API catalog's
-- claims about animal hunger/thirst state:
--
--   1. `animal:getStats():get(CharacterStat.HUNGER)` is the engine-authoritative
--      read, per vanilla ClientCommands.lua usage.
--   2. `animal:getStats():set(CharacterStat.HUNGER, v)` is the authoritative write.
--   3. `animal:getHunger()` is a separate getter that may or may not track
--      the authoritative value — the probe shows which, per-build.
--   4. `animal:updateLastTimeSinceUpdate()` exists as documented.
--
-- Output streams back to the requesting client via DEBUG_PROBE_RESULT,
-- appended to the panel's log pane one line at a time.
--
-- Non-destructive: the initial authoritative hunger value is restored after
-- the probe completes.

HBAPIProbe = {}

-- Mirror probe output to both the client (panel log) and the server console
-- so DebugLog.txt has a record too.
local function emit(player, line)
    local s = tostring(line)
    print("[HB probe] " .. s)
    if player then
        sendServerCommand(player, "RQ", HBCmd.DEBUG_PROBE_RESULT, { line = s })
    end
end

-- Safe read: returns (ok, value_or_err).
local function tryGet(fn)
    local ok, v = pcall(fn)
    return ok, v
end

local function fmt(v)
    if v == nil then return "nil" end
    if type(v) == "number" then return string.format("%.4f", v) end
    return tostring(v)
end

local function identity(animal)
    local name = "?"
    pcall(function() name = animal:getFullName() or animal:getCustomName() or "?" end)
    local species = "?"
    pcall(function() species = animal:getAnimalType() or "?" end)
    local sex = "?"
    pcall(function() sex = animal:isFemale() and "F" or "M" end)
    -- isBaby() is the only lifecycle flag confirmed in vanilla Lua — isYoung()
    -- has zero grep hits and was removed as an unverified claim.
    local age = "?"
    pcall(function() age = animal:isBaby() and "Baby" or "Adult" end)
    return name, species, sex, age
end

function HBAPIProbe.runOn(oid, player)
    emit(player, "─────────────────────────────")
    if not oid then
        emit(player, "[probe] no OID supplied")
        return
    end
    local animal = getAnimal(oid)
    if not animal then
        emit(player, "[probe] no animal loaded for OID " .. tostring(oid))
        return
    end

    local name, species, sex, age = identity(animal)
    emit(player, string.format("[probe] OID=%d  %s  %s  %s  %s",
        oid, tostring(name), tostring(species), tostring(sex), tostring(age)))

    -- ── Phase 1: read initial state through each candidate API ──────────

    local okStatH, statH = tryGet(function() return animal:getStats():get(CharacterStat.HUNGER) end)
    local okStatT, statT = tryGet(function() return animal:getStats():get(CharacterStat.THIRST) end)
    local okGetH,  getH  = tryGet(function() return animal:getHunger() end)
    local okGetT,  getT  = tryGet(function() return animal:getThirst() end)
    local okStr,   strs  = tryGet(function() return animal:getStats():get(CharacterStat.STRESS) end)

    emit(player, string.format("[probe] READ stats:get(HUNGER)=%s  getHunger()=%s",
        okStatH and fmt(statH) or ("ERR:" .. tostring(statH)),
        okGetH  and fmt(getH)  or ("ERR:" .. tostring(getH))))
    emit(player, string.format("[probe] READ stats:get(THIRST)=%s  getThirst()=%s",
        okStatT and fmt(statT) or ("ERR:" .. tostring(statT)),
        okGetT  and fmt(getT)  or ("ERR:" .. tostring(getT))))
    emit(player, string.format("[probe] READ stats:get(STRESS)=%s",
        okStr   and fmt(strs)  or ("ERR:" .. tostring(strs))))

    -- ── Phase 2: write via stats:set then re-read both APIs ─────────────

    local testVal = 0.42
    local okSet, errSet = pcall(function() animal:getStats():set(CharacterStat.HUNGER, testVal) end)
    if not okSet then
        emit(player, "[probe] stats:set(HUNGER, 0.42) ERROR: " .. tostring(errSet))
    else
        emit(player, "[probe] stats:set(HUNGER, 0.42) ok")
    end

    local _, statHafter = tryGet(function() return animal:getStats():get(CharacterStat.HUNGER) end)
    local _, getHafter  = tryGet(function() return animal:getHunger() end)
    emit(player, string.format("[probe] AFTER stats:set(HUNGER, 0.42):  stats:get=%s  getHunger()=%s",
        fmt(statHafter), fmt(getHafter)))

    -- Disagreement diagnostic
    if type(statHafter) == "number" and type(getHafter) == "number" then
        if math.abs(statHafter - getHafter) > 0.01 then
            emit(player, "[probe] ⚠ getHunger() does NOT track stats:get(HUNGER) — they are different fields")
        else
            emit(player, "[probe] ✓ getHunger() and stats:get(HUNGER) agree — same underlying value")
        end
    end

    -- ── Phase 3: check updateLastTimeSinceUpdate() existence ────────────

    local okU, errU = pcall(function() animal:updateLastTimeSinceUpdate() end)
    if okU then
        emit(player, "[probe] updateLastTimeSinceUpdate() ok — clock reset available")
    else
        emit(player, "[probe] updateLastTimeSinceUpdate() ERROR: " .. tostring(errU))
    end

    -- ── Phase 4: restore original hunger (non-destructive) ──────────────

    if okStatH and type(statH) == "number" then
        pcall(function() animal:getStats():set(CharacterStat.HUNGER, statH) end)
        emit(player, string.format("[probe] restored HUNGER to %s; done", fmt(statH)))
    else
        emit(player, "[probe] skipped restore (no valid initial value); done")
    end

    -- ── Phase 5: qualitative descriptors (skill-gated text per vanilla) ──
    -- Pattern: getXxxText(cheat, skillLvl). Cheat=true + skillLvl=10 yields
    -- the maximally-rich string. Used by vanilla ISAnimalUI for the in-game
    -- animal info window. Source: ISAnimalUI.lua:85,93,97.

    local _, healthTxt = tryGet(function() return animal:getHealthText(true, 10) end)
    local _, ageTxt    = tryGet(function() return animal:getAgeText(true, 10) end)
    local _, appearTxt = tryGet(function() return animal:getAppearanceText(true) end)
    emit(player, "[probe] healthText:    " .. tostring(healthTxt))
    emit(player, "[probe] ageText:       " .. tostring(ageTxt))
    emit(player, "[probe] appearanceTxt: " .. tostring(appearTxt))

    -- Genetic disorders: list of currently expressed disorder strings.
    local okGD, gd = pcall(function() return animal:getGeneticDisorder() end)
    if okGD and gd and gd.size then
        if gd:size() == 0 then
            emit(player, "[probe] geneticDisorders: (none expressed)")
        else
            local parts = {}
            for i = 0, gd:size() - 1 do parts[#parts + 1] = tostring(gd:get(i)) end
            emit(player, "[probe] geneticDisorders: " .. table.concat(parts, ", "))
        end
    else
        emit(player, "[probe] geneticDisorders: ERR " .. tostring(gd))
    end

    -- Acceptance toward the requesting player (bond / trust level).
    local _, accept = tryGet(function() return animal:getAcceptanceLevel(player) end)
    emit(player, "[probe] acceptance(toward you): " .. fmt(accept))
end
