-- RQSvAdminCmds fixture - the admin convert's AUTHORITY BOUNDARY.
--
-- WHY THIS FILE EXISTS. hAdminConvert carries the one proximity anchor in the
-- suite that bounds a coordinate-selected convert, and on 2026-08-25 it
-- silently stopped covering the whole coordinate lane: the resolver's lanes
-- were split that day and widened the coordinate lane from {0} to {nil, 0,
-- -1}, while this gate still tested `onlineID == 0`. A staff-tier caller
-- could send onlineID = -1 with any loaded coordinates and convert the nearest
-- ordinary zombie there - across the map, with nothing on the wire to
-- distinguish it from a legitimate right-click. Found in review the same day.
--
-- The FIX was not "add -1 to the gate" but to make the gate ask the resolver
-- (RQSvShared.usesCoordinateLane), so the two cannot disagree again. These
-- assertions pin BOTH halves: the lane test itself, and the handler honouring
-- it - because the previous version of each was individually defensible and
-- the bug lived in the gap between them.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvAdminCmds.lua"
local SHARED = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua"
local ZID    = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDZombieId.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvAdminCmds: " .. message)
    end
end

local now = 1000
local onTick
function isServer() return true end
function getTimestampMs() return now end
function ZombRand(n) return 0 end
function instanceof(o, cls) return o and o.__class == cls end
Events = { OnTick = { Add = function(fn) onTick = fn end } }

-- The REAL RQSvShared, because usesCoordinateLane is the thing under test and
-- a stub of it would be the fixture testing itself. Its own deps are stubbed.
RQChargeLevy = { drain = function() return 0 end }
RQCommon = {
    MODULE = "RFTDDirge",
    HEALTH_MULTIPLIER = { Screamer = 2, Juggernaut = 10, EMP = 2,
                          Glutton = 2, Scavenger = 2, Boss = 10 },
    JUGGERNAUT_MIN_BASE_HEALTH = 100,
    ENUMS = setmetatable({}, { __index = function(t, k) rawset(t, k, {}); return t[k] end }),
    ev  = function(_, value, default) return value or default end,
    pct = function(value, default) return value or default end,
}
RQDirgeLog = { write = function() end }
RDAccess = { meetsTier = function() return true end }   -- caller IS staff here
MoodleType = { ENDURANCE = "Endurance" }
CharacterStat = { ENDURANCE = "Endurance" }
RDShared = { textSafe = function(v) return tostring(v) end }

-- The cell the coordinate lane sweeps. One ordinary zombie sits at (900,900) -
-- far from the caller - so a convert that reaches it proves the anchor failed.
local ORDINARY = { __class = "IsoZombie", x = 900, y = 900,
    getX = function(s) return s.x end, getY = function(s) return s.y end,
    getZ = function() return 0 end, isDead = function() return false end,
    getOnlineID = function() return 4242 end,
    getModData = function() return {} end, transmitModData = function() end,
}
function getCell()
    return { getGridSquare = function(_, x, y, z)
        if math.abs(x - 900) <= 1 and math.abs(y - 900) <= 1 then
            return { getMovingObjects = function()
                return { size = function() return 1 end,
                         get = function() return ORDINARY end } end }
        end
        return nil
    end }
end

local registered = {}
RDNet = { register = function(_, action, opts, fn)
    registered[action] = { opts = opts, run = fn }
end }
local sent = {}

function require(name)
    if name == "RDZombieId" then dofile(ZID) return end
    if name == "RQZombieCache" then
        -- Empty cache: every id-lane lookup misses. That is the point - the
        -- assertions below are about WHICH LANE was taken, not what it found.
        RQZombieCache = { get = function() return nil end }
        return
    end
    if name == "RQChargeLevy" then return RQChargeLevy end
    if name == "RQSvShared" then return RQSvShared end
    if name == "RDShared" or name == "RDNet" or name == "RQCommon" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvShared = nil
local okS, errS = pcall(dofile, SHARED)
check(okS, "RQSvShared loads: " .. tostring(errS))
RQSvShared.sendToPlayer = function(p, cmd, args)
    sent[#sent + 1] = { command = cmd, args = args }
end

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(registered["adminConvert"] ~= nil, "adminConvert did not register")
check(registered["adminSpawnSpecial"] ~= nil, "adminSpawnSpecial did not register")
check(type(onTick) == "function", "spawn admission poller did not register")

-- ---------------------------------------------------------------------------
-- THE LANE TEST, pinned on its own. Every value the resolver treats as
-- coordinate-selected must report true, and a real id must report false.
-- ---------------------------------------------------------------------------
check(RQSvShared.usesCoordinateLane(0) == true, "0 is coordinate-selected")
check(RQSvShared.usesCoordinateLane(-1) == true,
    "-1 is coordinate-selected - it is RDZombieId's 'no id yet' sentinel, and "
    .. "MULTIPLE zombies carry it at once, so it can never name one")
check(RQSvShared.usesCoordinateLane(nil) == true, "nil is coordinate-selected")
check(RQSvShared.usesCoordinateLane(500) == false, "a real id is NOT")
check(RQSvShared.usesCoordinateLane(-10307) == false,
    "a WRAPPED negative id is a real id, not a sentinel - the short-wrap rule")

-- ---------------------------------------------------------------------------
-- THE ANCHOR. The caller stands at (100,100); the only zombie is at (900,900).
-- ---------------------------------------------------------------------------
local player = {
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "Omen" end,
}
-- pcall'd on purpose. A convert the anchor SHOULD have refused does not stop
-- at the refusal - it reaches the sweep, finds the distant zombie and runs the
-- real conversion path, which this fixture deliberately does not stub. Letting
-- that throw would report the regression as a stack trace; catching it reports
-- it as the assertion it is, and "reached" is itself the failure.
local function convert(onlineID)
    sent = {}
    pcall(registered["adminConvert"].run, player, {
        onlineID = onlineID, zType = "Screamer", x = 900, y = 900, z = 0,
    })
    for _, m in ipairs(sent) do
        if m.command == "adminConvertResult" then return m.args.status end
    end
    return "reached-the-world"
end

check(convert(0) == "outOfRange", "id 0 at 800 tiles was not refused")
check(convert(-1) == "outOfRange",
    "AN ID OF -1 CONVERTED A ZOMBIE 800 TILES AWAY. The resolver sends -1 down "
    .. "its coordinate lane, so the point selects the victim - and this gate "
    .. "tested `onlineID == 0` until 2026-08-25, leaving that whole path "
    .. "unanchored for any staff-tier caller.")

-- A real id is NOT anchored - an id names one zombie, so there is no ambiguity
-- for a proximity check to bound. It misses here (empty cache) rather than
-- being refused for range, and the two answers must stay distinguishable.
check(convert(500) == "missing",
    "an id-selected convert was range-refused; distance is not its constraint")

-- ---------------------------------------------------------------------------
-- THE SPAWN ADMISSION BARRIER. A newborn consumes its ordinary-roll ticket at
-- birth but cannot become special until native ownership has remained stable
-- for the grace. This pins the race fix: svTryConvert must never run in the
-- addZombiesInOutfit callback again.
-- ---------------------------------------------------------------------------
local converted = 0
local bossProfiles = 0
local conversionArgs
RQServer = { svTryConvert = function(zombie, cfg, zType, skipSpacing)
    converted = converted + 1
    conversionArgs = { zombie = zombie, cfg = cfg, zType = zType,
                       skipSpacing = skipSpacing }
    return true
end }
local cfg = { enabled = true }
RQSvShared.getSvConfig = function() return cfg end
RQSvShared.applyBossSprinter = function() bossProfiles = bossProfiles + 1 end

local function newZombie(id)
    local zombie = { id = id, owner = nil, dead = false, md = {} }
    function zombie:getOnlineID() return self.id end
    function zombie:getOwnerPlayer() return self.owner end
    function zombie:isDead() return self.dead end
    function zombie:getModData() return self.md end
    return zombie
end

local newborn
RQSvShared.svDoSpawn = function(_, _, _, _, onSpawned)
    onSpawned(newborn)
    return 1
end

local function runSpawn(zType)
    sent = {}
    registered["adminSpawnSpecial"].run(player, {
        zType = zType, count = 1, x = 100, y = 100, z = 0,
    })
end

local function spawnResult()
    for _, message in ipairs(sent) do
        if message.command == "adminSpawnResult" then return message.args end
    end
    return nil
end

newborn = newZombie(6101)
runSpawn("Boss")
check(newborn.md.RQRolled == true,
    "newborn did not consume its ordinary conversion roll at birth")
check(converted == 0,
    "NEWBORN CONVERTED INSIDE THE SPAWN CALLBACK, before native admission")
check(spawnResult() == nil,
    "spawn result claimed completion before native admission settled")

-- No owner: no conversion. First owner observation starts, rather than
-- completes, the one-second grace.
now = 1099
onTick()
check(converted == 0, "ownerless newborn crossed the admission barrier")
newborn.owner = { username = "Omen" }
now = 1100
onTick()
now = 2099
onTick()
check(converted == 0, "newborn converted before the stable-owner grace elapsed")
now = 2100
onTick()
check(converted == 1, "stable native ownership did not release conversion")
check(conversionArgs and conversionArgs.zombie == newborn
        and conversionArgs.cfg == cfg and conversionArgs.zType == "Boss"
        and conversionArgs.skipSpacing == true,
    "released conversion did not preserve the requested admin policy")
check(bossProfiles == 1, "admitted Boss did not receive its sprinter profile")
local result = spawnResult()
check(result and result.status == "ok" and result.spawned == 1
        and result.converted == 1,
    "settled spawn did not return the truthful conversion count")
onTick()
check(converted == 1, "settled admission converted twice")

-- Losing ownership resets the grace. A stale owner observation must not admit
-- a zombie after relevance moved away and back.
now = 3000
newborn = newZombie(6102)
runSpawn("Screamer")
newborn.owner = {}
now = 3100
onTick()
newborn.owner = nil
now = 3600
onTick()
newborn.owner = {}
now = 3700
onTick()
now = 4100
onTick()
check(converted == 1, "broken ownership interval still counted toward grace")
now = 4700
onTick()
check(converted == 2, "re-established stable ownership never admitted zombie")

-- A zombie that never receives a native owner times out as ordinary. The
-- operator receives a real failure after ten seconds instead of a false
-- immediate success, and the queue does not retry forever.
now = 5000
newborn = newZombie(6103)
runSpawn("EMP")
now = 14999
onTick()
check(converted == 2 and spawnResult() == nil,
    "ownerless admission settled before its timeout")
now = 15000
onTick()
result = spawnResult()
check(converted == 2, "timed-out newborn was converted without an owner")
check(result and result.status == "failed" and result.spawned == 1
        and result.converted == 0,
    "timed-out admission did not report spawned-but-unconverted truthfully")

print(string.format("RQSvAdminCmds: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
