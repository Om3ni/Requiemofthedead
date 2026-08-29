-- RQMcCoy fixture - every ceiling, and every reason not to write.
--
-- Two classes of failure matter here and they pull in opposite directions. Heal
-- too freely and a special becomes unkillable by some weapon classes, or an
-- enraged Scavenger outruns the ten-minute decay that is supposed to end its
-- rage. Heal too timidly - or resolve a ceiling as "wherever you are now" - and
-- the feature silently does nothing, which is worse because it looks fine.
-- So: the ceilings are pinned per type, and every skip path is pinned by name.

local ROOT = arg[1] or "."
local CEILING_SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQCeiling.lua"
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQMcCoy.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQMcCoy: " .. message)
    end
end

function isServer() return true end

-- RQCeiling requires RDShared (badNum, its save-data type gate), and this
-- dofile runs BEFORE the fixture's own require stub further down - so the stub
-- has to exist by here or the real Lua loader goes hunting for a .dll. The REAL
-- RDShared, not a stub: the type gate keys on badNum's exact semantics.
function require(name)
    if name == "RDShared" then
        dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")
        return
    end
    error("unexpected fixture require before load: " .. tostring(name))
end

RQCeiling = nil
dofile(CEILING_SOURCE)

local debugMode = false
local writes = {}
local authority = true
RQDirgeLog = { write = function() end }
RQCommon = {
    MODULE = "RFTDDirge",
    HEALTH_MULTIPLIER = {
        Screamer = 2, Juggernaut = 10, EMP = 2, Glutton = 2, Scavenger = 2, Boss = 10,
    },
}
RQSvShared = {
    MAX_NETWORK_HP = 30.0,
    getSvConfig = function()
        return { debugMode = debugMode, juggernautHealthMultiplier = 10, gluttonMaxMult = 5 }
    end,
    svSetZombieHP = function(z, hp)
        if not authority then return false end
        writes[#writes + 1] = { z = z, hp = hp }
        z.hp = hp
        return true
    end,
}
RQSvGlutton   = { state = {} }
RQSvScavenger = { state = {} }

function require(name)
    local known = { RQCommon = true, RQCeiling = true, RQDirgeLog = true,
                    RQSvShared = true, RQSvGlutton = true, RQSvScavenger = true,
                    RDShared = true }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQMcCoy = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local nextId = 0
local function makeZombie(baseHP, hp, md)
    nextId = nextId + 1
    local m = md or {}
    if baseHP then m["RQBaseHP"] = baseHP end
    local id = nextId
    local z
    z = {
        hp = hp, dead = false,
        getOnlineID = function() return id end,
        getModData  = function() return m end,
        isDead      = function() return z.dead end,
        getHealth   = function() return z.hp end,
    }
    return z
end

local cfg = RQSvShared.getSvConfig()

-- ---------------------------------------------------------------------------
-- Ceilings, per type
-- ---------------------------------------------------------------------------
-- base * multiplier for the four types with no growth mechanic. These are the
-- ones that could not reconstruct a ceiling at all before RQBaseHP existed.
local function ceilOf(z, t) return (RQMcCoy.ceilingFor(z, t, cfg)) end

check(ceilOf(makeZombie(2.0, 1.0), "Screamer") == 4.0, "Screamer ceiling is base x2")
check(ceilOf(makeZombie(2.0, 1.0), "EMP") == 4.0, "EMP ceiling is base x2")
check(ceilOf(makeZombie(2.0, 1.0), "Boss") == 20.0, "Boss ceiling is base x10")
check(ceilOf(makeZombie(2.0, 1.0), "Juggernaut") == 20.0,
    "Juggernaut ceiling follows the sandbox multiplier, not a stored number")

-- A retuned multiplier must move the ceiling. This is the whole reason the BASE
-- is stored rather than the ceiling itself.
local jug = makeZombie(2.0, 1.0)
local retuned = { debugMode = false, juggernautHealthMultiplier = 6, gluttonMaxMult = 5 }
check((RQMcCoy.ceilingFor(jug, "Juggernaut", retuned)) == 12.0,
    "lowering JuggernautHealthMultiplier lowers the ceiling of an existing Juggernaut")

-- ---------------------------------------------------------------------------
-- Growth types
-- ---------------------------------------------------------------------------
-- A Glutton that has never eaten gets base x2 and NOT the theoretical cap.
local g = makeZombie(2.0, 1.0)
RQSvGlutton.state[g:getOnlineID()] = { totalMultGain = 0 }
check(ceilOf(g, "Glutton") == 4.0, "an unfed Glutton is not entitled to the feeding cap")

local g2 = makeZombie(2.0, 1.0)
RQSvGlutton.state[g2:getOnlineID()] = { totalMultGain = 1.0 }
check(ceilOf(g2, "Glutton") == 8.0, "a fed Glutton's ceiling reflects what it actually ate")

-- ---------------------------------------------------------------------------
-- Rage decay must not be defeated
-- ---------------------------------------------------------------------------
-- The frozen peak wins outright, with no multiplier applied. Decay walks that
-- number down; if McCoy derived a ceiling from the base instead, healing would
-- climb back above the decay target and the ten-minute timer would never end
-- the rage.
local sc = makeZombie(2.0, 5.0)
RQSvScavenger.state[sc:getOnlineID()] = { hostile = true, peakHP = 12.0 }
check(ceilOf(sc, "Scavenger") == 12.0, "an enraged Scavenger's ceiling is its frozen rage peak")

RQSvScavenger.state[sc:getOnlineID()].peakHP = 6.0    -- decay has walked it down
check(ceilOf(sc, "Scavenger") == 6.0,
    "as decay lowers the peak, the healing ceiling follows it down")

local sp = makeZombie(2.0, 1.0)
RQSvScavenger.state[sp:getOnlineID()] = { hostile = false, totalMultGain = 0.5 }
check(ceilOf(sp, "Scavenger") == 6.0, "a passive Scavenger uses its fed ceiling, not a rage peak")

-- ---------------------------------------------------------------------------
-- Legacy zombies, converted before RQBaseHP existed
-- ---------------------------------------------------------------------------
local legacyJug = makeZombie(nil, 5.0, { RQJuggMaxHP = 20.0 })
check(ceilOf(legacyJug, "Juggernaut") == 20.0,
    "a pre-RQBaseHP Juggernaut recovers its base from RQJuggMaxHP")

local legacyGlut = makeZombie(nil, 3.0, { RQGluttonBaseHealth = 4.0 })
RQSvGlutton.state[legacyGlut:getOnlineID()] = { totalMultGain = 0 }
check(ceilOf(legacyGlut, "Glutton") == 4.0,
    "a pre-RQBaseHP Glutton recovers its base from RQGluttonBaseHealth")

-- Nothing to go on at all: refuse rather than invent.
local orphan = makeZombie(nil, 3.0, {})
local c, how = RQMcCoy.ceilingFor(orphan, "Screamer", cfg)
check(c == nil and how == "unreconstructable",
    "a special with no stored evidence is refused by name rather than given a guess")

-- Current health floors the ceiling - a zombie inflated by the old aura model
-- must not read as "below its ceiling by a negative amount".
local inflated = makeZombie(2.0, 9.0)
check(ceilOf(inflated, "Screamer") == 9.0, "current health floors the ceiling")

-- ---------------------------------------------------------------------------
-- Arming
-- ---------------------------------------------------------------------------
local NOW = 50000
local target = makeZombie(2.0, 1.0)
RQMcCoy.onAttacked{ zombie = target, zType = "Boss", now = NOW }
local w = RQMcCoy.windows[target]
check(w ~= nil, "an attack arms a window")
check(w.expiresAt == NOW + RQMcCoy.WINDOW_MS, "the window runs from the hit")
check(w.nextDueAt == NOW + RQMcCoy.CADENCE_MS,
    "the first heal is one cadence out, not on the same tick as the blow")

RQMcCoy.onAttacked{ zombie = target, zType = "Boss", now = NOW + 3000 }
check(RQMcCoy.windows[target].expiresAt == NOW + 3000 + RQMcCoy.WINDOW_MS,
    "a further hit extends the window")
check(RQMcCoy.stats.armed == 1 and RQMcCoy.stats.refreshed == 1,
    "arming and refreshing are counted apart")

-- ---------------------------------------------------------------------------
-- Healing
-- ---------------------------------------------------------------------------
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 1, "the first cadence tick heals")
-- Boss ceiling 20.0, 1% = 0.2
check(math.abs(writes[1].hp - 1.2) < 1e-9,
    "healed one percent of the ceiling, not of current health: " .. tostring(writes[1].hp))

-- Cadence holds: ticks between deadlines do nothing.
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS + 100)
check(#writes == 0, "no heal between cadence deadlines")

-- Window expiry stops it.
writes = {}
RQMcCoy.update(NOW + 3000 + RQMcCoy.WINDOW_MS + 1)
check(#writes == 0, "an expired window heals nothing")
check(RQMcCoy.windows[target] == nil, "and is dropped")
check(RQMcCoy.stats.expired >= 1, "expiry is counted")

-- ---------------------------------------------------------------------------
-- Every reason not to write
-- ---------------------------------------------------------------------------
local function armed(z, t, now)
    RQMcCoy.onAttacked{ zombie = z, zType = t, now = now }
    return RQMcCoy.windows[z]
end

-- A LETHAL HIT STAYS LETHAL. This is the one that would be a resurrection bug.
local dying = makeZombie(2.0, 0.5)
armed(dying, "Boss", NOW)
dying.dead = true
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 0, "a dead target is never healed")
check(RQMcCoy.windows[dying] == nil, "and its window is dropped rather than left to fire late")
check(RQMcCoy.stats.skipped["dead"] >= 1, "the dead skip is named")

local zeroed = makeZombie(2.0, 0)
armed(zeroed, "Boss", NOW)
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 0, "a zero-health target is never healed")
check(RQMcCoy.stats.skipped["zero-health"] >= 1, "the zero-health skip is named")

-- At the ceiling: no no-op packet.
local full = makeZombie(2.0, 20.0)
armed(full, "Boss", NOW)
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 0, "a target already at its ceiling produces no HP write")
check(RQMcCoy.stats.skipped["at-ceiling"] >= 1, "the at-ceiling skip is named")

-- No ceiling, no heal.
local unknown = makeZombie(nil, 3.0, {})
armed(unknown, "Screamer", NOW)
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 0, "a target with no reconstructable ceiling is not healed")

-- Ownership: a failed placement is not counted as a heal.
local unowned = makeZombie(2.0, 1.0)
armed(unowned, "Boss", NOW)
authority = false
writes = {}
local writesBefore = RQMcCoy.stats.writes
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(RQMcCoy.stats.writes == writesBefore, "a refused HP placement is not counted as a write")
check(RQMcCoy.stats.skipped["no-authority"] >= 1, "the authority skip is named")
authority = true

-- ---------------------------------------------------------------------------
-- The network cap
-- ---------------------------------------------------------------------------
-- ZombiePacket.health is a signed short applied as health/1000. Nothing may
-- ever aim above the cap, however large a ceiling says it should be.
local huge = makeZombie(100.0, 29.95)
armed(huge, "Boss", NOW)
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 1, "a target below the cap still heals")
check(writes[1].hp <= 30.0, "no write ever exceeds MAX_NETWORK_HP: " .. tostring(writes[1].hp))

local atCap = makeZombie(100.0, 30.0)
armed(atCap, "Boss", NOW)
writes = {}
RQMcCoy.update(NOW + RQMcCoy.CADENCE_MS)
check(#writes == 0, "a target already at the network cap produces no write")

-- ---------------------------------------------------------------------------
-- update() walks only armed windows
-- ---------------------------------------------------------------------------
RQMcCoy.reset()
check(RQMcCoy.update(NOW) == 0, "an empty window table costs one empty walk")
armed(makeZombie(2.0, 1.0), "Boss", NOW)
armed(makeZombie(2.0, 1.0), "Juggernaut", NOW)
check(RQMcCoy.update(NOW + 10) == 2, "update reports the live window count")
RQMcCoy.reset()
check(RQMcCoy.update(NOW + 20) == 0, "reset clears every window")

print(string.format("RQMcCoy: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
