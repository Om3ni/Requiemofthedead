-- RQEMP fixture - detonation VFX emits one ring, thunder event, flare, local
-- falloff pair, and authoritative zombie-attraction world sound.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQEMP.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQEMP: " .. message)
    end
end

local callbacks = {}
local function event(name)
    callbacks[name] = {}
    return { Add = function(selfOrFn, maybeFn)
        local fn = maybeFn or selfOrFn
        callbacks[name][#callbacks[name] + 1] = fn
    end }
end
Events = { OnTick = event("tick"), OnPostUIDraw = event("draw"), OnGameStart = event("start") }

local logs, thunder, flares, sounds, falloff, draws = {}, {}, {}, {}, {}, {}
RQDirgeLog = { write = function(_, line) logs[#logs + 1] = line end }
local config = {
    empDeafMinMs = 0,
    empDeafMaxMs = 0,
    empBlindMinMs = 0,
    empBlindMaxMs = 0,
}
RQConfig = { COLORS = { EMP = { r = 0.2, g = 0.95, b = 0.7 } }, get = function() return config end }
RQRing = { TILE_SCALE = 1 }
RQCore = { playFalloffSound = function(name, x, y, z, volume)
    falloff[#falloff + 1] = { name = name, x = x, y = y, z = z, volume = volume }
end }
-- Device static is RQEMPStatic's own subject and is covered by its own fixture;
-- what this one owns is the HANDOFF - that detonation delegates at all, and
-- passes the blast geometry rather than something of its own.
local scrambles = {}
RQEMPStatic = { scramble = function(x, y, z, radius)
    scrambles[#scrambles + 1] = { x = x, y = y, z = z, radius = radius }
end }
CharacterTrait = { DEAF = "Deaf" }

local marker = {
    setScaleCircleTexture = function(self, value) self.circle = value end,
    setSize = function(self, value) self.size = value end,
    remove = function(self) self.removed = true end,
}
local square = {}
local cell = { getGridSquare = function(_, x, y, z) return square end }
function getCell() return cell end
function getWorldMarkers()
    return { addGridSquareMarker = function(_, sq, r, g, b, pulse, alpha)
        marker.args = { sq, r, g, b, pulse, alpha }
        return marker
    end }
end
local nowMs = 1000
function getTimestampMs() return nowMs end
function ZombRand(maxExclusive) return maxExclusive - 1 end

local function runTickCallbacks()
    for i = 1, #callbacks.tick do
        callbacks.tick[i]()
    end
end

function getClimateManager()
    return { getThunderStorm = function()
        return { triggerThunderEvent = function(_, x, y, strike, lightning, rumble)
            thunder[#thunder + 1] = { x, y, strike, lightning, rumble }
        end }
    end }
end
WorldFlares = { launchFlare = function(...) flares[#flares + 1] = { ... } end }
function addSound(...) sounds[#sounds + 1] = { ... } end
function instanceof(obj, className)
    return obj and obj.className == className
end
local clearedActions = {}
ISTimedActionQueue = { clear = function(player) clearedActions[#clearedActions + 1] = player end }
UIManager = {
    getBlack = function() return "black.png" end,
    DrawTexture = function(...)
        draws[#draws + 1] = { ... }
    end,
}
function getPlayerScreenLeft() return 11 end
function getPlayerScreenTop() return 22 end
function getPlayerScreenWidth() return 333 end
function getPlayerScreenHeight() return 444 end

RQEMP = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

RQEMP.playDetonationVFX(10, 20, 1, 12)
check(marker.circle == true and marker.args and marker.args[1] == square,
    "detonation creates the expanding world marker")
check(#thunder == 1 and thunder[1][1] == 10 and thunder[1][2] == 20 and thunder[1][4] == true,
    "detonation triggers the established thunder effect")
check(#flares == 1 and flares[1][1] == 60 and flares[1][2] == 10 and flares[1][3] == 20 and flares[1][4] == 12,
    "detonation launches the direct WorldFlares effect")
-- Three layers, and the ORDER is pinned along with the names: crack,
-- concussion, electrical wind-down, in descending gain. GeneratorStopping is
-- the generator shutdown event (FMOD Object/Generator/Shutdown, defined in
-- sounds_object_generator.txt:23) and sits under the concussion deliberately -
-- at parity it masked the crack that reads as the detonation itself.
-- A wrong event name is SILENT rather than loud (FMODSoundEmitter.playSound
-- returns 0 for an unknown event), so the names are asserted here or nothing
-- in the suite would ever notice a typo.
check(#falloff == 3 and falloff[1].name == "GeneratorBackfire" and falloff[1].volume == 1.0
    and falloff[2].name == "PipeBombExplode" and falloff[2].volume == 0.7
    and falloff[3].name == "GeneratorStopping" and falloff[3].volume == 0.65,
    "detonation emits all three distance-scaled audio layers in descending gain")
check(#sounds == 1 and sounds[1][1] == nil and sounds[1][2] == 10 and sounds[1][3] == 20
    and sounds[1][4] == 1 and sounds[1][5] == 100 and sounds[1][6] == 100,
    "detonation emits one authoritative zombie-attraction world sound")
check(#scrambles == 1 and scrambles[1].x == 10 and scrambles[1].y == 20
    and scrambles[1].z == 1 and scrambles[1].radius == 12,
    "detonation hands device static the blast's own geometry")

local bumped = {}
local knockbackPlayer = {
    setBumpType = function(_, value) bumped.bumpType = value end,
    setVariable = function(_, key, value) bumped[key] = value end,
    getBodyDamage = function()
        return { ReduceGeneralHealth = function(_, amount) bumped.damage = amount end }
    end,
    reportEvent = function(_, eventName) bumped.event = eventName end,
}
RQEMP.applyKnockback(knockbackPlayer, 4, 100)
check(clearedActions[#clearedActions] == knockbackPlayer, "EMP knockback clears timed actions directly")
check(bumped.damage == 10 and bumped.BumpFall == true and bumped.event == "wasBumped",
    "inner EMP knockback applies fall damage, bump variables, and state event")

local activePlayer = nil
function getPlayer() return activePlayer end

local function makePlayer(initialDeaf)
    local md = {}
    local traits = { [CharacterTrait.DEAF] = initialDeaf or false }
    return {
        isDead = function() return false end,
        hasTrait = function(_, trait) return traits[trait] == true end,
        getModData = function() return md end,
        getPlayerNum = function() return 0 end,
        getCharacterTraits = function()
            return {
                add = function(_, trait) traits[trait] = true end,
                remove = function(_, trait) traits[trait] = false end,
            }
        end,
        hasDeafTrait = function() return traits[CharacterTrait.DEAF] == true end,
        modData = md,
    }
end

config.empDeafMinMs = 100
config.empDeafMaxMs = 100
config.empBlindMinMs = 100
config.empBlindMaxMs = 100
local shockedPlayer = makePlayer(false)
activePlayer = shockedPlayer
RQEMP.applySensoryEffects(shockedPlayer, 9, 100)
check(shockedPlayer:hasDeafTrait(), "sensory shock adds the temporary Deaf trait directly")
check(shockedPlayer.modData.RQEMPDeafUntil == 1100, "sensory shock records the temporary Deaf expiry")
callbacks.draw[1]()
check(#draws == 1 and draws[1][1] == "black.png" and draws[1][2] == 11 and draws[1][3] == 22
    and draws[1][4] == 333 and draws[1][5] == 444 and draws[1][6] == 1.0,
    "active EMP blindness draws the post-UI blackout directly")

nowMs = 1100
runTickCallbacks()
check(not shockedPlayer:hasDeafTrait(), "expired temporary Deaf trait is removed directly")
check(shockedPlayer.modData.RQEMPDeafUntil == nil, "expired temporary Deaf marker is cleared")

nowMs = 1200
local bornDeafPlayer = makePlayer(true)
activePlayer = bornDeafPlayer
RQEMP.applySensoryEffects(bornDeafPlayer, 9, 100)
check(bornDeafPlayer:hasDeafTrait(), "existing Deaf trait is not owned or removed by EMP")
check(bornDeafPlayer.modData.RQEMPDeafUntil == nil, "existing Deaf trait does not arm EMP cleanup")

-- ---------------------------------------------------------------------------
-- The caster is immune to its own blast
-- ---------------------------------------------------------------------------
-- Owner-observed 2026-08-24: a Boss casting EMPulse knocked ITSELF down, every
-- time. It stands at its own epicentre, so dSq = 0 - as deep inside the inner
-- zone as it is possible to be. Neither sweep had any notion of "the thing that
-- did this". Owner decision the same day: CASTER ONLY. Other specials stay
-- vulnerable, because specials shrugging off each other's blasts would read as
-- coordination, and zombies do not coordinate.
--
-- This is the client half. The server half (RQSvShared.svApplyEMPBlast) takes
-- the same casterID; both must honour it, because whichever side owns the
-- zombie is the side that stumbles it.
local function makeStumbleZed(id, x, y)
    return {
        id = id, downed = false, staggered = false,
        getOnlineID = function(self) return self.id end,
        isDead      = function() return false end,
        isRemoteZombie = function() return false end,
        isReanimatedForGrappleOnly = function() return false end,
        isCrawling  = function() return false end,
        isOnFloor   = function() return false end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return 0 end,
        knockDown      = function(self) self.downed = true end,
        setStaggerBack = function(self) self.staggered = true end,
        setHitForce    = function() end,
        setHitReaction = function() end,
        reportEvent    = function() end,
    }
end

-- True, because this sweep only ever runs on a connected client; the module's
-- own ownership guard reads `isClient() and zed:isRemoteZombie()`, and stubbing
-- isClient false would skip that guard entirely and test a path production
-- never takes.
function isClient() return true end

local caster    = makeStumbleZed(500, 10, 20)   -- dead centre of the blast
local bystander = makeStumbleZed(501, 10, 20)   -- same square, not the caster
cell.getZombieList = function()
    local list = { caster, bystander }
    return { size = function() return #list end,
             get  = function(_, i) return list[i + 1] end }
end

RQEMP.stumbleZombies(10, 20, 0, 12, 500)
check(caster.downed == false and caster.staggered == false,
    "the caster is untouched by its own blast")
check(bystander.downed == true,
    "a bystander at the same range still goes down - immunity is caster-only")

-- A sourceless blast (an EMP zombie detonating on death, or the admin command)
-- passes no casterID, and must still flatten everything in range.
caster.downed, bystander.downed = false, false
RQEMP.stumbleZombies(10, 20, 0, 12, nil)
check(caster.downed == true and bystander.downed == true,
    "with no caster named, every zombie in range is caught")

print(string.format("RQEMP: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
