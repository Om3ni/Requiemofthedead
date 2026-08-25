-- RQSvShared fixture - owner-only health sync sends to an established owner,
-- leaves server-owned zombies local, and only broadcasts when explicitly asked.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua"
local CHARGE_SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQChargeLevy.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvShared: " .. message)
    end
end

function isServer() return true end
RQChargeLevy = nil
dofile(CHARGE_SOURCE)
function require(name)
    if name == "RQChargeLevy" then return RQChargeLevy end
    error("unexpected fixture require: " .. tostring(name))
end

local enumNames = {
    "SCREAMER_INTERVAL", "SCREAMER_CAST", "SCREAMER_RANGE", "SCREAMER_SOUND",
    "SCREAMER_SPAWN_MIN", "SCREAMER_SPAWN_MAX", "SCREAMER_THRESHOLD", "JUGG_RADIUS",
    "JUGG_BUFF", "EMP_RANGE", "EMP_CAST", "EMP_RADIUS", "EMP_DRAIN", "GLUTTON_RADIUS",
    "GLUTTON_MULT", "BOSS_COOLDOWN", "CAST_4",
}
local enums = {}
for i = 1, #enumNames do enums[enumNames[i]] = {} end
RQCommon = {
    MODULE = "RFTDDirge",
    -- The real shape from RQCommon.lua:103 - a per-type TABLE. The old stub
    -- said `= 2`, which nothing ever dereferenced until getSvConfig became
    -- callable from this fixture; a stub that lies about a shape passes right
    -- up until the first honest read.
    HEALTH_MULTIPLIER = {
        Screamer   = 2,
        Juggernaut = 10,
        EMP        = 2,
        Glutton    = 2,
        Scavenger  = 2,
        Boss       = 10,
    },
    JUGGERNAUT_MIN_BASE_HEALTH = 100,
    ENUMS = enums,
    -- Value-or-default, matching the real resolvers closely enough for
    -- getSvConfig to be CALLABLE from a test. The old always-nil stubs made
    -- `sev(...) * 1000` throw, so no fixture could ever reach the config
    -- builder - which is where the DebugMode wiring under test now lives.
    ev = function(_, value, default) return value or default end,
    pct = function(value, default) return value or default end,
}
RQDirgeLog = { write = function() end }
RDAccess = { meetsTier = function() return false end }
MoodleType = { ENDURANCE = "Endurance" }
CharacterStat = { ENDURANCE = "Endurance" }

local commands = {}
function sendServerCommand(target, module, command, payload)
    commands[#commands + 1] = { target = target, module = module, command = command, payload = payload }
end

RQSvShared = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local owner = { username = "owner" }
local health = nil
local zombie = {
    setHealth = function(_, value) health = value end,
    getOnlineID = function() return 42 end,
    getX = function() return 10.9 end,
    getY = function() return 20.1 end,
    getZ = function() return 0 end,
    getOwnerPlayer = function() return owner end,
}

check(RQSvShared.svSetZombieHP(zombie, 25, true), "owner-only update reports authoritative delivery")
check(health == 25, "owner-only update sets server health first")
check(#commands == 1 and commands[1].target == owner and commands[1].command == "applyZombieHP",
    "owner-only update targets the owning client")
check(commands[1] and commands[1].payload.onlineID == 42 and commands[1].payload.targetHP == 25,
    "owner delivery retains the exact authoritative payload")

zombie.getOwnerPlayer = function() return nil end
check(RQSvShared.svSetZombieHP(zombie, 26, true), "server-owned update remains authoritative")
check(#commands == 1, "server-owned update does not broadcast a redundant packet")

check(RQSvShared.svSetZombieHP(zombie, 27, false), "explicit broadcast update reports delivery")
check(#commands == 2 and commands[2].target == RQCommon.MODULE,
    "non-owner-only update uses the normal broadcast path")

local function makePlayer(enduranceLevel, currentEndurance)
    local statsValue = currentEndurance
    return {
        getMoodles = function()
            return {
                getMoodleLevel = function(_, moodle)
                    check(moodle == MoodleType.ENDURANCE, "EMP endurance drain reads the endurance moodle")
                    return enduranceLevel
                end,
            }
        end,
        getStats = function()
            return {
                get = function(_, stat)
                    check(stat == CharacterStat.ENDURANCE, "EMP endurance drain reads endurance stat")
                    return statsValue
                end,
                set = function(_, stat, value)
                    check(stat == CharacterStat.ENDURANCE, "EMP endurance drain writes endurance stat")
                    statsValue = value
                end,
            }
        end,
        getEndurance = function() return statsValue end,
    }
end

local tiredPlayer = makePlayer(1, 0.9)
RQSvShared.svApplyEMPEnduranceDrain(tiredPlayer)
check(tiredPlayer:getEndurance() == 0.40, "EMP endurance drain lowers endurance to the moodle target")

local exhaustedPlayer = makePlayer(2, 0.10)
RQSvShared.svApplyEMPEnduranceDrain(exhaustedPlayer)
check(exhaustedPlayer:getEndurance() == 0.10, "EMP endurance drain does not heal players already below target")

local maxMoodlePlayer = makePlayer(4, 0.9)
RQSvShared.svApplyEMPEnduranceDrain(maxMoodlePlayer)
check(maxMoodlePlayer:getEndurance() == 0.9, "EMP endurance drain leaves max endurance moodle alone")

local spawnCalls = 0
local spawnResults = {}
local spawnSquare = { isSolid = function() return false end }
function getCell()
    return { getGridSquare = function() return spawnSquare end }
end
function getTimestampMs() return 1234 end
function ZombRand() return 0 end
local function javaList(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end
function addZombiesInOutfit()
    spawnCalls = spawnCalls + 1
    return javaList(spawnResults[spawnCalls] or {})
end

local newborn = { id = 1 }
spawnResults = { {}, { newborn } }
local handled = {}
local spawned = RQSvShared.svDoSpawn(10, 20, 0, 1, function(zed)
    handled[#handled + 1] = zed
end)
check(spawned == 1 and spawnCalls == 2, "an empty engine result costs an attempt and is retried")
check(#handled == 1 and handled[1] == newborn, "only returned newborns reach the handler")

spawnCalls = 0
spawnResults = { { { id = 2 } }, { { id = 3 } } }
local realPrint = print
local warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
spawned = RQSvShared.svDoSpawn(10, 20, 0, 2, function(zed)
    error("newborn " .. tostring(zed.id) .. " failed")
end)
print = realPrint
check(spawned == 2 and spawnCalls == 2, "one callback failure does not abort later newborns")
check(#warnings == 1 and warnings[1]:find("2 of 2", 1, true)
    and warnings[1]:find("newborn 2 failed", 1, true),
    "callback failures produce one bounded summary with the first error")

function instanceof(value, className) return value and value.className == className end
local shutDown, smashed = 0, 0
local blastSquare
local radio = { className = "IsoRadio" }
local device = {
    getParent = function() return radio end,
    getIsTurnedOn = function() return true end,
    setIsTurnedOn = function(_, value)
        check(value == false, "EMP shutdown passes the engine's off state")
        shutDown = shutDown + 1
    end,
}
radio.getDeviceData = function() return device end
radio.getSquare = function() return blastSquare end
local window = {
    className = "IsoWindow",
    getSquare = function() return blastSquare end,
    isSmashed = function() return false end,
    smashWindow = function() smashed = smashed + 1 end,
}
blastSquare = {
    getObjects = function() return javaList({ radio, window }) end,
}
function getCell()
    return { getGridSquare = function() return blastSquare end }
end
RQSvShared.svDamageWorldElectronics(10, 20, 0, 0, 25)
check(shutDown == 1 and smashed == 1, "EMP directly mutates live radios and windows")

device.getParent = function() return nil end
window.getSquare = function() return nil end
RQSvShared.svDamageWorldElectronics(10, 20, 0, 0, 25)
check(shutDown == 1 and smashed == 1, "EMP skips world objects detached during the scan")

device.getParent = function() return radio end
window.getSquare = function() return blastSquare end
device.setIsTurnedOn = function() error("fixture shutdown fault") end
check(not pcall(RQSvShared.svDamageWorldElectronics, 10, 20, 0, 0, 25),
    "an unexpected live-object mutation fault is not swallowed")

-- ---------------------------------------------------------------------------
-- RQSvShared.due - the one cadence gate
-- ---------------------------------------------------------------------------
-- These pin the three properties every caller in the mod leans on: a fresh
-- state row fires immediately, a stamped one stays shut for the full interval,
-- and the clock is the caller's wall clock rather than a count of calls. That
-- last one is the whole reason the helper exists - the Juggernaut aura used to
-- gate on a tick count and so stretched silently whenever OnTick sagged.

local st = {}
check(RQSvShared.due(st, "k", 1000, 5000) == true,
    "a key that has never fired is due immediately")
check(st.k == 5000, "firing stamps the deadline on the caller's table")
check(RQSvShared.due(st, "k", 1000, 5999) == false,
    "a key stays shut for the whole interval")
check(st.k == 5000, "a refused call does not move the stamp")
check(RQSvShared.due(st, "k", 1000, 6000) == true,
    "the boundary is inclusive - exactly one interval later is due")
check(st.k == 6000, "firing at the boundary re-stamps")

-- Independent keys on one row. svOnTick keeps every cadence in a single table,
-- so a fast gate must not hold a slow one open or vice versa.
local multi = {}
RQSvShared.due(multi, "fast", 250, 1000)
check(RQSvShared.due(multi, "slow", 2000, 1000) == true,
    "a second key on the same row is judged on its own stamp")
check(RQSvShared.due(multi, "fast", 250, 1100) == false,
    "stamping one key does not disturb another")

-- A zero stamp is a real stamp, not an absent one. RQSvBoss seeds
-- lastBuffTick = 0 at state creation, and Lua's only falsey values are nil and
-- false - so 0 must be read as "fired at time zero", which is long overdue.
local zeroed = { lastBuffTick = 0 }
check(RQSvShared.due(zeroed, "lastBuffTick", 2000, 50000) == true,
    "a zero stamp reads as long overdue, matching the Boss's seeded state")

-- Callers pass a table they already own; a nil row means "no state to throttle
-- against", which must not throw inside a per-tick loop.
check(RQSvShared.due(nil, "k", 1000, 1) == true,
    "a nil state row is treated as due rather than raising")

-- ---------------------------------------------------------------------------
-- Movement writes must reach the OWNING CLIENT
-- ---------------------------------------------------------------------------
-- The regression: a server-side setWalkType/setSpeedMod on a client-owned
-- zombie is erased by that client's next sync (NetworkZombiePacker.applyZombie
-- :251-252 re-applies the packet's walk type unconditionally). On 2026-08-24
-- Bloodhound logged sprint=true while the owner watched a Juggernaut walk, and
-- the hit probe reported owner=client on 90 of 90 hits - so this is the normal
-- case, not a corner. Delivery now mirrors svSetZombieHP's ownerOnly branch.
local moveOwner = { username = "mover" }
local moved = {}
local moveZombie = {
    getOnlineID = function() return 77 end,
    getX = function() return 5.4 end,
    getY = function() return 6.6 end,
    getZ = function() return 0 end,
    getOwnerPlayer = function() return moveOwner end,
    setWalkType              = function(_, v) moved.walkType = v end,
    setSpeedTypeFromWalkType = function() moved.derived = true end,
    setSpeedMod              = function(_, v) moved.speedMod = v end,
    setTurnDelta             = function(_, v) moved.turnDelta = v end,
    resetModelNextFrame      = function() moved.reset = true end,
}

commands = {}
check(RQSvShared.applySprintProfile(moveZombie), "a sprint on a client-owned zombie reports delivery")
check(moved.walkType and moved.walkType:sub(1, 6) == "sprint",
    "the sprint uses a real sprintN walk type, not a name the wire would flatten to WT1")
check(moved.derived == true, "speed type is derived from the walk type, never written directly")
check(#commands == 1 and commands[1].target == moveOwner
      and commands[1].command == "applyZombieMovement",
    "the sprint is handed to the OWNING CLIENT, whose packet would otherwise revert it")
check(commands[1] and commands[1].payload.onlineID == 77
      and commands[1].payload.walkType == moved.walkType
      and commands[1].payload.speedMod == moved.speedMod,
    "the owner receives exactly the values written server-side")

-- Server-owned: the direct write is already authoritative, so a packet would
-- be pure waste. Same rule svSetZombieHP follows.
moveZombie.getOwnerPlayer = function() return nil end
commands = {}
check(RQSvShared.applySprintProfile(moveZombie), "a sprint on a server-owned zombie still reports delivery")
check(#commands == 0, "no packet is sent for a zombie the server already owns")

-- Restore rides the same path. A restore that only landed server-side would be
-- reverted exactly like the sprint was, and a special left sprinting forever is
-- the failure the restore exists to prevent.
moveZombie.getOwnerPlayer = function() return moveOwner end
commands = {}
check(RQSvShared.restoreMovementProfile(moveZombie,
        { walkType = "2", speedType = 2, speedMod = 0.55, turnDelta = 0.4 }),
    "a restore reports delivery")
check(moved.walkType == "2" and moved.speedMod == 0.55 and moved.turnDelta == 0.4,
    "the restore puts every captured field back")
check(#commands == 1 and commands[1].command == "applyZombieMovement"
      and commands[1].payload.walkType == "2",
    "the restore is delivered to the owner too, not just written locally")

-- ---------------------------------------------------------------------------
-- DebugMode drives RQDirgeLog's master switch
-- ---------------------------------------------------------------------------
-- RQDirgeLog ships ENABLED=false so a release server is quiet - and until
-- 2026-08-24 nothing ever flipped it, so every debug-gated diagnostic
-- (the Slice 1 hit probe included) wrote into a no-op even with the sandbox
-- flag on. The wiring lives in getSvConfig because that is the one place the
-- server reads the flag; both directions ride the cache-clear path a live
-- sandbox flip would ride.
RQDirgeLog.ENABLED = false
SandboxVars = { RFTDDirge = { DebugMode = true } }
RQSvShared.clearSvConfig()
RQSvShared.getSvConfig()
check(RQDirgeLog.ENABLED == true,
    "DebugMode on flips the log master switch on when the config is built")
SandboxVars.RFTDDirge.DebugMode = false
RQSvShared.clearSvConfig()
RQSvShared.getSvConfig()
check(RQDirgeLog.ENABLED == false,
    "DebugMode off drops the switch with it on the next config build")

print(string.format("RQSvShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
