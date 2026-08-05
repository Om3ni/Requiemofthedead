-- Echoes: the solo play action. Equips the instrument into the off hand, runs
-- the play animation, and drives the song through the character's emitter so
-- the audio is positional for everyone nearby. World instruments (drum kit)
-- lock the player in place and re-drop the kit where it stood afterward.
--
-- Fixed from the fork source: the zombie lure was dead code three ways over
-- (read a sandbox key that didn't exist, never seeded its timer, and had the
-- timer comparison inverted). It now pulses addSound on a 30s cadence, scaled
-- by per-instrument loudness and the LureModifier dial; 0 switches it off.

require "TimedActions/ISBaseTimedAction"
require "echoes/ECCore"

ECPlayAction = ECPlayAction or ISBaseTimedAction:derive("ECPlayAction")

local LURE_INTERVAL = 30 -- seconds between world-sound pulses
local LURE_BASE_RADIUS = 30
local LURE_VOLUME = 5

function ECPlayAction:isValid()
    if self.character:getVehicle() ~= nil then return false end
    return true
end

function ECPlayAction:start()
    if self.instrument then
        self:equipStart()
        self:setActionAnim(ECCore:getInstrumentAnimation(self.instrument:getFullType()))
    end
    if self.doLockPlayer then
        self:lockMovement()
    end
end

function ECPlayAction:update()
    if not self.song then
        return
    end

    self.character:setMetabolicTarget(Metabolics.LightWork)
    local ts = getTimestamp()
    -- Sound start is deferred to the first update so a failed/instant action
    -- never leaks a playing emitter; if the emitter dies early (muted,
    -- invisible admin), finish rather than loop silence.
    if not self:isPlayingSong() then
        if self.startTime then
            self:forceComplete()
            return
        end
        self:startSong()
    else
        self.action:setTime(self.song.duration)
        self.action:setCurrentTime(ts - self.startTime)
        self.instrument:setJobDelta(self:getJobDelta())
    end

    local lure = SandboxVars.RFTDEchoes.LureModifier
    if lure > 0 and ts >= self.nextAttract then
        local loudness = ECCore:getInstrumentLoudness(self.instrument:getFullType())
        local radius = math.floor(LURE_BASE_RADIUS * loudness * lure)
        if radius > 0 then
            addSound(self.character, self.character:getX(), self.character:getY(), self.character:getZ(), radius, LURE_VOLUME)
        end
        self.nextAttract = ts + LURE_INTERVAL
    end
end

function ECPlayAction:stop()
    self.instrument:setJobDelta(0.0)
    self:stopSong()
    self:giveXp()
    self:equipDone()
    if self.doLockPlayer then
        self:unlockMovement()
    end
    ISBaseTimedAction.stop(self)
end

function ECPlayAction:perform()
    self.instrument:setJobDelta(0.0)
    self:stopSong()
    self:giveXp()
    self:equipDone()
    if self.doLockPlayer then
        self:unlockMovement()
    end
    ISBaseTimedAction.perform(self)
end

function ECPlayAction:startSong()
    self.playingSong = self.character:getEmitter():playSound(self.song.soundFile)
    self.startTime = getTimestamp()
end

function ECPlayAction:stopSong()
    if self:isPlayingSong() then
        self.character:getEmitter():stopSound(self.playingSong)
    end
end

function ECPlayAction:isPlayingSong()
    return self.playingSong and self.playingSong ~= 0 and self.character:getEmitter():isPlaying(self.playingSong)
end

function ECPlayAction:lockMovement()
    if self.postPlayWorldPosition then
        local offset = ECCore:getWorldOffset(self.instrument:getFullType())
        if offset then
            self.character:setDirectionAngle(self.postPlayWorldPosition.r + offset.r + 90)
            self.character:setX(self.postPlayWorldPosition.sq:getX() + self.postPlayWorldPosition.x + offset.x)
            self.character:setY(self.postPlayWorldPosition.sq:getY() + self.postPlayWorldPosition.y + offset.y)
            self.character:setZ(self.postPlayWorldPosition.sq:getZ() + self.postPlayWorldPosition.z + offset.z)
        end
    end
    self.character:setIgnoreInputsForDirection(true)
    self.character:setIgnoreMovement(true)
    self.character:setIgnoreAimingInput(true)
end

function ECPlayAction:unlockMovement()
    self.character:setIgnoreInputsForDirection(false)
    self.character:setIgnoreMovement(false)
    self.character:setIgnoreAimingInput(false)
end

function ECPlayAction:giveXp()
    if self.startTime then
        local skillType = ECCore:getInstrumentSkill(ECCore:getInstrumentType(self.instrument:getFullType()))
        local skillName = getText(ECCore:getSkillName(skillType))
        local duration = getTimestamp() - self.startTime
        local xp = math.floor(duration / 10)
        if xp > 0 then
            ECCore:givePlayerXp(self.character, skillType, xp)
            HaloTextHelper.addTextWithArrow(self.character, skillName, true, 200, 250, 200)
        end
        self.startTime = nil
    end
end

function ECPlayAction:equipStart()
    self.character:setPrimaryHandItem(nil)
    self.character:setSecondaryHandItem(self.instrument)
end

-- Re-dropping a world instrument has to wait until this action has fully left
-- the queue, hence the one-shot tick handler instead of queueing directly
-- from perform().
local dropItemData
local function doDropItem()
    if not dropItemData then
        Events.OnTick.Remove(doDropItem)
        return
    end
    if ISTimedActionQueue.getTimedActionQueue(dropItemData.character).queue[1] == nil then
        Events.OnTick.Remove(doDropItem)
        ISTimedActionQueue.add(ISUnequipAction:new(dropItemData.character, dropItemData.instrument, 1))
        ISTimedActionQueue.add(ISDropWorldItemAction:new(dropItemData.character, dropItemData.instrument, dropItemData.sq, dropItemData.x, dropItemData.y, dropItemData.z, dropItemData.r, false))
        dropItemData = nil
    end
end
local function scheduleDropItems(character, instrument, sq, x, y, z, r)
    dropItemData = {
        character = character,
        instrument = instrument,
        sq = sq,
        x = x,
        y = y,
        z = z,
        r = r,
    }
    Events.OnTick.Add(doDropItem)
end

function ECPlayAction:equipDone()
    if self.postPlayWorldPosition then
        scheduleDropItems(self.character, self.instrument, self.postPlayWorldPosition.sq, self.postPlayWorldPosition.x, self.postPlayWorldPosition.y, self.postPlayWorldPosition.z, self.postPlayWorldPosition.r)
    elseif self.instrument:isTwoHandWeapon() then
        self.character:setPrimaryHandItem(self.instrument)
        self.character:setSecondaryHandItem(self.instrument)
    else
        self.character:setPrimaryHandItem(self.instrument)
        self.character:setSecondaryHandItem(nil)
    end
end

--- @param character IsoGameCharacter
--- @param instrument InventoryItem
--- @param song table|nil nil means pretend to play (no sound, no XP)
function ECPlayAction:new(character, instrument, song)
    local o = ISBaseTimedAction:new(character)
    setmetatable(o, self)
    self.__index = self
    o.stopOnWalk = not SandboxVars.RFTDEchoes.CanPlayWhileWalking
    o.stopOnRun = true
    o.stopOnAim = false
    o.maxTime = -1
    o.forceProgressBar = true
    o.instrument = instrument
    o.song = song
    o.playingSong = 0
    o.nextAttract = 0
    o.doLockPlayer = ECCore:isWorldInstrument(instrument:getFullType())
    return o
end
