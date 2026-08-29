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
                playSound = function(_, name)
                    emitterCalls[#emitterCalls + 1] = { kind = "play", name = name }
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

print(string.format("RQCore: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
