-- HBVitals - one set of thresholds for "is this animal in trouble".
--
-- WHY THIS EXISTS. Two views now answer the same question about the same
-- animals: the Animals list (which of these needs me) and the Hutches occupant
-- pane (what is inside this coop). Written twice they WILL drift, and a
-- threshold that disagrees between two panels in the same tab is worse than
-- either threshold - you stop trusting both.
--
-- THE SCALES ARE NOT THE SAME DIRECTION, which is the whole reason this is a
-- module and not four inline comparisons:
--
--   hunger / thirst / stress   0..1, where 1 is WORST
--   health                     0..100, where 0 is worst
--
-- HBKeepAlive.lua:48 sets HUNGER to 0 to keep an animal alive, and the old
-- "starve all" debug button set it to 0.9 - that is the proof of direction.
-- Health is 0..1 from the engine; HBDebugPanel.buildRow already multiplies by
-- 100, so anything reading a scanned row gets percent and anything reading a
-- live IsoAnimal has to do the same conversion. read() below does it.
--
-- AUTHORITATIVE READS ONLY. getHunger() / getThirst() are a SECOND API that may
-- or may not track the stats the engine actually writes - HBAPIProbe.lua:6-9
-- settled that getStats():get is the real one, and every writer in the mod
-- (HBKeepAlive.lua:48-49, HBCommands.lua:91-92) goes through getStats():set().
-- The old twin-column display of both is gone; this reads the one that counts.

if isServer() then return end

HBVitals = HBVitals or {}

-- Read vitals off a LIVE IsoAnimal. Every accessor is pcall-wrapped so one
-- broken method cannot kill the caller's whole row.
-- Returns a table shaped exactly like a scanned row's vitals fields, so
-- severity() below takes either without caring which it got.
function HBVitals.read(animal)
    local v = { hp = 0, hunger = 0, thirst = 0, stress = 0 }
    if not animal then return v end
    -- getHealth() is 0..1 for animals, NOT 0..100 like player getHealth.
    pcall(function() v.hp = (animal:getHealth() or 0) * 100 end)
    pcall(function() v.hunger = animal:getStats():get(CharacterStat.HUNGER) or 0 end)
    pcall(function() v.thirst = animal:getStats():get(CharacterStat.THIRST) or 0 end)
    pcall(function() v.stress = animal:getStats():get(CharacterStat.STRESS) or 0 end)
    return v
end

-- Level 0 (fine) .. 3 (urgent), plus the word a UI shows.
-- Highest bid wins, so the reason names what is actually worst - not whichever
-- check happened to run last.
function HBVitals.severity(v)
    if not v then return 0, "" end
    local worst, why = 0, ""
    local function bid(level, reason)
        if level > worst then worst, why = level, reason end
    end

    local hp = v.hp or 100
    if hp < 30 then bid(3, "hurt") elseif hp < 60 then bid(2, "injured") end

    local hng = v.hunger or 0
    if hng >= 0.75 then bid(3, "starving") elseif hng >= 0.50 then bid(2, "hungry") end

    local thr = v.thirst or 0
    if thr >= 0.75 then bid(3, "parched") elseif thr >= 0.50 then bid(2, "thirsty") end

    local str = v.stress or 0
    if str >= 0.75 then bid(2, "stressed") elseif str >= 0.50 then bid(1, "restless") end

    return worst, why
end

-- Colour + alpha for a severity level. Returns a DFKit token, so a skin
-- repaints these along with everything else.
function HBVitals.sevColor(level)
    local c = DFKit.col
    if (level or 0) >= 3 then return c.danger, 0.95 end
    if (level or 0) >= 2 then return c.warn,   0.90 end
    if (level or 0) >= 1 then return c.warn,   0.45 end
    return c.ok, 0
end

-- Bar colour for a 0..1 fraction. `invert` for values where HIGH is good (hp).
function HBVitals.barColor(frac, invert)
    local bad = invert and (1 - (frac or 0)) or (frac or 0)
    local c = DFKit.col
    if bad >= 0.75 then return c.danger end
    if bad >= 0.50 then return c.warn end
    return c.ok
end

-- A short name for an animal, preferring what the player called it.
function HBVitals.nameOf(animal)
    local name
    pcall(function()
        local n = animal:getCustomName()
        if n and n ~= "" then name = n else name = animal:getFullName() end
    end)
    if not name or name == "" then
        pcall(function() name = animal:getAnimalType() end)
    end
    return name or "?"
end

print("[HB] HBVitals loaded (shared animal thresholds)")
