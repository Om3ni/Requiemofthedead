-- RQMoodle - self-contained disorientation HUD icon for the Screamer effect.
-- No external dependencies. Renders as a vanilla-style moodle using ISUIElement,
-- following the same sizing/positioning patterns as the vanilla moodle stack.

RQMoodle = RQMoodle or {}

-- ========================
-- Config
-- ========================

local X_OFFSET = 10
local Y_OFFSET = 120  -- matches vanilla moodle baseline

-- Per-trait display info
local TRAIT_INFO = {
    brave    = { title = "Dazed",                desc = "Shaken by a Screamer's howl." },
    normal   = { title = "Dazed",                desc = "Vision blurred by a Screamer's howl." },
    cowardly = { title = "Severely Disoriented", desc = "Completely disoriented. Hard to see anything." },
}

-- ========================
-- Size helper mirroring the vanilla moodle scale behavior.
-- ========================

local function getMoodleSize()
    local core = getCore()
    if not core then return 32 end
    local ms = core:getOptionMoodleSize()
    local scale
    if ms < 5.5 then
        scale = 0.5 + 0.5 * ms
    elseif ms < 6.5 then
        scale = 4
    else
        scale = 0.5 + 0.5 * core:getOptionFontSizeReal()
    end
    return math.floor(32 * scale)
end

-- ========================
-- ISUIElement subclass
-- ========================

local RQDazedMoodle = ISUIElement:derive("RQDazedMoodle")

function RQDazedMoodle:new(player)
    local size = getMoodleSize()
    local o = ISUIElement:new(0, 0, size, size)
    setmetatable(o, self)
    self.__index = self

    o.player    = player
    o.playerNum = player:getPlayerNum()
    o.active    = false
    o.title     = ""
    o.desc      = ""

    -- Textures: size-keyed vanilla paths. Fallback to 32 if size variant missing.
    local sStr = tostring(size)
    o.texIcon   = getTexture("media/ui/Moodles/" .. sStr .. "/Mood_Dizzy.png")
                  or getTexture("media/ui/Moodles/32/Mood_Dizzy.png")
    o.texBkg    = getTexture("media/ui/Moodles/" .. sStr .. "/_Moodles_BGsolid.png")
                  or getTexture("media/ui/Moodles/32/_Moodles_BGsolid.png")
    o.texBorder = getTexture("media/ui/Moodles/" .. sStr .. "/_Moodles_BGoutline.png")
                  or getTexture("media/ui/Moodles/32/_Moodles_BGoutline.png")

    o.borderColor     = { r=0, g=0, b=0, a=0 }
    o.backgroundColor = { r=0, g=0, b=0, a=0 }
    o.keepOnScreen    = false

    o:initialise()
    return o
end

-- Count active vanilla moodles so we stack below them.
-- B42 uses Registries.MOODLE_TYPE:values() — MoodleType.FromIndex no longer exists.
local function countVanillaMoodles(player)
    local count = 0
    local moodles      = player:getMoodles()
    local moodleValues = Registries.MOODLE_TYPE:values()
    local numMoodles   = moodleValues:size()
    for i = 0, numMoodles - 1 do
        local mType  = moodleValues:get(i)
        local mLevel = moodles:getMoodleLevel(mType)
        if mLevel ~= 0 and (mType ~= MoodleType.FOOD_EATEN or mLevel >= 3) then
            count = count + 1
        end
    end
    return count
end

function RQDazedMoodle:computePosition()
    local size = getMoodleSize()
    local step = size + 10
    local pn   = self.playerNum
    local x    = getPlayerScreenLeft(pn) + getPlayerScreenWidth(pn) - X_OFFSET - size
    local y    = getPlayerScreenTop(pn)  + Y_OFFSET
    y = y + countVanillaMoodles(self.player) * step
    return x, y, size
end

function RQDazedMoodle:render()
    if not self.active then return end

    local x, y, size = self:computePosition()
    self:setX(x)
    self:setY(y)
    self:setWidth(size)
    self:setHeight(size)

    if self.texBkg    then self:drawTextureScaled(self.texBkg,    0, 0, size, size, 1) end
    if self.texBorder then self:drawTextureScaled(self.texBorder, 0, 0, size, size, 1) end
    if self.texIcon   then self:drawTextureScaled(self.texIcon,   0, 0, size, size, 1) end

    -- Tooltip: render to the left, matching vanilla moodle tooltip style
    if self:isMouseOver() then
        local font = UIFont.Small
        local pad  = 3
        local tm   = getTextManager()
        local tW   = math.max(tm:MeasureStringX(font, self.title),
                              tm:MeasureStringX(font, self.desc)) + pad * 2
        local tH   = tm:MeasureStringY(font, self.title)
        local dH   = tm:MeasureStringY(font, self.desc)
        local boxH = tH + dH + pad * 3
        local boxX = -(tW + 6)
        local boxY = math.max(0, math.floor((size - boxH) / 2))
        self:drawRect(boxX, boxY, tW, boxH, 0.7, 0, 0, 0)
        self:drawText(self.title, boxX + pad, boxY + pad,          1, 1, 1, 1, font)
        self:drawText(self.desc,  boxX + pad, boxY + pad + tH + pad, 1, 1, 1, 0.7, font)
    end
end

function RQDazedMoodle:show(traitName)
    local info  = TRAIT_INFO[traitName] or TRAIT_INFO.normal
    self.title  = info.title
    self.desc   = info.desc
    self.active = true
    if not self.addedToUI then
        self:addToUIManager()
        self.addedToUI = true
    end
end

function RQDazedMoodle:hide()
    self.active = false
    if self.addedToUI then
        self:removeFromUIManager()
        self.addedToUI = false
    end
end

-- ========================
-- Per-player instance table
-- ========================

local instances = {}  -- playerNum -> RQDazedMoodle

local function getInstance(playerNum)
    return instances[playerNum]
end

local function createInstance(playerNum)
    local player = getSpecificPlayer(playerNum)
    if not player then return nil end
    local m = RQDazedMoodle:new(player)
    instances[playerNum] = m
    return m
end

local function getOrCreateInstance(playerNum)
    return getInstance(playerNum) or createInstance(playerNum)
end

local function clearInstances()
    for _, m in pairs(instances) do
        if m and m.addedToUI then
            m:removeFromUIManager()
            m.addedToUI = false
        end
    end
    instances = {}
end

Events.OnCreatePlayer.Add(function(playerNum)
    createInstance(playerNum)
end)

Events.OnGameStart.Add(clearInstances)

-- ========================
-- Public API (called by RQScreamer)
-- ========================

function RQMoodle.setDazed(playerNum, traitName)
    local m = getOrCreateInstance(playerNum)
    if m then m:show(traitName) end
end

function RQMoodle.clearDazed(playerNum)
    local m = getInstance(playerNum)
    if m then m:hide() end
end

-- Copyright Project_Omen
