-- Echoes: playing a fixed world instrument - a piano standing in a house, not
-- an item in a hand. No equip choreography and no inventory item; the player
-- faces the object, locks in place, and the song runs off their emitter the
-- same way held instruments do. Skill, XP and the zombie lure all flow through
-- the def's instrumentType, so a world piano trains the same skill as its
-- portable cousin.

require "TimedActions/ISBaseTimedAction"
require "echoes/ECCore"

ECPlayWorldAction = ECPlayWorldAction or ISBaseTimedAction:derive("ECPlayWorldAction")

local LURE_INTERVAL = 30
local LURE_BASE_RADIUS = 30
local LURE_VOLUME = 5

function ECPlayWorldAction:isValid()
    if self.character:getVehicle() ~= nil then return false end
    if not self.object or not self.object:getSquare() then return false end
    return true
end

function ECPlayWorldAction:start()
    self.character:faceThisObject(self.object)
    self:setActionAnim(self.def.animation)
    self.character:setIgnoreInputsForDirection(true)
    self.character:setIgnoreMovement(true)
    self.character:setIgnoreAimingInput(true)
end

function ECPlayWorldAction:update()
    if not self.song then
        return
    end

    self.character:setMetabolicTarget(Metabolics.LightWork)
    local ts = getTimestamp()
    if not self:isPlayingSong() then
        if self.startTime then
            self:forceComplete()
            return
        end
        self.playingSong = self.character:getEmitter():playSound(self.song.soundFile)
        self.startTime = ts
    else
        self.action:setTime(self.song.duration)
        self.action:setCurrentTime(ts - self.startTime)
    end

    local lure = SandboxVars.RFTDEchoes.LureModifier
    if lure > 0 and ts >= self.nextAttract then
        local radius = math.floor(LURE_BASE_RADIUS * (self.def.loudness or 1.0) * lure)
        if radius > 0 then
            addSound(self.character, self.character:getX(), self.character:getY(), self.character:getZ(), radius, LURE_VOLUME)
        end
        self.nextAttract = ts + LURE_INTERVAL
    end
end

local function finish(self)
    if self:isPlayingSong() then
        self.character:getEmitter():stopSound(self.playingSong)
    end
    if self.startTime then
        local skillType = ECCore:getInstrumentSkill(self.def.instrumentType)
        local duration = getTimestamp() - self.startTime
        local xp = math.floor(duration / 10)
        if xp > 0 and skillType then
            ECCore:givePlayerXp(self.character, skillType, xp)
            HaloTextHelper.addTextWithArrow(self.character, getText(ECCore:getSkillName(skillType)), true, 200, 250, 200)
        end
        self.startTime = nil
    end
    self.character:setIgnoreInputsForDirection(false)
    self.character:setIgnoreMovement(false)
    self.character:setIgnoreAimingInput(false)
end

function ECPlayWorldAction:stop()
    finish(self)
    ISBaseTimedAction.stop(self)
end

function ECPlayWorldAction:perform()
    finish(self)
    ISBaseTimedAction.perform(self)
end

function ECPlayWorldAction:isPlayingSong()
    return self.playingSong and self.playingSong ~= 0 and self.character:getEmitter():isPlaying(self.playingSong)
end

--- @param character IsoGameCharacter
--- @param def table world instrument def: instrumentType, animation, loudness
--- @param object IsoObject the world tile being played
--- @param song table|nil nil means pretend to play
function ECPlayWorldAction:new(character, def, object, song)
    local o = ISBaseTimedAction:new(character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = false
    o.maxTime = -1
    o.forceProgressBar = true
    o.def = def
    o.object = object
    o.song = song
    o.playingSong = 0
    o.nextAttract = 0
    return o
end
