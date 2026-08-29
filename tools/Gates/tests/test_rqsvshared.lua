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
    -- The REAL RDZombieId, not a stub. Its entire value is the rule that -1 is
    -- the only invalid onlineID, and svSetZombieHP / svDeliverMovement now both
    -- depend on it - a stub would let the negative-id bug back in unseen.
    if name == "RDZombieId" then
        dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDZombieId.lua")
        return
    end
    -- The id lane of svFindZombieByOnlineID resolves through the cache. A
    -- minimal stand-in is enough here because the cache's own behaviour has
    -- its own fixture (test_rqzombiecache); this fixture only needs the seam.
    if name == "RQZombieCache" then
        RQZombieCache = RQZombieCache or { get = function() return nil end }
        return
    end
    error("unexpected fixture require: " .. tostring(name))
end

local enumNames = {
    "SCREAMER_INTERVAL", "SCREAMER_CAST", "SCREAMER_RANGE", "SCREAMER_SOUND",
    "SCREAMER_SPAWN_MIN", "SCREAMER_SPAWN_MAX", "SCREAMER_THRESHOLD", "JUGG_RADIUS",
    -- JUGG_BUFF went with JuggernautBuffPercent on 2026-08-25; JUGG_RADIUS
    -- stays, because JuggernautBuffRadius is still live (RQBulwark.lua:162).
    "EMP_RANGE", "EMP_CAST", "EMP_RADIUS", "EMP_DRAIN", "GLUTTON_RADIUS",
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
check(commands[1] and commands[1].payload.x == nil and commands[1].payload.y == nil
      and commands[1].payload.z == nil,
    "the payload is id-only - x/y/z came off the wire 2026-08-25 (owner-approved), "
    .. "the client resolves through RQZombieCache and never read them")

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
local smashed = 0
local blastSquare
local conditionSet = nil

-- THE RADIO IS A CANARY, not a subject. A branch here used to call
-- dd:setIsTurnedOn(false), which mutates the server's copy and transmits
-- nothing - transmitDeviceDataState is `if (GameClient.client)` and this file
-- is server-only (DeviceData.java:932-942). It was removed 2026-08-27, and
-- this fixture exists so re-adding it fails loudly here instead of shipping as
-- a TV that stays on for every client. See the block comment at the deletion.
local radio = { className = "IsoRadio" }
local device = {
    getParent      = function() return radio end,
    getIsTurnedOn  = function() return true end,
    setIsTurnedOn  = function()
        error("the server must never flip device power directly - it does not replicate")
    end,
}
radio.getDeviceData = function() return device end
radio.getSquare = function() return blastSquare end

-- The generator IS the mechanism now: damaging it to 0 is what cuts grid power,
-- and the engine turns each device off and transmits that itself.
local generator = {
    className    = "IsoGenerator",
    getCondition = function() return 80 end,
    setCondition = function(_, value) conditionSet = value end,
}
local window = {
    className = "IsoWindow",
    getSquare = function() return blastSquare end,
    isSmashed = function() return false end,
    smashWindow = function() smashed = smashed + 1 end,
}
blastSquare = {
    getObjects = function() return javaList({ generator, radio, window }) end,
}
function getCell()
    return { getGridSquare = function() return blastSquare end }
end
RQSvShared.svDamageWorldElectronics(10, 20, 0, 0, 25)
check(smashed == 1, "EMP smashes a live window in the blast")
check(conditionSet == 60, "EMP damages generator condition by the drain percentage")

-- setCondition clamps to 0-100 itself (IsoGenerator.java:504), so a drain that
-- would overshoot is the engine's problem, not ours - but the subtraction must
-- not hand it a negative in the first place.
generator.getCondition = function() return 10 end
RQSvShared.svDamageWorldElectronics(10, 20, 0, 0, 100)
check(conditionSet == 0, "a full-severity drain floors condition at zero, never below")

generator.getCondition = function() return 80 end
window.getSquare = function() return nil end
smashed, conditionSet = 0, nil
RQSvShared.svDamageWorldElectronics(10, 20, 0, 0, 25)
check(smashed == 0 and conditionSet == 60,
    "EMP skips a window detached during the scan without skipping its peers")

window.getSquare = function() return blastSquare end
window.smashWindow = function() error("fixture smash fault") end
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

-- A zero stamp is a real stamp, not an absent one. Lua's only falsey values
-- are nil and false, so 0 must read as "fired at time zero" - long overdue -
-- never as "no stamp yet". No live caller seeds 0 today (RQSvBoss's
-- lastBuffTick did until the field was cut 2026-08-25), but absent-vs-zero is
-- exactly the boundary a rewrite would fumble, so the contract stays pinned.
local zeroed = { stamp = 0 }
check(RQSvShared.due(zeroed, "stamp", 2000, 50000) == true,
    "a zero stamp reads as long overdue, not as an absent one")

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
check(commands[1] and commands[1].payload.x == nil,
    "movement payload is id-only too - same wire trim as applyZombieHP")

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

-- ---------------------------------------------------------------------------
-- svCheckZoneSprinter - the zone-risk sprinter contract (Limes S8)
-- ---------------------------------------------------------------------------
-- The dial arrives only on the per-zone cfg overlay (getEffectiveRules), the
-- roll is one-shot per zombie and only burns on ground with a share, specials
-- are excluded on both sides, and a committed sprinter self-heals a walk type
-- an owning client stamped back. Every property here is one the design doc
-- states; a fixture drift is a contract drift.

local effCalls, shareForTest = 0, 0
RQPhunZones = {
    getEffectiveRules = function(_, _, cfg)
        effCalls = effCalls + 1
        return setmetatable({ sprinterShare = shareForTest }, { __index = cfg })
    end,
}
local rand = 0
ZombRand = function() return rand end

-- moveZombie gains the live walk-type read the self-heal branch uses; wired to
-- the same `moved` record the delivery writes, so the stub behaves like the
-- engine's own state.
moveZombie.getWalkType = function() return moved.walkType end
moveZombie.getOwnerPlayer = function() return nil end   -- server-owned: no packets to count

local md = { RQConverted = true }
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(md.RQSprintRolled == nil and md.RQSprinter == nil,
    "a converted special never enters the sprinter lottery")

md = {}
shareForTest = 100
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(md.RQSprintRolled == nil and effCalls == 0,
    "an unsettled special lottery defers the sprint roll - no overlay even computed")
md = { RQRolled = true, RQPendingType = "Screamer" }
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(md.RQSprintRolled == nil,
    "a parked special win defers too - the two lotteries can never both pay out")

md = { RQRolled = true }
shareForTest = 0
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(effCalls == 1 and md.RQSprintRolled == nil,
    "shareless ground burns nothing - the zombie stays eligible where risk exists")

shareForTest = 50
rand = 99
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(md.RQSprintRolled == true and md.RQSprinter == nil,
    "a losing roll on risk ground is consumed without minting a sprinter")
effCalls = 0
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(effCalls == 0, "a settled loser never pays the overlay lookup again")

md = { RQRolled = true }
moved = {}
rand = 0
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(md.RQSprinter == true and moved.walkType
      and moved.walkType:sub(1, 6) == "sprint",
    "a winning roll mints a sprinter and delivers the sprint profile")

-- Self-heal: the owning client's packets can stamp a walk back over the
-- profile (NetworkZombiePacker.applyZombie). A committed sprinter re-delivers
-- when its live walk type has reverted, and only then.
moved.walkType = "1"
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(moved.walkType:sub(1, 6) == "sprint",
    "a stamped-over sprinter is re-delivered on the next visit")
local before = moved
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(moved == before and moved.walkType:sub(1, 6) == "sprint",
    "a sprinter already sprinting is left alone")

md.RQConverted = true
moved.walkType = "1"
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(moved.walkType == "1",
    "a sprinter that later converts is the special's to move, not ours")

SandboxVars.RFTDDirge.Enabled = false
RQSvShared.clearSvConfig()
md = { RQRolled = true }
effCalls = 0
RQSvShared.svCheckZoneSprinter(moveZombie, md)
check(effCalls == 0 and md.RQSprintRolled == nil,
    "a disabled Dirge rolls nothing and burns nothing")
SandboxVars.RFTDDirge.Enabled = nil
RQSvShared.clearSvConfig()

print(string.format("RQSvShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
