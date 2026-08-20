-- SPDX-License-Identifier: GPL-3.0-or-later
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

-- Read vitals off a LIVE IsoAnimal. getHealth/getStats():get are trivial
-- field reads (stats is a final field; Stats.get is a map lookup), so no
-- guards are needed on a non-nil animal.
-- Returns a table shaped exactly like a scanned row's vitals fields, so
-- severity() below takes either without caring which it got.
function HBVitals.read(animal)
    local v = { hp = 0, hunger = 0, thirst = 0, stress = 0 }
    if not animal then return v end
    -- getHealth() is 0..1 for animals, NOT 0..100 like player getHealth.
    v.hp = (animal:getHealth() or 0) * 100
    local stats = animal:getStats()
    v.hunger = stats:get(CharacterStat.HUNGER) or 0
    v.thirst = stats:get(CharacterStat.THIRST) or 0
    v.stress = stats:get(CharacterStat.STRESS) or 0
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
    if not animal then return "?" end
    local name = animal:getCustomName()
    if (not name or name == "") and animal:getData() then
        -- getFullName dereferences AnimalData; an animal whose constructor
        -- bailed early has no data and falls through to its type instead
        -- (IsoAnimal.java:1185-1187, 2050-2065).
        name = animal:getFullName()
    end
    if not name or name == "" then
        name = animal:getAnimalType()
    end
    return name or "?"
end

print("[HB] HBVitals loaded (shared animal thresholds)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
