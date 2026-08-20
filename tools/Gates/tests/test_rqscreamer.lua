-- RQScreamer fixture - the SearchMode singleton owns initialized modes for all
-- local player slots, so applying and releasing the effect are direct calls.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQScreamer.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQScreamer: " .. message)
    end
end

local function event()
    return { Add = function() end }
end

Events = { OnTick = event(), OnGameStart = event() }
CharacterTrait = { DESENSITIZED = "desensitized", BRAVE = "brave", COWARDLY = "cowardly" }
CharacterStat = { PANIC = "panic" }

local now = 1000
function getTimestampMs() return now end

local writes, moodles = {}, {}
RQDirgeLog = { write = function(_, line) writes[#writes + 1] = line end }
RQMoodle = {
    setDazed = function(playerNum, kind) moodles.set = { playerNum, kind } end,
    clearDazed = function(playerNum) moodles.clear = playerNum end,
}
RQConfig = { get = function() return { screamerTriggerRange = 30, screamerBlurStrength = 0.5, screamerDarkStrength = 0.5 } end }
RQRing = { clear = function() end }

local function numberValue()
    return {
        exterior = nil,
        interior = nil,
        setExterior = function(self, value) self.exterior = value end,
        setInterior = function(self, value) self.interior = value end,
    }
end

local playerSearchMode = {
    blur = numberValue(), darkness = numberValue(), desat = numberValue(),
    radius = numberValue(), gradient = numberValue(),
}
function playerSearchMode:getBlur() return self.blur end
function playerSearchMode:getDarkness() return self.darkness end
function playerSearchMode:getDesat() return self.desat end
function playerSearchMode:getRadius() return self.radius end
function playerSearchMode:getGradientWidth() return self.gradient end

local searchMode = { fades = {}, overrides = {}, enabled = {} }
function searchMode:getSearchModeForPlayer(index) self.lastIndex = index; return playerSearchMode end
function searchMode:setFadeTime(value) self.fades[#self.fades + 1] = value end
function searchMode:setOverride(index, value) self.overrides[index] = value end
function searchMode:setEnabled(index, value) self.enabled[index] = value end
function getSearchMode() return searchMode end

local player = {
    getPlayerNum = function() return 0 end,
    getX = function() return 100 end,
    getY = function() return 100 end,
    getStats = function() return { add = function() end } end,
    hasTrait = function() return false end,
}
function getPlayer() return player end

RQScreamer = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

RQScreamer.onCastStart(player, { getX = function() return 102 end, getY = function() return 102 end })
check(RQScreamer.isDisoriented(), "nearby scream marks the effect active")
check(searchMode.lastIndex == 0 and searchMode.fades[1] == 0.3, "apply selects the player mode and fade-in")
check(searchMode.enabled[0] == true and searchMode.overrides[0] == true, "apply enables the override")
check(playerSearchMode.blur.exterior == 0.4 and playerSearchMode.blur.interior == 0.375,
    "apply scales blur through the direct SearchMode accessors")
check(playerSearchMode.darkness.exterior == 0.1 and playerSearchMode.darkness.interior == 0.075,
    "apply scales darkness through the direct SearchMode accessors")
check(playerSearchMode.desat.exterior == 0.35 and playerSearchMode.desat.interior == 0.25,
    "apply preserves desaturation values")
check(playerSearchMode.radius.exterior == 0 and playerSearchMode.radius.interior == 0
    and playerSearchMode.gradient.exterior == 6 and playerSearchMode.gradient.interior == 0,
    "apply sets the established radius and gradient")
check(moodles.set and moodles.set[1] == 0 and moodles.set[2] == "normal", "apply sets the dazed moodle")

RQScreamer.onDead(nil)
check(not RQScreamer.isDisoriented(), "release clears the active effect")
check(searchMode.fades[2] == 1.5 and searchMode.enabled[0] == false and searchMode.overrides[0] == false,
    "release fades out and returns control to SearchMode")
check(playerSearchMode.blur.exterior == 0 and playerSearchMode.blur.interior == 0
    and playerSearchMode.darkness.exterior == 0 and playerSearchMode.darkness.interior == 0
    and playerSearchMode.desat.exterior == 0 and playerSearchMode.desat.interior == 0,
    "release clears all effect strengths")
check(playerSearchMode.radius.exterior == 0 and playerSearchMode.radius.interior == 0
    and playerSearchMode.gradient.exterior == 0 and playerSearchMode.gradient.interior == 0,
    "release clears radius and gradient")
check(moodles.clear == 0, "release clears the dazed moodle")

print(string.format("RQScreamer: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
