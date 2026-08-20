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
    HEALTH_MULTIPLIER = 2,
    JUGGERNAUT_MIN_BASE_HEALTH = 100,
    ENUMS = enums,
    ev = function() return nil end,
    pct = function() return nil end,
}
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

print(string.format("RQSvShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
