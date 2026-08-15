-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCSpawnWindow - the staff vehicle spawner (client).
--
-- The donor mod's genuinely good flow, kept: configure in a window -> Spawn
-- arms placement mode -> a full-width banner says so -> every world click
-- places a vehicle at the cursor until CLOSE MODE. Everything AROUND that
-- flow is rebuilt to house rules:
--   * every gate here is DECORATIVE (hides tools). The server re-checks the
--     sender on the shared RCShared.canUseSpawner ladder for every command -
--     the donor's server handler trusted any packet that knew its name, which
--     is the exploited hole this replaces.
--   * the condition picker sends an ENUM ("random"/"perfect"/"average"/"low");
--     the server rolls per spawn. The donor baked ZombRand(0,101) into the
--     combo at window-build time, so "Random" was one frozen number/session.
--   * the catalogue fixes the donor's table.sort-returns-nil bug (its manual
--     picker iterated nil) and its pairs()-ordered type dropdown (order
--     shuffled between sessions); soft-deps key off the RVInterior GLOBAL,
--     never the mod id (the RCRVGate contract).
--
-- Two doors in: the world right-click option (donor UX) and the Spawn...
-- button on the Dragonfly Vehicles tab (RCVehicleTab).

if isServer() and not isClient() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

RCSpawnWindow = ISCollapsableWindow:derive("RCSpawnWindow")
RCSpawnWindow.instance = nil

local M     = RCShared.MODULE
local PAD   = 10
local CTL_X = 170

-- One flag arms placement; the banner below and the mouse handler at the
-- bottom are its only readers.
local armed = false

-- ---------------------------------------------------------------------------
-- Catalogue: the picker lists, built from the ScriptManager at window-open.
-- Ordered array of { key, label, list = { {fullName, shortName}, ... } }.
-- ---------------------------------------------------------------------------
local function buildCatalogue()
    local scripts = getScriptManager():getAllVehicleScripts()
    -- Soft-dep on any RV-interior mod via its GLOBAL, never the mod id.
    local rv = (RVInterior ~= nil and RVInterior.getVehicleName ~= nil)

    local cats = {
        { key = "usable",   label = getText("IGUI_RC_Spawn_CatUsable"),   list = {} },
        { key = "trailers", label = getText("IGUI_RC_Spawn_CatTrailers"), list = {} },
        { key = "burned",   label = getText("IGUI_RC_Spawn_CatBurned"),   list = {} },
        { key = "smashed",  label = getText("IGUI_RC_Spawn_CatSmashed"),  list = {} },
        { key = "wrecks",   label = getText("IGUI_RC_Spawn_CatWrecks"),   list = {} },
        { key = "all",      label = getText("IGUI_RC_Spawn_CatAll"),      list = {} },
    }
    if rv then
        table.insert(cats, 3, { key = "withInterior", label = getText("IGUI_RC_Spawn_CatWithInterior"), list = {} })
        table.insert(cats, 4, { key = "noInterior",   label = getText("IGUI_RC_Spawn_CatNoInterior"),   list = {} })
    end
    local byKey = {}
    for _, c in ipairs(cats) do byKey[c.key] = c.list end

    for i = 0, scripts:size() - 1 do
        local script = scripts:get(i)
        local full, short = script:getFullName(), script:getName()
        local lower   = string.lower(short or "")
        local burnt   = string.contains(lower, "burnt")
        local smashed = string.contains(lower, "smashed")
        local wreck   = burnt or smashed
        local seats   = script:getPassengerCount() or 0
        local row     = { full, short }

        table.insert(byKey.all, row)
        if burnt then table.insert(byKey.burned, row); table.insert(byKey.wrecks, row) end
        if smashed then table.insert(byKey.smashed, row); table.insert(byKey.wrecks, row) end
        if not wreck and seats > 0 then table.insert(byKey.usable, row) end
        if not wreck and seats == 0 then table.insert(byKey.trailers, row) end

        if rv and not wreck then
            local interior
            -- guarded: RVInterior is a foreign mod - its lookup is not ours to trust
            pcall(function() interior = RVInterior.getVehicleName(full, true) end)
            if interior ~= nil then
                table.insert(byKey.withInterior, row)
            elseif seats > 0 then
                table.insert(byKey.noInterior, row)
            end
        end
    end

    -- The donor's bug: it STORED table.sort's return (nil). Sort in place
    -- first, keep the table.
    for _, c in ipairs(cats) do
        table.sort(c.list, function(a, b) return a[1] < b[1] end)
    end
    return cats
end

-- ---------------------------------------------------------------------------
-- Spawn-mode banner (full-width top strip). Donor colors kept.
-- ---------------------------------------------------------------------------
local SpawnBanner = ISPanel:derive("RCSpawnBanner")
SpawnBanner.instance = nil

function SpawnBanner:createChildren()
    ISPanel.createChildren(self)
    local label = ISLabel:new(0, 0, 40, getText("IGUI_RC_SpawnModeActive"), 0, 1, 0, 1, UIFont.Large, true)
    label:initialise()
    label:setX((self:getWidth() - label:getWidth()) / 2)
    self:addChild(label)
    local btn = ISButton:new(label:getX() + label:getWidth() + 12, 5, 110, 30,
        getText("IGUI_RC_SpawnModeClose"), self, SpawnBanner.onClose)
    btn:initialise()
    self:addChild(btn)
end

function SpawnBanner:prerender()
    self:drawRect(0, 0, self:getWidth(), self:getHeight(), 1, 0, 0.7, 0)
end

function SpawnBanner:onClose()
    armed = false            -- disarm FIRST (see onWorldMouseDown race note)
    SpawnBanner.hide()
    if RCSpawnWindow.instance then
        RCSpawnWindow.instance:setVisible(true)
        RCSpawnWindow.instance:bringToTop()
    end
end

function SpawnBanner.show()
    if not SpawnBanner.instance then
        local o = SpawnBanner:new(0, 0, getCore():getScreenWidth(), 40)
        o:initialise()
        o:addToUIManager()
        SpawnBanner.instance = o
    else
        SpawnBanner.instance:setVisible(true)
        SpawnBanner.instance:bringToTop()
    end
end

function SpawnBanner.hide()
    if SpawnBanner.instance then SpawnBanner.instance:setVisible(false) end
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------
function RCSpawnWindow.open(playerObj)
    playerObj = playerObj or getPlayer()
    -- Decorative gate: hides the tool. The server re-gates every command.
    if not RCShared.canUseSpawner(playerObj) then return end
    if RCSpawnWindow.instance then
        RCSpawnWindow.instance:setVisible(true)
        RCSpawnWindow.instance:bringToTop()
        return RCSpawnWindow.instance
    end
    local w, h = 560, 354
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = RCSpawnWindow:new(x, y, w, h, playerObj)
    o:initialise()
    o:addToUIManager()
    -- Instance is REUSED across opens on purpose (donor behavior kept): an
    -- admin placing a themed scene keeps their selections between opens.
    RCSpawnWindow.instance = o
    return o
end

function RCSpawnWindow:new(x, y, w, h, playerObj)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title     = getText("IGUI_RC_SpawnTitle")
    o.playerObj = playerObj
    o.resizable = false
    o.pin       = true
    return o
end

function RCSpawnWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local th = getTextManager():getFontHeight(UIFont.Small)
    local y = self:titleBarHeight() + PAD
    local comboW = self.width - CTL_X - PAD

    self.catalogue = buildCatalogue()

    -- direction
    local lblDir = ISLabel:new(PAD, y + 4, th, getText("IGUI_RC_SpawnDirection"), 1, 1, 1, 1, UIFont.Small, true)
    lblDir:initialise(); self:addChild(lblDir)
    self.directionCombo = ISComboBox:new(CTL_X, y, 140, 25, self)
    self.directionCombo:addOptionWithData(getText("IGUI_RC_Spawn_DirRandom"), 0)
    self.directionCombo:addOptionWithData(getText("IGUI_RC_Spawn_DirWest"),   1)
    self.directionCombo:addOptionWithData(getText("IGUI_RC_Spawn_DirEast"),   2)
    self.directionCombo:addOptionWithData(getText("IGUI_RC_Spawn_DirNorth"),  3)
    self.directionCombo:addOptionWithData(getText("IGUI_RC_Spawn_DirSouth"),  4)
    self:addChild(self.directionCombo)
    y = y + 25 + 8

    -- condition: data is an ENUM string; the server rolls (see RCSpawn)
    local lblCond = ISLabel:new(PAD, y + 4, th, getText("IGUI_RC_SpawnCondition"), 1, 1, 1, 1, UIFont.Small, true)
    lblCond:initialise(); self:addChild(lblCond)
    self.conditionCombo = ISComboBox:new(CTL_X, y, 140, 25, self)
    self.conditionCombo:addOptionWithData(getText("IGUI_RC_Spawn_CondRandom"),  "random")
    self.conditionCombo:addOptionWithData(getText("IGUI_RC_Spawn_CondPerfect"), "perfect")
    self.conditionCombo:addOptionWithData(getText("IGUI_RC_Spawn_CondAverage"), "average")
    self.conditionCombo:addOptionWithData(getText("IGUI_RC_Spawn_CondLow"),     "low")
    self.conditionCombo.tooltip = getText("IGUI_RC_SpawnCondTip")
    self:addChild(self.conditionCombo)
    y = y + 25 + 8

    -- flags (donor's three, one tickbox each - donor-proven layout)
    self.noFuelCheck = ISTickBox:new(PAD, y, 20, 20, "", self, nil)
    self.noFuelCheck:initialise(); self:addChild(self.noFuelCheck)
    self.noFuelCheck:addOption(getText("IGUI_RC_SpawnNoFuel"))
    y = y + 24
    self.noBatteryCheck = ISTickBox:new(PAD, y, 20, 20, "", self, nil)
    self.noBatteryCheck:initialise(); self:addChild(self.noBatteryCheck)
    self.noBatteryCheck:addOption(getText("IGUI_RC_SpawnNoBattery"))
    y = y + 24
    self.keyGloveboxCheck = ISTickBox:new(PAD, y, 20, 20, "", self, nil)
    self.keyGloveboxCheck:initialise(); self:addChild(self.keyGloveboxCheck)
    self.keyGloveboxCheck:addOption(getText("IGUI_RC_SpawnKeyGlovebox"))
    y = y + 24
    -- missing parts: server strips a random handful of installable parts
    -- (never the engine); the count is rolled per spawn, server-side.
    self.missingPartsCheck = ISTickBox:new(PAD, y, 20, 20, "", self, nil)
    self.missingPartsCheck:initialise(); self:addChild(self.missingPartsCheck)
    self.missingPartsCheck:addOption(getText("IGUI_RC_SpawnMissingParts"))
    self.missingPartsCheck.tooltip = getText("IGUI_RC_SpawnMissingPartsTip")
    y = y + 24 + 10

    -- what to spawn: radio pair + the two pickers
    local lblWhat = ISLabel:new(PAD, y, th, getText("IGUI_RC_SpawnTypeHeader"), 1, 1, 1, 1, UIFont.Small, true)
    lblWhat:initialise(); self:addChild(lblWhat)
    y = y + th + 6

    self.modeTicks = ISTickBox:new(PAD, y, 20, 20, "", self, nil)
    self.modeTicks:initialise()
    self.modeTicks.onlyOnePossibility = true
    self:addChild(self.modeTicks)
    self.modeTicks:addOption(getText("IGUI_RC_SpawnManual"))
    self.modeTicks:addOption(getText("IGUI_RC_SpawnByType"))
    self.modeTicks.selected[1] = false
    self.modeTicks.selected[2] = true

    -- manual picker (editable = type-to-filter), from the "all" category
    self.manualCombo = ISComboBox:new(CTL_X, y, comboW, 25, self)
    for _, c in ipairs(self.catalogue) do
        if c.key == "all" then
            for _, v in ipairs(c.list) do
                self.manualCombo:addOptionWithData(v[1] .. " - " .. getText("IGUI_VehicleName" .. v[2]), v[1])
            end
        end
    end
    self.manualCombo:initialise()
    self.manualCombo:setEditable(true)
    self:addChild(self.manualCombo)

    -- category picker; option data is the catalogue entry itself
    self.typeCombo = ISComboBox:new(CTL_X, y + 25, comboW, 25, self)
    for _, c in ipairs(self.catalogue) do
        self.typeCombo:addOptionWithData(c.label, c)
    end
    self:addChild(self.typeCombo)
    y = y + 50 + 12

    -- buttons (donor placement: Close left of Spawn, bottom-right)
    self.closeBtn = ISButton:new(self.width - 170, y, 80, 30, getText("IGUI_RC_SpawnCloseBtn"), self, RCSpawnWindow.onCloseBtn)
    self.closeBtn:initialise(); self:addChild(self.closeBtn)
    self.spawnBtn = ISButton:new(self.width - 85, y, 80, 30, getText("IGUI_RC_SpawnBtn"), self, RCSpawnWindow.onSpawn)
    self.spawnBtn:initialise(); self:addChild(self.spawnBtn)
end

-- Close button HIDES (selections survive); the title-bar X closes for real.
function RCSpawnWindow:onCloseBtn()
    self:setVisible(false)
end

function RCSpawnWindow:onSpawn()
    -- An editable combo can sit on typed text with no selection: verify a
    -- manual pick exists BEFORE arming, not at click time.
    if self.modeTicks.selected[1] then
        local opt = self.manualCombo.options[self.manualCombo.selected]
        if not (opt and opt.data) then
            RCShared.halo(getPlayer(), getText("IGUI_RC_SpawnPickVehicle"), true)
            return
        end
    end
    armed = true
    self:setVisible(false)
    SpawnBanner.show()
end

-- Read the live control state into a spawn spec. Called at PLACEMENT time so
-- every click re-reads - and a category pick re-rolls per click. The random
-- pick here is UI sugar only; the server validates whatever model arrives.
function RCSpawnWindow:readSpec(playerObj)
    local model
    if self.modeTicks.selected[1] then
        local opt = self.manualCombo.options[self.manualCombo.selected]
        model = opt and opt.data or nil
    else
        local opt = self.typeCombo.options[self.typeCombo.selected]
        local list = opt and opt.data and opt.data.list or nil
        if list and #list > 0 then
            model = list[ZombRand(1, #list + 1)][1]
        end
    end
    if not model then return nil end

    local wx, wy = ISCoordConversion.ToWorld(getMouseXScaled(), getMouseYScaled(), playerObj:getZ() or 0)
    return {
        model       = model,
        x           = math.floor(wx),
        y           = math.floor(wy),
        z           = math.floor(playerObj:getZ() or 0),
        direction   = self.directionCombo.options[self.directionCombo.selected].data,
        condition   = self.conditionCombo.options[self.conditionCombo.selected].data,
        noFuel      = self.noFuelCheck:isSelected(1),
        noBattery   = self.noBatteryCheck:isSelected(1),
        keyGlovebox = self.keyGloveboxCheck:isSelected(1),
        missingParts = self.missingPartsCheck:isSelected(1),
    }
end

-- Title-bar X: tear down for real (disarm + drop the banner with it).
function RCSpawnWindow:close()
    armed = false
    SpawnBanner.hide()
    RCSpawnWindow.instance = nil
    ISCollapsableWindow.close(self)
end

-- ---------------------------------------------------------------------------
-- Armed-mode placement. Events.OnMouseDown also fires for clicks that land on
-- UI, so the banner strip is explicitly excluded - otherwise the CLOSE MODE
-- click itself could race one final spawn (the banner's onClose also disarms
-- BEFORE hiding for the same reason).
-- ---------------------------------------------------------------------------
local function onWorldMouseDown(x, y)
    if not armed then return end
    local inst = RCSpawnWindow.instance
    if not inst then armed = false; return end

    local banner = SpawnBanner.instance
    if banner and banner:isVisible() and y <= banner:getHeight() then return end

    local playerObj = getPlayer()
    if not playerObj then return end
    -- Decorative re-check (config may have flipped mid-session); the server's
    -- check on the sender is the one that counts.
    if not RCShared.canUseSpawner(playerObj) then
        armed = false
        SpawnBanner.hide()
        return
    end

    local spec = inst:readSpec(playerObj)
    if not spec then return end
    sendClientCommand(playerObj, M, "spawnvehicle", spec)
end
Events.OnMouseDown.Add(onWorldMouseDown)

-- ---------------------------------------------------------------------------
-- Door #1: the world right-click option (donor UX kept). Door #2 is the
-- Spawn... button on the Dragonfly Vehicles tab (RCVehicleTab).
-- ---------------------------------------------------------------------------
-- OnPreFill, not OnFill: vanilla suppresses OnFillWorldObjectContextMenu when
-- the clicked square has nothing pickable (fetch.c == 0) and inside a
-- non-owned safehouse (fetch.safehouseAllowInteract) - exactly the open
-- ground you place vehicles on. OnPreFill fires unconditionally, same args.
local function onPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or not RCShared.canUseSpawner(playerObj) then return end
    context:addOption(getText("IGUI_RC_SpawnMenu"), playerObj, RCSpawnWindow.open)
end
Events.OnPreFillWorldObjectContextMenu.Add(onPreFillWorldObjectContextMenu)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
