-- RQBloodhound fixture - a pursuit that always gives the zombie back.
--
-- The dangerous failure in this module is not "the chase did not start". It is a
-- special left sprinting forever because one exit path forgot to restore it. So
-- the bulk of what follows walks every way a pursuit can end and asserts the
-- movement profile came back, plus the two ways the snapshot itself could be
-- corrupted: re-capturing a profile from an already-sprinting zombie, and
-- restoring a Boss that is supposed to run permanently.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQBloodhound.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQBloodhound: " .. message)
    end
end

function isServer() return true end
function ZombRand(n) return 0 end

local debugMode = false
RQDirgeLog = { write = function() end }
RQCommon = { MODULE = "RFTDDirge" }
local enragedAnswer = true

-- The real capture/restore contract, mirrored. If production's snapshot shape
-- changes, these assertions stop meaning what they say - which is why the
-- restore test below compares against the values captured, not against
-- constants.
local applied = {}
RQSvShared = {
    getSvConfig = function() return { debugMode = debugMode } end,
    captureMovementProfile = function(z)
        if not z then return nil end
        return { walkType = z.walkType, speedType = z.speedType,
                 speedMod = z.speedMod, turnDelta = z.turnDelta }
    end,
    applySprintProfile = function(z)
        applied[#applied + 1] = z
        z.walkType, z.speedType, z.speedMod, z.turnDelta = "sprint1", 1, 0.85, 1.0
    end,
    restoreMovementProfile = function(z, snap)
        if not z or not snap then return false end
        z.walkType, z.speedType = snap.walkType, snap.speedType
        z.speedMod, z.turnDelta = snap.speedMod, snap.turnDelta
        return true
    end,
}
RQSvScavenger = { isEnraged = function() return enragedAnswer end }

function require(name)
    local known = { RQCommon = true, RQDirgeLog = true, RQSvShared = true, RQSvScavenger = true }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQBloodhound = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- Doubles
-- ---------------------------------------------------------------------------
local function makeZombie(id)
    return {
        id = id,
        x = 0, y = 0,
        walkType = "2", speedType = 2, speedMod = 0.55, turnDelta = 0.4,
        dead = false,
        targets = {}, aggro = {}, paths = {},
        getOnlineID = function(self) return self.id end,
        getModData  = function() return {} end,
        isDead      = function(self) return self.dead end,
        getX = function(self) return self.x end,
        getY = function(self) return self.y end,
        setTarget = function(self, t) self.targets[#self.targets + 1] = t end,
        addAggro  = function(self, t, d) self.aggro[#self.aggro + 1] = { t, d } end,
        pathToCharacter = function(self, t) self.paths[#self.paths + 1] = t end,
    }
end

local function makePlayer(x, y)
    return {
        x = x, y = y, dead = false, invisible = false, ghost = false, square = {},
        getX = function(self) return self.x end,
        getY = function(self) return self.y end,
        isDead      = function(self) return self.dead end,
        isInvisible = function(self) return self.invisible end,
        isGhostMode = function(self) return self.ghost end,
        getSquare   = function(self) return self.square end,
    }
end

local NOW = 100000
local function ctxFor(z, p, zType, isRanged, now)
    return { zombie = z, attacker = p, zType = zType,
             isRanged = isRanged ~= false, now = now or NOW }
end

-- ---------------------------------------------------------------------------
-- Who it refuses, by name
-- ---------------------------------------------------------------------------
local z = makeZombie(1)
local p = makePlayer(30, 0)

check(RQBloodhound.onAttacked(ctxFor(z, p, "Juggernaut", false)) == nil,
    "a melee hit does not start a pursuit")
check(RQBloodhound.stats.refused["not-ranged"] == 1, "and says why")

for _, t in ipairs({ "Screamer", "EMP", "Glutton" }) do
    check(RQBloodhound.onAttacked(ctxFor(makeZombie(9), p, t, true)) == nil,
        t .. " does not pursue - its own state machine would fight forced movement")
end
check(RQBloodhound.stats.refused["type-not-pursuing"] == 3, "each refusal is counted")

enragedAnswer = false
check(RQBloodhound.onAttacked(ctxFor(makeZombie(8), p, "Scavenger", true)) == nil,
    "a passive Scavenger does not pursue")
check(RQBloodhound.stats.refused["scavenger-passive"] == 1, "and says why")
enragedAnswer = true

local ghost = makePlayer(30, 0)
ghost.ghost = true
check(RQBloodhound.onAttacked(ctxFor(makeZombie(7), ghost, "Boss", true)) == nil,
    "an admin in ghost mode is never made a quarry")

-- ---------------------------------------------------------------------------
-- Acquisition
-- ---------------------------------------------------------------------------
applied = {}
check(RQBloodhound.onAttacked(ctxFor(z, p, "Juggernaut", true)) == true, "a ranged hit acquires")
local st = RQBloodhound.pursuits[z]
check(st ~= nil, "pursuit state exists")
check(st.quarry == p, "the shooter is the quarry")
check(#applied == 1 and applied[1] == z, "the sprint profile is applied once")
check(st.sprintApplied == true, "and recorded as applied")
check(st.profile.walkType == "2" and st.profile.speedMod == 0.55,
    "the snapshot holds the NATIVE profile, taken before the sprint")
check(z.targets[#z.targets] == p, "the quarry is set as the engine target")
check(#z.aggro == 1, "acquisition nudges aggro exactly once")
check(#z.paths == 1, "acquisition requests one path")

-- ---------------------------------------------------------------------------
-- Refresh must not corrupt the snapshot
-- ---------------------------------------------------------------------------
-- This is the bug that would strand a zombie at speed forever: re-capturing on
-- a second hit would record "sprint1" as its native profile.
RQBloodhound.onAttacked(ctxFor(z, p, "Juggernaut", true, NOW + 1000))
check(RQBloodhound.pursuits[z].profile.walkType == "2",
    "a second hit does NOT re-snapshot the now-sprinting zombie")
check(#applied == 1, "and does not re-apply the sprint")
check(RQBloodhound.stats.refreshed == 1, "a same-quarry hit counts as a refresh")

-- Most recent shooter wins.
local p2 = makePlayer(28, 0)
RQBloodhound.onAttacked(ctxFor(z, p2, "Juggernaut", true, NOW + 2000))
check(RQBloodhound.pursuits[z].quarry == p2, "the most recent shooter takes the quarry")
check(RQBloodhound.stats.replaced == 1, "replacement is counted separately from refresh")
check(RQBloodhound.pursuits[z].profile.walkType == "2",
    "replacing the quarry still does not touch the snapshot")

-- ---------------------------------------------------------------------------
-- Every exit restores
-- ---------------------------------------------------------------------------
local function freshPursuit(id, zType)
    local zz = makeZombie(id)
    local pp = makePlayer(40, 0)
    RQBloodhound.onAttacked(ctxFor(zz, pp, zType or "Juggernaut", true, NOW))
    return zz, pp
end

local function checkRestored(zz, label)
    check(zz.walkType == "2" and zz.speedType == 2
          and zz.speedMod == 0.55 and zz.turnDelta == 0.4,
          label .. ": every captured field is restored")
    check(RQBloodhound.pursuits[zz] == nil, label .. ": the pursuit row is dropped")
end

-- closing the distance
local z2, p2b = freshPursuit(2)
z2.x, z2.y = 38, 0                       -- inside CLOSE_DISTANCE of the quarry at 40
RQBloodhound.update(NOW + 100)
checkRestored(z2, "closed")
check(RQBloodhound.stats.exits["closed"] == 1, "the close-distance exit is named")

-- quarry dies
local z3, p3 = freshPursuit(3)
p3.dead = true
RQBloodhound.update(NOW + 100)
checkRestored(z3, "quarry dead")

-- quarry disconnects (no square)
local z4, p4 = freshPursuit(4)
p4.square = nil
RQBloodhound.update(NOW + 100)
checkRestored(z4, "quarry has no square")

-- quarry goes invisible mid-chase
local z5, p5 = freshPursuit(5)
p5.invisible = true
RQBloodhound.update(NOW + 100)
checkRestored(z5, "quarry invisible")

-- the zombie dies
local z6 = freshPursuit(6)
z6.dead = true
RQBloodhound.update(NOW + 100)
check(RQBloodhound.pursuits[z6] == nil, "a dead zombie's pursuit row is dropped")

-- timeout
local z7 = freshPursuit(7)
RQBloodhound.update(NOW + RQBloodhound.PURSUIT_TIMEOUT + 1)
checkRestored(z7, "timeout")
check(RQBloodhound.stats.exits["timeout"] == 1, "the timeout exit is named")

-- path failure
local z8 = freshPursuit(8)
RQBloodhound.pursuits[z8].pathFails = 99
RQBloodhound.update(NOW + 100)
checkRestored(z8, "path failed")

-- reset
local z9 = freshPursuit(9)
RQBloodhound.reset()
checkRestored(z9, "reset")

-- ---------------------------------------------------------------------------
-- The Boss is the exception
-- ---------------------------------------------------------------------------
-- It is a PERMANENT sprinter, applied at conversion and again on reload.
-- Restoring it to its captured profile would be tidy bookkeeping and wrong
-- behaviour - it would end each chase slower than it started.
applied = {}
local zb = makeZombie(10)
zb.walkType, zb.speedType, zb.speedMod, zb.turnDelta = "sprint3", 1, 0.9, 1.0
local pb = makePlayer(40, 0)
RQBloodhound.onAttacked(ctxFor(zb, pb, "Boss", true, NOW))
check(#applied == 0, "a Boss is not re-sprinted - it already runs")
check(RQBloodhound.pursuits[zb].sprintApplied == false,
    "and is not recorded as having had its movement changed")
zb.x = 38
RQBloodhound.update(NOW + 100)
check(zb.walkType == "sprint3" and zb.speedMod == 0.9,
    "ending a Boss pursuit leaves it running")
check(RQBloodhound.pursuits[zb] == nil, "the Boss pursuit row is still dropped")

-- ---------------------------------------------------------------------------
-- Repath is bounded
-- ---------------------------------------------------------------------------
local z11, p11 = freshPursuit(11)
local pathsAfterAcquire = #z11.paths
for i = 1, 30 do
    RQBloodhound.update(NOW + i * 10)     -- quarry stationary, no time elapsed
end
check(#z11.paths == pathsAfterAcquire,
    "a stationary quarry earns no repaths at all: " .. #z11.paths)

p11.x = p11.x + 10                        -- moved well past the threshold
RQBloodhound.update(NOW + 5000)
check(#z11.paths == pathsAfterAcquire + 1, "a quarry that moved earns exactly one repath")

-- Target is re-set every pass even when no path is requested; setTarget on an
-- unchanged target is a Java no-op, and it is what keeps the quarry pinned if
-- something else clears it.
check(#z11.targets > 1, "the target is reasserted while pursuing")
RQBloodhound.endPursuit(z11, "test")

-- ---------------------------------------------------------------------------
-- update() only walks live pursuits
-- ---------------------------------------------------------------------------
for zz in pairs(RQBloodhound.pursuits) do RQBloodhound.endPursuit(zz, "test") end
check(RQBloodhound.update(NOW) == 0, "an empty pursuit table costs one empty walk")
local za = freshPursuit(12)
local zc = freshPursuit(13)
check(RQBloodhound.update(NOW + 50) == 2, "update reports the live pursuit count")
RQBloodhound.reset()
check(RQBloodhound.update(NOW + 60) == 0, "reset leaves nothing pursuing")

print(string.format("RQBloodhound: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
