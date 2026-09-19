-- RQDread fixture - who projects, the two radii, the fail-safe, and that the
-- term registers into RQSuppress and nowhere else.
--
-- The snapshot, linger and restore are RQSuppress's and have their own
-- fixture; this one only asks the question RQDread answers: how much, right
-- now, for this player.

local ROOT = arg[1] or "."
local LUA = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQDread: " .. message) end
end

-- ---------------------------------------------------------------------------
-- Engine surface
-- ---------------------------------------------------------------------------
local cfg = { suppressPercent = 40, suppressRadius = 3 }
RQConfig = { get = function() return cfg end }
RQRegistry = { activeZombies = {} }
RQReconcile = { scavClientState = {} }
local registered = {}
RQSuppress = { register = function(g, s, fn) registered[#registered + 1] = { group = g, source = s, fn = fn } end }
local world = {}
RQCore = { findZombieByID = function(oid) return world[oid] end }
function require(name)
    if name == "RQConfig" or name == "RQRegistry" or name == "RQReconcile" or name == "RQSuppress" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQDread = nil
local ok, err = pcall(dofile, LUA .. "/client/RQDread.lua")
check(ok, "module loads: " .. tostring(err))
check(#registered == 1 and registered[1].group == "dread" and registered[1].source == "dirge",
    "exactly one term registers, in its own group")

local function place(oid, zType, x, y, z)
    RQRegistry.activeZombies[oid] = zType
    world[oid] = { getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end }
end
local pos = { x = 0, y = 0, z = 0 }
local player = { getX = function() return pos.x end, getY = function() return pos.y end, getZ = function() return pos.z end }
local melee = {}
local gun = { isAimedFirearm = function() return true end }
local resolve = RQCore.findZombieByID
local function mult(weapon) return RQDread.multiplier(player, weapon, cfg, resolve) end

-- ---------------------------------------------------------------------------
-- The fail-safe
-- ---------------------------------------------------------------------------
place(1, "Juggernaut", 0, 1)
check(mult(melee) == 0.4, "inside the ring a melee weapon keeps the configured share")
check(RQDread.multiplier(player, melee, { suppressPercent = nil, suppressRadius = 3 }, resolve) == nil,
    "an unreadable percent suppresses nothing")
check(RQDread.multiplier(player, melee, { suppressPercent = 40, suppressRadius = nil }, resolve) == nil,
    "an unreadable radius suppresses nothing")
check(RQDread.multiplier(player, melee, { suppressPercent = 100, suppressRadius = 3 }, resolve) == nil,
    "100 percent kept means the feature is off")
check(RQDread.multiplier(player, melee, { suppressPercent = 40, suppressRadius = 0 }, resolve) == nil,
    "a zero radius disables it")
check(RQDread.multiplier(player, melee, { suppressPercent = -5, suppressRadius = 3 }, resolve) == 0,
    "a negative percent clamps to zero damage, never to a negative multiplier")

-- ---------------------------------------------------------------------------
-- The two bands
-- ---------------------------------------------------------------------------
-- Melee radius 3, firearm band 6. A player at 4.5 tiles is outside the ring and
-- inside the band: a swing is clean, a shot is not. This is the kiting counter.
pos.y = 4.5
check(mult(melee) == nil, "a melee weapon at 4.5 tiles is outside the ring and clean")
check(mult(gun) == 0.4, "a firearm at the same distance IS suppressed")
pos.y = 7    -- the protector stands at y=1, so this is exactly six tiles
check(mult(gun) == 0.4, "the firearm band is inclusive at exactly twice the radius")
pos.y = 7.5
check(mult(gun) == nil, "and past it even a firearm is clean")
-- Two melee hits so far: the first check and the negative-percent clamp, which
-- is still a band hit that answered.
check(RQDread.stats.meleeBand == 2 and RQDread.stats.rangedBand == 2, "the counters split the two bands")

-- The term goes through the registered predicate with the live config.
pos.y = 1
check(registered[1].fn(player, melee) == 0.4, "the registered term answers from RQConfig")

-- ---------------------------------------------------------------------------
-- Who projects
-- ---------------------------------------------------------------------------
RQRegistry.activeZombies, world = {}, {}
place(2, "Screamer", 0, 1)
place(3, "EMP", 0, 1)
place(4, "Glutton", 0, 1)
check(mult(melee) == nil, "Screamers, EMPs and Gluttons project nothing")

place(5, "Scavenger", 0, 1)
check(mult(melee) == nil, "a passive Scavenger projects nothing - it is a sleeper")
RQReconcile.scavClientState[5] = { enraged = true }
check(mult(melee) == 0.4, "an enraged Scavenger projects")
RQReconcile.scavClientState[5] = nil

RQRegistry.activeZombies, world = {}, {}
place(6, "Boss", 0, 1)
check(mult(melee) == 0.4, "a Boss projects")

-- A floor is not transparent: a protector downstairs must not weaken a swing here.
RQRegistry.activeZombies, world = {}, {}
place(7, "Juggernaut", 0, 1, 1)
check(mult(melee) == nil, "a Juggernaut on another floor projects no ring")

-- Known to the registry but not loaded here: no projection, no error.
RQRegistry.activeZombies, world = {}, {}
RQRegistry.activeZombies[8] = "Juggernaut"
check(mult(melee) == nil, "a registered special that is not loaded here projects nothing")

-- Nothing registered at all.
RQRegistry.activeZombies = {}
check(mult(gun) == nil, "with no specials the weapon is untouched")

print(string.format("RQDread: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
