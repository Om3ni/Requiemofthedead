-- Echoes: the UI capability probe. Every claim UISCHEMA.md makes about the
-- 42.20 engine, drawn live so it can be seen, not believed. Staff/debug only:
-- right-click the world -> "Echoes: UI Probe". Page through with the buttons;
-- anything that renders wrong here gets struck from the schema vocabulary
-- before a real panel ever depends on it.
--
-- Deliberately zero dependencies on the songbook or the future schema
-- renderer - raw calls only, so a failure indicts the engine claim and
-- nothing else.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISUI3DModel"

ECUIProbe = ISCollapsableWindow:derive("ECUIProbe")
ECUIProbe.instance = nil

local FONT_HGT = getTextManager():getFontHeight(UIFont.Small)

-- Machine-readable verdicts: every line prefixed ECPROBE| lands in
-- console.txt, so the API half of the probe can be harvested without eyes.
-- Declared BEFORE the pages table - page closures capture it lexically.
local function verdict(...)
    print("ECPROBE|" .. table.concat({...}, "|"))
end

-- Each page: { title, note, draw = function(self, x, y, w, h) }.
local pages = {}

local function white()
    return Texture.getWhite()
end

local function sampleIcon()
    -- Any shipped texture works; the sheet music icon is ours and always present.
    return getTexture("media/textures/Item_SheetMusic.png")
end

-- Page 1: free-quad + rotation ----------------------------------------------
table.insert(pages, {
    title = "Free-quad + DrawTextureAngle",
    note = "Left: corners skewed independently (fake perspective). Right: continuous rotation.",
    draw = function(self, x, y, w, h)
        local tex = sampleIcon()
        if not tex then return end
        local t = (getTimestampMs() % 4000) / 4000
        local lean = math.sin(t * math.pi * 2) * 30
        -- Skewed quad: top edge slides while the bottom stays planted.
        self.javaObject:DrawTexture(tex,
            x + 40 + lean, y + 20,          -- top-left
            x + 160 + lean, y + 30,         -- top-right
            x + 170, y + 150,               -- bottom-right
            x + 30, y + 140,                -- bottom-left
            1, 1, 1, 1)
        -- Rotation about a center.
        self.javaObject:DrawTextureAngle(tex, x + w - 110, y + 90, t * 360)
    end,
})

-- Page 2: stencils ------------------------------------------------------------
table.insert(pages, {
    title = "Stencil rect + stencil CIRCLE",
    note = "The moving bar is clipped by a rectangle on the left, a circle on the right.",
    draw = function(self, x, y, w, h)
        local t = (getTimestampMs() % 2000) / 2000
        local sweep = y + 10 + (h - 40) * t
        local half = math.floor(w / 2) - 20

        self:setStencilRect(x + 10, y + 30, half, h - 60)
        self:drawRect(x + 10, sweep, half, 14, 0.9, 0.75, 0.62, 0.30)
        self:clearStencilRect()

        self.javaObject:setStencilCircle(x + half + 30, y + 30, half, h - 60)
        self:drawRect(x + half + 30, sweep, half, 14, 0.9, 0.30, 0.62, 0.75)
        self:clearStencilRect()

        self:drawRectBorder(x + 10, y + 30, half, h - 60, 0.5, 1, 1, 1)
        self:drawRectBorder(x + half + 30, y + 30, half, h - 60, 0.5, 1, 1, 1)
    end,
})

-- Page 3: 9-slice + tiling ----------------------------------------------------
table.insert(pages, {
    title = "DrawUVSliceTexture + tiled fills",
    note = "Top: UV sub-rects of one texture (9-slice chrome). Bottom: X-tiled strip.",
    draw = function(self, x, y, w, h)
        local tex = sampleIcon()
        if not tex then return end
        local col = Color.new(1, 1, 1, 1)
        -- Four corner slices of the same texture stretched into a frame.
        self.javaObject:DrawUVSliceTexture(tex, x + 20, y + 20, 60, 60, col, 0.0, 0.0, 0.5, 0.5)
        self.javaObject:DrawUVSliceTexture(tex, x + 140, y + 20, 60, 60, col, 0.5, 0.0, 1.0, 0.5)
        self.javaObject:DrawUVSliceTexture(tex, x + 20, y + 90, 60, 60, col, 0.0, 0.5, 0.5, 1.0)
        self.javaObject:DrawUVSliceTexture(tex, x + 140, y + 90, 60, 60, col, 0.5, 0.5, 1.0, 1.0)
        self.javaObject:DrawTextureTiledX(tex, x + 20, y + h - 60, w - 40, 32, 1, 1, 1, 0.8)
    end,
})

-- Page 4: mask fills + item icons --------------------------------------------
table.insert(pages, {
    title = "Percentage fills + DrawItemIcon",
    note = "Meters from a texture mask, no bar art. Right: engine-drawn item icons at any size.",
    draw = function(self, x, y, w, h)
        local tex = sampleIcon()
        if not tex then return end
        local t = (getTimestampMs() % 3000) / 3000
        self.javaObject:DrawTexturePercentage(tex, t, x + 30, y + 30, 64, 64, 1, 1, 1, 1)
        self.javaObject:DrawTexturePercentageBottomUp(tex, t, x + 120, y + 30, 64, 64, 0.75, 0.62, 0.30, 1)
        local player = getPlayer()
        local item = player and player:getPrimaryHandItem()
        if item then
            self.javaObject:DrawItemIcon(item, x + w - 150, y + 20, 1.0, 128, 128)
            self:drawText("held item, 128px", x + w - 150, y + 155, 0.6, 0.6, 0.6, 1, UIFont.Small)
        else
            self:drawText("(hold an item to see DrawItemIcon)", x + w - 260, y + 60, 0.6, 0.6, 0.6, 1, UIFont.Small)
        end
    end,
})

-- Page 5: SDF fonts -----------------------------------------------------------
table.insert(pages, {
    title = "SDF + flavor fonts",
    note = "Crisp-at-scale family plus Handwritten/Dialogue/Title. Judge small-size legibility here.",
    draw = function(self, x, y, w, h)
        local rows = {
            { UIFont.SdfRegular, "SdfRegular - the quick brown zombie" },
            { UIFont.SdfBold, "SdfBold - the quick brown zombie" },
            { UIFont.SdfItalic, "SdfItalic - the quick brown zombie" },
            { UIFont.SdfBoldItalic, "SdfBoldItalic - the quick brown zombie" },
            { UIFont.Handwritten, "Handwritten - for sheet music margins" },
            { UIFont.Dialogue, "Dialogue - spoken flavor" },
            { UIFont.Title, "Title - ECHOES" },
        }
        local yy = y + 16
        for _, row in ipairs(rows) do
            local ok = pcall(function()
                self:drawText(row[2], x + 20, yy, 0.92, 0.90, 0.84, 1, row[1])
            end)
            if not ok then
                self:drawText("[font unavailable] " .. row[2], x + 20, yy, 0.8, 0.3, 0.3, 1, UIFont.Small)
            end
            yy = yy + 30
        end
    end,
})

-- Page 6: lines + polygons ----------------------------------------------------
table.insert(pages, {
    title = "DrawLine (thickness) + DrawPolygon",
    note = "Thick animated line; textured 4-point polygon.",
    draw = function(self, x, y, w, h)
        local t = (getTimestampMs() % 4000) / 4000
        local ang = t * math.pi * 2
        local cx, cy = x + 110, y + 90
        self.javaObject:DrawLine(white(), cx, cy,
            cx + math.cos(ang) * 80, cy + math.sin(ang) * 80,
            4.0, 0.75, 0.62, 0.30, 1)
        local tex = sampleIcon()
        if tex then
            self.javaObject:DrawPolygon(tex,
                x + w - 200, y + 30,
                x + w - 60, y + 50,
                x + w - 80, y + 160,
                x + w - 220, y + 140,
                1, 1, 1, 0.9)
        end
    end,
})

-- Page 7: 3D portrait ---------------------------------------------------------
table.insert(pages, {
    title = "UI3DModel - the portrait question",
    note = "Your character, live. PROBE: is the held instrument visible? Does it animate?",
    setup = function(self, x, y, w, h)
        if self.model3d then return end
        local player = getPlayer()
        if not player then return end
        self.model3d = ISUI3DModel:new(x, y, math.min(220, w - 20), h - 20)
        self.model3d:initialise()
        self.model3d:instantiate()
        self:addChild(self.model3d)
        -- Each sub-probe gets its own verdict; the vanilla wrapper's method
        -- is setAnimateWhilePaused (there is no setAnimate - found the loud way).
        local steps = {
            { "setCharacter", function() self.model3d:setCharacter(player) end },
            { "setDirection", function() self.model3d:setDirection(IsoDirections.S) end },
            { "animateWhilePaused", function() self.model3d:setAnimateWhilePaused(true) end },
            { "setState_idle", function() self.model3d:setState("idle") end },
            -- The money probe: our AnimSet condition variable on the doll.
            { "var_PerformingAction_ECPlay", function() self.model3d:setVariable("PerformingAction", "ECPlayGuitarAcoustic") end },
        }
        for _, step in ipairs(steps) do
            local ok, err = pcall(step[2])
            verdict("p7", step[1], ok and "ok" or ("FAIL " .. tostring(err)))
        end
    end,
    draw = function(self, x, y, w, h)
        self:drawText("equip an instrument, reopen this page,", x + 240, y + 30, 0.7, 0.7, 0.7, 1, UIFont.Small)
        self:drawText("then judge: doll? held item? animation?", x + 240, y + 30 + FONT_HGT + 2, 0.7, 0.7, 0.7, 1, UIFont.Small)
    end,
    teardown = function(self)
        if self.model3d then
            self:removeChild(self.model3d)
            self.model3d = nil
        end
    end,
})

-- Page 8: radial progress -----------------------------------------------------
-- RadialProgressBar is a UIElement subclass: constructor is (luaSelfTable,
-- texture) - the standard PZ wrapper contract - and render() draws itself in
-- the element tree. So it gets a proper ISUIElement wrapper, not a static call.
local ECRadialWrap = ISUIElement:derive("ECRadialWrap")
function ECRadialWrap:instantiate()
    self.javaObject = RadialProgressBar.new(self, sampleIcon())
    self.javaObject:setX(self.x)
    self.javaObject:setY(self.y)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
end

table.insert(pages, {
    title = "RadialProgressBar (native)",
    note = "Engine radial fill, driven 0..1. If this sweeps, a quick-play wheel is a primitive, not a project.",
    setup = function(self, x, y, w, h)
        if self.radial then return end
        local wrap = ECRadialWrap:new(x + 80, y + 30, 96, 96)
        wrap:initialise()
        wrap:instantiate()
        self:addChild(wrap)
        self.radial = wrap
    end,
    draw = function(self, x, y, w, h)
        if self.radial and self.radial.javaObject then
            local t = (getTimestampMs() % 3000) / 3000
            self.radial.javaObject:setValue(t)
            self:drawText(string.format("setValue(%.2f)", t), x + 200, y + 60, 0.62, 0.62, 0.62, 1, UIFont.Small)
        end
    end,
    teardown = function(self)
        if self.radial then
            self:removeChild(self.radial)
            self.radial = nil
        end
    end,
})

-- Window ---------------------------------------------------------------------

local function rollCall()
    local checks = {
        { "Texture.getWhite", function() return Texture.getWhite() ~= nil end },
        -- Exposure checks only: calling exposed Java constructors with wrong
        -- arg counts detonates OUTSIDE pcall (engine arg validation), learned
        -- the loud way. Construction is proven on page 8 with correct args.
        { "RadialProgressBar.global", function() return RadialProgressBar ~= nil end },
        { "RadialMenu.global", function() return RadialMenu ~= nil end },
        { "UI3DScene.global", function() return UI3DScene ~= nil end },
        { "PZAPI.UI.atoms", function() return PZAPI ~= nil and PZAPI.UI ~= nil and PZAPI.UI.Node ~= nil end },
        { "UIFont.SdfRegular", function() return UIFont.SdfRegular ~= nil end },
        { "UIFont.Handwritten", function() return UIFont.Handwritten ~= nil end },
        { "CharacterTrait.echoes", function() return ECCore ~= nil and ECCore.SavantTrait ~= nil end },
    }
    for _, check in ipairs(checks) do
        local ok, result = pcall(check[2])
        verdict("rollcall", check[1], ok and tostring(result) or ("ERR " .. tostring(result)))
    end
end

function ECUIProbe:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()

    self.prevButton = ISButton:new(10, self.height - 32, 70, 24, "< Prev", self, ECUIProbe.onPrev)
    self.prevButton:initialise()
    self:addChild(self.prevButton)

    self.nextButton = ISButton:new(90, self.height - 32, 70, 24, "Next >", self, ECUIProbe.onNext)
    self.nextButton:initialise()
    self:addChild(self.nextButton)

    self.autoButton = ISButton:new(170, self.height - 32, 110, 24, "Auto Run", self, ECUIProbe.onAuto)
    self.autoButton:initialise()
    self:addChild(self.autoButton)

    self.pageIndex = 1
    self.pageVerdicts = {}
    self:enterPage()
end

function ECUIProbe:onAuto()
    verdict("auto", "start")
    rollCall()
    self:leavePage()
    self.pageIndex = 1
    self.autoMode = true
    self.autoDeadline = getTimestampMs() + 2500
    self:enterPage()
end

function ECUIProbe:contentArea()
    local th = self:titleBarHeight()
    return 10, th + 8 + FONT_HGT * 2 + 8, self.width - 20, self.height - (th + 8 + FONT_HGT * 2 + 8) - 44
end

function ECUIProbe:enterPage()
    local page = pages[self.pageIndex]
    if page and page.setup then
        local x, y, w, h = self:contentArea()
        local ok, setupErr = pcall(page.setup, self, x, y, w, h)
        if not ok then
            verdict("page", tostring(self.pageIndex), page.title, "SETUP_FAIL " .. tostring(setupErr))
        end
    end
end

function ECUIProbe:leavePage()
    local page = pages[self.pageIndex]
    if page and page.teardown then
        page.teardown(self)
    end
end

function ECUIProbe:onPrev()
    self:leavePage()
    self.pageIndex = self.pageIndex > 1 and self.pageIndex - 1 or #pages
    self:enterPage()
end

function ECUIProbe:onNext()
    self:leavePage()
    self.pageIndex = self.pageIndex < #pages and self.pageIndex + 1 or 1
    self:enterPage()
end

function ECUIProbe:prerender()
    ISCollapsableWindow.prerender(self)
    local page = pages[self.pageIndex]
    if not page then return end
    local th = self:titleBarHeight()
    self:drawText(string.format("[%d/%d] %s", self.pageIndex, #pages, page.title),
        10, th + 6, 0.75, 0.62, 0.30, 1, UIFont.Medium)
    self:drawText(page.note, 10, th + 8 + FONT_HGT, 0.62, 0.62, 0.62, 1, UIFont.Small)
    local x, y, w, h = self:contentArea()

    local ok, drawErr = pcall(page.draw, self, x, y, w, h)
    if self.pageVerdicts[self.pageIndex] == nil then
        self.pageVerdicts[self.pageIndex] = true
        verdict("page", tostring(self.pageIndex), page.title,
            ok and "draw_ok" or ("DRAW_FAIL " .. tostring(drawErr)))
    end
    if not ok then
        self:drawText("DRAW FAILED - see console.txt", x, y, 0.9, 0.2, 0.2, 1, UIFont.Medium)
    end

    if self.autoMode and getTimestampMs() >= self.autoDeadline then
        if self.pageIndex >= #pages then
            self.autoMode = false
            verdict("auto", "complete")
        else
            self:onNext()
            self.autoDeadline = getTimestampMs() + 2500
        end
    end
end

function ECUIProbe:close()
    self:leavePage()
    self:setVisible(false)
    self:removeFromUIManager()
    if ECUIProbe.instance == self then
        ECUIProbe.instance = nil
    end
end

function ECUIProbe.open()
    if ECUIProbe.instance then
        ECUIProbe.instance:close()
    end
    local o = ECUIProbe:new(120, 120, 640, 420)
    o:initialise()
    o:addToUIManager()
    ECUIProbe.instance = o
end

function ECUIProbe:new(x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.title = "Echoes: UI Probe"
    o.resizable = true
    o.minimumWidth = 480
    o.minimumHeight = 340
    return o
end

-- Access: staff or debug builds only.
Events.OnFillWorldObjectContextMenu.Add(function(playerIdx, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerIdx)
    if not player then return end
    if not getDebug() and player:getAccessLevel() == "None" then return end
    context:addOption("Echoes: UI Probe", nil, ECUIProbe.open)
end)
