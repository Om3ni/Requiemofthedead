-- RQCore fixture - falloff sound uses an explicit world precondition and the
-- verified direct emitter path.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQCore.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQCore: " .. message)
    end
end

local callbacks = {}
local function event(name)
    callbacks[name] = {}
    return { Add = function(selfOrFn, maybeFn)
        callbacks[name][#callbacks[name] + 1] = maybeFn or selfOrFn
    end }
end

Events = {
    OnZombieDead = event("zombieDead"),
    OnServerCommand = event("serverCommand"),
    OnRenderTick = event("renderTick"),
    OnGameStart = event("gameStart"),
}

local realRequire = require
function require(name)
    if name:sub(1, 2) == "RQ" then return true end
    return realRequire(name)
end

RQDirgeLog = { write = function() end }
RQConfig = { get = function() return { screamerVolume = 1.0 } end }
RQCommon = { acceptsModule = function(module) return module == "RFTDDirge" end }
RQRegistry = {}
RQCastBar = { cancel = function() end, create = function() return 1 end }
local clearedRings = {}
RQRing = {
    clear = function(ringId) clearedRings[#clearedRings + 1] = ringId end,
    show = function() end,
}
RQHighlight = { remove = function() end }
RQMoodle = {}
RQScreamer = { onDead = function() end, onCastStart = function() end }
RQJuggernaut = { onDead = function() end }
local empCalls = {}
RQEMP = {
    onDead = function() end,
    playDetonationVFX = function(x, y, z, radius)
        empCalls[#empCalls + 1] = { kind = "vfx", x = x, y = y, z = z, radius = radius }
    end,
    stumbleZombies = function(x, y, z, radius)
        empCalls[#empCalls + 1] = { kind = "stumble", x = x, y = y, z = z, radius = radius }
    end,
    applyKnockback = function() empCalls[#empCalls + 1] = { kind = "knockback" } end,
    applySensoryEffects = function() empCalls[#empCalls + 1] = { kind = "sensory" } end,
}
RQGlutton = { onDead = function() end, startEating = function() end, stopEating = function() end, confirmEating = function() end }
RQBoss = { onDead = function() end }
RQScavenger = { onDead = function() end }
RQReconcile = {}
RQAdmin = {}
-- The livery seam. RQLivery is the real declaration (the prefix test is
-- what the handler validates with); RQTailor and the cache are stubs.
HairOutfitDefinitions = {}
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQLivery.lua")
local redressed = {}
RQTailor = { redress = function(z, outfit) redressed[#redressed + 1] = { zombie = z, outfit = outfit } end }
local mustered = {}
RQMuster = { muster = function(z, attackerID, radius) mustered[#mustered + 1] = { zombie = z, attackerID = attackerID, radius = radius } end }
local cached = {}
RQZombieCache = { get = function(id) return cached[id] end }
RQHealthBar = {}
RQReflect = {}

function getDebug() return false end
function getCell() return nil end
function getTimestampMs() return 1000 end
function instanceof() return false end

local activePlayer = nil
function getPlayer() return activePlayer end

local activeWorld = nil
function getWorld() return activeWorld end

RQCore = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local emitterCalls = {}
local function makeWorld()
    return {
        getFreeEmitter = function(_, x, y, z)
            emitterCalls[#emitterCalls + 1] = { kind = "emitter", x = x, y = y, z = z }
            return {
                -- Both halves of the real surface (BaseSoundEmitter.java:53, :67).
                -- playSound is the NETWORKED one: on an MP client it relays a
                -- PlayWorldSoundPacket that every other client replays at the
                -- clip's own gain, outside the reach of setVolume. It is
                -- recorded rather than omitted so a regression to it fails
                -- loudly here instead of only on a populated server.
                playSound = function(_, name)
                    emitterCalls[#emitterCalls + 1] = { kind = "play-networked", name = name }
                    return 99
                end,
                playSoundImpl = function(_, name, doWorldSound, parent)
                    emitterCalls[#emitterCalls + 1] = {
                        kind = "play", name = name,
                        doWorldSound = doWorldSound, parent = parent,
                    }
                    return 99
                end,
                setVolume = function(_, handle, volume)
                    emitterCalls[#emitterCalls + 1] = { kind = "volume", handle = handle, volume = volume }
                end,
            }
        end,
    }
end

activePlayer = nil
activeWorld = makeWorld()
RQCore.playFalloffSound("RQScreamerScream", 10, 20, 0, 1.0)
check(#emitterCalls == 0, "falloff sound skips without a player")

activePlayer = { getX = function() return 10 end, getY = function() return 20 end }
activeWorld = nil
RQCore.playFalloffSound("RQScreamerScream", 10, 20, 0, 1.0)
check(#emitterCalls == 0, "falloff sound skips before world init")

activeWorld = makeWorld()
activePlayer = { getX = function() return 80 end, getY = function() return 20 end }
RQCore.playFalloffSound("RQScreamerScream", 10, 20, 0, 1.0)
check(#emitterCalls == 0, "falloff sound skips beyond audible range")

activePlayer = { getX = function() return 10 end, getY = function() return 27 end }
RQCore.playFalloffSound("RQScreamerScream", 10, 20, 2, 0.5)
check(#emitterCalls == 3, "falloff sound creates one emitter and applies one volume")
check(emitterCalls[1].x == 10.5 and emitterCalls[1].y == 20.5 and emitterCalls[1].z == 2,
    "falloff sound positions the pooled emitter at raw blast coordinates")
check(emitterCalls[2].name == "RQScreamerScream" and emitterCalls[3].handle == 99,
    "falloff sound plays the requested sound before setting volume")
check(math.abs(emitterCalls[3].volume - 0.45) < 0.0001,
    "falloff sound applies distance and base gain")

-- The multiplayer contract: the local, non-relaying overload, called with the
-- 3-arg shape that binds unambiguously. playSound would broadcast a copy to
-- every client in earshot at full gain and defeat ScreamerVolume outright.
check(emitterCalls[2].doWorldSound == false and emitterCalls[2].parent == nil,
    "falloff sound uses the 3-arg non-networked playSoundImpl")
local relayed = false
for i = 1, #emitterCalls do
    if emitterCalls[i].kind == "play-networked" then relayed = true end
end
check(not relayed, "falloff sound never calls the relaying playSound")

-- Volume knob at 0 is silent, and silent means no emitter at all - not an
-- emitter playing at gain 0. Distance is unchanged from the case above.
local mutedFrom = #emitterCalls
RQCore.playFalloffSound("RQScreamerScream", 10, 20, 2, 0.0)
check(#emitterCalls == mutedFrom, "falloff sound at gain 0 spawns no emitter")

-- The knob reaches the sound: playScreamSound must read screamerVolume rather
-- than play at a fixed gain. Distance is 0 here, so falloff is 1.0 and the
-- applied volume IS the configured value.
local realConfigGet = RQConfig.get
RQConfig.get = function() return { screamerVolume = 0.25 } end
activePlayer = { getX = function() return 10 end, getY = function() return 20 end }
local screamFrom = #emitterCalls
RQCore.playScreamSound(10, 20, 0)
check(#emitterCalls == screamFrom + 3, "playScreamSound plays through the falloff path")
check(emitterCalls[#emitterCalls].kind == "volume"
    and math.abs(emitterCalls[#emitterCalls].volume - 0.25) < 0.0001,
    "playScreamSound applies the configured screamerVolume as gain")

RQConfig.get = function() return { screamerVolume = 0.0 } end
local zeroFrom = #emitterCalls
RQCore.playScreamSound(10, 20, 0)
check(#emitterCalls == zeroFrom, "ScreamerVolume 0 plays no scream at point-blank range")
RQConfig.get = realConfigGet
activePlayer = { getX = function() return 10 end, getY = function() return 27 end }

callbacks.serverCommand[1]("RFTDDirge", "castDone", {
    ringId = "emp_14_25",
    fixedX = 15,
    fixedY = 26,
    fixedZ = "2",
    radius = 11,
})
check(#clearedRings == 2 and clearedRings[1] == "emp_14_25" and clearedRings[2] == "emp_14_25_inner",
    "EMP castDone clears the cast ring and inner ring")
check(#empCalls == 2 and empCalls[1].kind == "stumble" and empCalls[2].kind == "vfx",
    "EMP castDone runs owned-zombie stumble before presentation")
check(empCalls[1].x == 15 and empCalls[1].y == 26 and empCalls[1].z == 2 and empCalls[1].radius == 11,
    "EMP castDone passes normalized stumble coordinates and radius")
check(empCalls[2].x == 15 and empCalls[2].y == 26 and empCalls[2].z == "2" and empCalls[2].radius == 11,
    "EMP castDone preserves presentation coordinates and radius")

activePlayer = { getX = function() return 10 end, getY = function() return 20 end }
callbacks.serverCommand[1]("RFTDDirge", "empDebuff", {
    x = 10, y = 20, radius = 12, drain = 35,
})
check(#empCalls == 4 and empCalls[3].kind == "knockback" and empCalls[4].kind == "sensory",
    "EMP debuff remains client presentation only; no inventory mutation surface is required")

-- ---------------------------------------------------------------------------
-- zombieLivery: targeted re-dress of a zombie this client already holds
-- ---------------------------------------------------------------------------
local held = { isDead = function() return false end }
cached[77] = held
callbacks.serverCommand[1]("RFTDDirge", "zombieLivery", { onlineID = 77, outfit = "RQ_Juggernaut" })
check(#redressed == 1 and redressed[1].zombie == held and redressed[1].outfit == "RQ_Juggernaut",
    "zombieLivery hands the held zombie and the outfit name to RQTailor")

callbacks.serverCommand[1]("RFTDDirge", "zombieLivery", { onlineID = 78, outfit = "RQ_Juggernaut" })
check(#redressed == 1, "a zombie this client does not hold is nothing to do - creation dresses it")

callbacks.serverCommand[1]("RFTDDirge", "zombieLivery", { onlineID = 77, outfit = "Police" })
check(#redressed == 1, "an outfit outside the livery prefix is refused - wire data is untrusted")

callbacks.serverCommand[1]("RFTDDirge", "zombieLivery", { onlineID = "77", outfit = "RQ_ScavengerEnraged" })
check(#redressed == 2 and redressed[2].outfit == "RQ_ScavengerEnraged",
    "a string id is normalized like every other id-carrying command")

cached[77] = { isDead = function() return true end }
callbacks.serverCommand[1]("RFTDDirge", "zombieLivery", { onlineID = 77, outfit = "RQ_Juggernaut" })
check(#redressed == 2, "a dead zombie is not re-dressed")

callbacks.serverCommand[1]("OtherMod", "zombieLivery", { onlineID = 77, outfit = "RQ_Juggernaut" })
check(#redressed == 2, "a foreign wire token is ignored")

-- ---------------------------------------------------------------------------
-- escortMuster: the forced spot on the escorts this client owns
-- ---------------------------------------------------------------------------
local struck = { isDead = function() return false end }
cached[80] = struck
callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 80, attackerID = 5, radius = 8 })
check(#mustered == 1 and mustered[1].zombie == struck and mustered[1].attackerID == 5 and mustered[1].radius == 8,
    "escortMuster hands the held special, the attacker's id and the radius to RQMuster")

callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 81, attackerID = 5, radius = 8 })
check(#mustered == 1, "a special this client does not hold has no escort here to command")

callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 80, radius = 8 })
callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 80, attackerID = 5 })
callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 80, attackerID = 5, radius = 0 })
check(#mustered == 1, "a missing attacker, a missing radius and a zero radius are each refused")

callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = "80", attackerID = "5", radius = "8" })
check(#mustered == 2 and mustered[2].attackerID == 5 and mustered[2].radius == 8,
    "string ids and radius are normalized like every other id-carrying command")

cached[80] = { isDead = function() return true end }
callbacks.serverCommand[1]("RFTDDirge", "escortMuster", { onlineID = 80, attackerID = 5, radius = 8 })
check(#mustered == 2, "a dead special musters nobody")

callbacks.serverCommand[1]("OtherMod", "escortMuster", { onlineID = 80, attackerID = 5, radius = 8 })
check(#mustered == 2, "a foreign wire token is ignored")

print(string.format("RQCore: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
