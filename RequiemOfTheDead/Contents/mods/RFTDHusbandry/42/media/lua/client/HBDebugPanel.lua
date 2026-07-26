-- HBDebugPanel — admin developer tool for animal state inspection.
-- Dark theme, monospace columns, explicit refresh. Not player-facing.
--
-- Step 1: skeleton with hardcoded test data. Proves the shell —
-- resizable, scrollable, log pane, refresh — before we wire in real
-- scanning (step 2) or the probe (step 3).

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISLabel"
require "ISUI/ISButton"

HBDebugPanel = ISCollapsableWindow:derive("HBDebugPanel")
HBDebugPanel._instance = nil

-- ─── Constants ───────────────────────────────────────────────────────────

local PAD        = 8
local ROW_H      = 18
local HEADER_H   = 22
local STATUS_H   = 22
local LOG_H      = 140
local BTN_H      = 24
local LOG_ROW_H  = 14

-- Column layout. `align = "right"` right-justifies numeric cells.
-- The dual hunger / thirst columns show the same value through two APIs
-- (animal:getHunger() vs animal:getStats():get(CharacterStat.HUNGER)) so
-- divergence is visible — vanilla appears to use both interchangeably but
-- we want eyes on it until the probe confirms.
local COLS = {
    { key = "oid",     label = "OID",      w = 70                    },
    { key = "id",      label = "RQHB",     w = 85                    },
    { key = "species", label = "Species",  w = 90                    },
    { key = "name",    label = "Name",     w = 140                   },
    { key = "sex",     label = "S",        w = 22                    },
    { key = "age",     label = "Age",      w = 50                    },
    { key = "hp",      label = "HP",       w = 44, align = "right"   },
    { key = "hngA",    label = "Hng:get",  w = 64, align = "right"   },
    { key = "hngB",    label = "Hng:stat", w = 64, align = "right"   },
    { key = "thrA",    label = "Thr:get",  w = 64, align = "right"   },
    { key = "thrB",    label = "Thr:stat", w = 64, align = "right"   },
    { key = "stress",  label = "Strs",     w = 44, align = "right"   },
    { key = "loc",     label = "Loc",      w = 70                    },
    { key = "seen",    label = "Seen",     w = 44                    },
}

local function totalColW()
    local t = 0
    for _, c in ipairs(COLS) do t = t + c.w end
    return t
end

-- Build a row from a live IsoAnimal. All accessors are pcall-wrapped so a
-- single broken method doesn't kill the whole row.
local function buildRow(animal, location)
    local row = {
        oid = 0, id = nil, species = "?", name = "?", sex = "?", age = "?",
        hp = 0, hngA = nil, hngB = nil, thrA = nil, thrB = nil,
        stress = 0, loc = location or "?", seen = false,
    }
    pcall(function() row.oid = animal:getOnlineID() or 0 end)
    pcall(function()
        local md = animal:getModData()
        if md and md[HBData.NS_ANIMAL] then row.id = md[HBData.NS_ANIMAL].id end
    end)
    pcall(function() row.species = animal:getAnimalType() or "?" end)
    pcall(function()
        local n = animal:getCustomName()
        if n and n ~= "" then row.name = n
        else row.name = animal:getFullName() or row.species end
    end)
    pcall(function() row.sex = animal:isFemale() and "F" or "M" end)
    pcall(function() row.age = animal:isBaby() and "Baby" or "Adult" end)
    -- getHealth() returns 0-1 like hunger/thirst (NOT 0-100 like player getHealth).
    -- Multiply by 100 for percent-style display. Verified via DBD_NearbyAnimals
    -- which does the same conversion (line 191 of that mod).
    pcall(function() row.hp = (animal:getHealth() or 0) * 100 end)
    pcall(function() row.hngA = animal:getHunger() end)
    pcall(function() row.hngB = animal:getStats():get(CharacterStat.HUNGER) end)
    pcall(function() row.thrA = animal:getThirst() end)
    pcall(function() row.thrB = animal:getStats():get(CharacterStat.THIRST) end)
    pcall(function() row.stress = animal:getStats():get(CharacterStat.STRESS) or 0 end)
    -- HBData is server-side; in SP both sides share the same Lua state so the
    -- read works directly. In MP this would need a server query.
    if HBData and HBData.seen and row.oid ~= 0 then
        row.seen = HBData.seen[row.oid] == true
    end
    return row
end

local TRAILER_SCAN_RANGE = 20  -- ±squares around player for trailer search

-- Scan for animals in two passes:
--   1. Loose animals via cell:getObjectListForLua().
--   2. Trailer animals — animals stored in a vehicle's animal container don't
--      appear in the cell object list, so we walk grid squares around the
--      player, look up the vehicle on each square via sq:getVehicleContainer()
--      (vanilla pattern, ISVehicleMenu.lua:42, DebugContextMenu.lua:142),
--      and ask each vehicle for getAnimals().
--
-- Every per-element block runs in its own pcall so a single broken animal,
-- vehicle, or grid square can't kill the whole scan.
local function scanCellAnimals()
    local rows = {}
    local cell = getCell()
    if not cell then return rows end

    local seen = {}

    -- ── Pass 1: loose animals via cell object list ─────────────────────
    local ok, objs = pcall(function() return cell:getObjectListForLua() end)
    if ok and objs and type(objs) ~= "boolean" then
        local count = 0
        pcall(function() count = objs:size() or 0 end)
        for i = 0, count - 1 do
            pcall(function()
                local obj = objs:get(i)
                if not obj then return end
                if not instanceof(obj, "IsoAnimal") then return end
                local oid = obj:getOnlineID()
                if not oid or oid == 0 or seen[oid] then return end
                seen[oid] = true
                -- Three-realm location detection (DBD pattern, ISAnimalUI.lua):
                --   getVehicle() → trailer-bound
                --   getHutch()   → in a hutch / coop
                --   else         → loose in the world
                local location = "loose"
                local v = obj:getVehicle()
                if v then
                    local vid = "?"
                    pcall(function() vid = tostring(v:getId() or "?") end)
                    location = "tr:" .. vid
                elseif obj:getHutch() then
                    location = "hutch"
                end
                rows[#rows + 1] = buildRow(obj, location)
            end)
        end
    end

    -- ── Pass 2: trailers + hutches via grid-square scan ────────────────
    -- Animals stored in vehicles (trailer container) or hutches (rabbit /
    -- chicken coops) are not in the cell's general object list. We have to
    -- walk grid squares and pull from the per-square accessors:
    --   sq:getVehicleContainer() → BaseVehicle, then v:getAnimals() (ArrayList)
    --   sq:getObjects()          → IsoHutch, then getAnimalInside() (HashMap)
    --     (avoid getMaxAnimals()/getAnimal(i): they read the hutch def and NPE
    --      inside the engine on a def==null hutch — pcall does not catch it)
    local seenVehicles = {}
    local seenHutches  = {}
    local player = getPlayer()
    if player then
        local sq = player:getCurrentSquare()
        if sq then
            local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
            for dx = -TRAILER_SCAN_RANGE, TRAILER_SCAN_RANGE do
                for dy = -TRAILER_SCAN_RANGE, TRAILER_SCAN_RANGE do
                    pcall(function()
                        local s = cell:getGridSquare(px + dx, py + dy, pz)
                        if not s then return end

                        -- Trailer animals
                        local v = s:getVehicleContainer()
                        if v then
                            local vid = v:getId()
                            if vid and not seenVehicles[vid] then
                                seenVehicles[vid] = true
                                local animals = v:getAnimals()
                                if animals then
                                    local n = animals:size() or 0
                                    for j = 0, n - 1 do
                                        local animal = animals:get(j)
                                        if animal then
                                            local oid = animal:getOnlineID()
                                            if oid and oid ~= 0 and not seen[oid] then
                                                seen[oid] = true
                                                rows[#rows + 1] = buildRow(animal, "tr:" .. tostring(vid))
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        -- Hutch animals (rabbits, chickens in coops). DBD pattern:
                        -- iterate sq:getObjects() looking for IsoHutch.
                        -- Use getAnimalInside() rather than getMaxAnimals()/
                        -- getAnimal(i): the latter read the hutch's script def
                        -- and NPE inside the engine on a broken (def==null)
                        -- hutch — an exception pcall does NOT catch (it aborts
                        -- the scan). getAnimalInside() returns the always-
                        -- initialised animalInside map and never touches def.
                        -- (See HBKeepAlive for the full rationale.)
                        local objs = s:getObjects()
                        if objs then
                            for k = 0, objs:size() - 1 do
                                local obj = objs:get(k)
                                if obj and instanceof(obj, "IsoHutch") then
                                    local key = tostring(obj)  -- IsoHutch may not have getId()
                                    if not seenHutches[key] then
                                        seenHutches[key] = true
                                        local inside = obj:getAnimalInside()
                                        if inside then
                                            -- getAnimal(pos) is def-free and avoids the unexposed
                                            -- HashMap.values() view that throws "non-table: []".
                                            -- (Matches HBKeepAlive/HBLifespan; slots are small.)
                                            for pos = 0, 63 do
                                                local animal = obj:getAnimal(pos)
                                                if animal then
                                                    local oid = animal:getOnlineID()
                                                    if oid and oid ~= 0 and not seen[oid] then
                                                        seen[oid] = true
                                                        rows[#rows + 1] = buildRow(animal, "hutch")
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
    end

    return rows
end

-- ─── Value formatting ────────────────────────────────────────────────────

local function formatCell(row, col)
    local v = row[col.key]
    if v == nil then return "-" end
    if type(v) == "boolean" then return v and "yes" or "no" end
    if type(v) == "number" then
        if col.key == "oid" then return string.format("%d", v) end
        if col.key == "hp" or col.key == "stress" then return string.format("%d", math.floor(v)) end
        return string.format("%.2f", v)
    end
    return tostring(v)
end

local function cellColor(row, col)
    -- Seen: green yes, amber no.
    if col.key == "seen" then
        if row.seen then return 0.55, 0.90, 0.55 end
        return 0.85, 0.70, 0.40
    end
    -- Missing RQHB id dimmed.
    if col.key == "id" and row.id == nil then return 0.45, 0.45, 0.55 end
    -- Cross-API disagreement: red when Hng:get differs from Hng:stat.
    if col.key == "hngA" or col.key == "hngB" then
        if type(row.hngA) == "number" and type(row.hngB) == "number" then
            if math.abs(row.hngA - row.hngB) > 0.01 then return 0.95, 0.45, 0.45 end
        end
    end
    if col.key == "thrA" or col.key == "thrB" then
        if type(row.thrA) == "number" and type(row.thrB) == "number" then
            if math.abs(row.thrA - row.thrB) > 0.01 then return 0.95, 0.45, 0.45 end
        end
    end
    return 0.88, 0.88, 0.92
end

-- Truncate `s` to fit `maxWidth` pixels at `font`, suffixed with "…" if cut.
-- Iterative tail trim — fast enough for per-cell per-frame use.
local function truncateToWidth(font, s, maxWidth)
    local tm = getTextManager()
    if tm:MeasureStringX(font, s) <= maxWidth then return s end
    local trimmed = s
    while #trimmed > 1 and tm:MeasureStringX(font, trimmed .. "…") > maxWidth do
        trimmed = trimmed:sub(1, -2)
    end
    return trimmed .. "…"
end

-- ─── Scrollable animal list ──────────────────────────────────────────────

local HBAnimalList = ISScrollingListBox:derive("HBAnimalList")

function HBAnimalList:doDrawItem(y, item, alt)
    local row = item.item
    -- Row background
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight - 1, 0.55, 0.20, 0.35, 0.55)
    elseif alt then
        self:drawRect(0, y, self:getWidth(), self.itemheight - 1, 1.0, 0.06, 0.06, 0.09)
    end

    local font = UIFont.Code
    local tm = getTextManager()
    local x = 4
    for _, c in ipairs(COLS) do
        local s = formatCell(row, c)
        local r, g, b = cellColor(row, c)
        local maxTextWidth = c.w - 8  -- leave a 4px gutter on each side
        if tm:MeasureStringX(font, s) > maxTextWidth then
            s = truncateToWidth(font, s, maxTextWidth)
        end
        if c.align == "right" then
            local sw = tm:MeasureStringX(font, s)
            self:drawText(s, x + c.w - sw - 6, y + 2, r, g, b, 1, font)
        else
            self:drawText(s, x, y + 2, r, g, b, 1, font)
        end
        x = x + c.w
    end
    return y + self.itemheight
end

function HBAnimalList:onMouseDown(x, y)
    ISScrollingListBox.onMouseDown(self, x, y)
    if self.parent and self.parent.onSelectionChanged then
        self.parent:onSelectionChanged(self.selected)
    end
end

-- Right-click a row → open vanilla's AnimalContextMenu for the underlying
-- animal. Same menu the player gets right-clicking the animal in the world
-- (Feed, Water, Pet, Milk, Shear, Slaughter, Add to Trailer, etc.).
-- Pattern from DBD_NearbyAnimals.lua:1138-1153.
function HBAnimalList:onRightMouseUp(x, y)
    -- Determine which row was right-clicked. Items render top-down at
    -- itemheight-row positions; vscroll offset shifts things.
    local rowIdx = math.floor((y - (self:getYScroll() or 0)) / self.itemheight) + 1
    if not self.items or rowIdx < 1 or rowIdx > #self.items then return false end

    local item = self.items[rowIdx]
    local row  = item and item.item
    if not row or not row.oid or row.oid == 0 then return false end

    local animal = getAnimal(row.oid)
    if not animal then return false end

    local player = getPlayer()
    if not player then return false end

    -- Update list selection to match the right-click target.
    self.selected = rowIdx
    if self.parent and self.parent.onSelectionChanged then
        self.parent:onSelectionChanged(rowIdx)
    end

    local ok, err = pcall(function()
        require "ISUI/Animal/ISAnimalContextMenu"
        local screenX = self:getAbsoluteX() + x
        local screenY = self:getAbsoluteY() + y
        local pn = player:getPlayerNum()
        local context = ISContextMenu.get(pn, screenX, screenY)
        if context and AnimalContextMenu and AnimalContextMenu.doMenu then
            -- Force cheat-mode for the duration of the menu build. Two reasons:
            --   1. Vanilla's distance check at ISAnimalContextMenu.lua:159 nil-
            --      indexes when animal:getCurrentSquare() is nil (containerised
            --      animal, edge-of-load animal, etc.). The `not cheat` guard
            --      short-circuits that whole branch.
            --   2. Cheat-mode surfaces debug-only options (set acceptance,
            --      fertilize, set age, genetic-disorder editor) that are
            --      exactly the diagnostics this admin panel wants.
            -- We restore the previous value after — but note that menu building
            -- is synchronous, so the option callbacks (clicked later) run with
            -- the original cheat flag.
            local prevCheat = AnimalContextMenu.cheat
            AnimalContextMenu.cheat = true
            AnimalContextMenu.doMenu(pn, context, animal, false)
            AnimalContextMenu.cheat = prevCheat
        end
    end)
    if not ok then
        print("[HB] right-click context menu error: " .. tostring(err))
    end
    return true
end

-- ─── Log list (append-only, auto-scroll to bottom) ───────────────────────

local HBLogList = ISScrollingListBox:derive("HBLogList")

function HBLogList:doDrawItem(y, item, alt)
    if alt then
        self:drawRect(0, y, self:getWidth(), self.itemheight - 1, 1.0, 0.02, 0.02, 0.04)
    end
    self:drawText(item.text or "", 6, y + 1, 0.75, 0.85, 0.75, 1, UIFont.Code)
    return y + self.itemheight
end

-- ─── Panel ───────────────────────────────────────────────────────────────

function HBDebugPanel:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index         = self
    o.title              = "HB Animal Debug"
    o.resizable          = true
    o.minimumWidth       = 680
    o.minimumHeight      = 460
    o.backgroundColor    = { r = 0.05, g = 0.05, b = 0.08, a = 0.97 }
    o.borderColor        = { r = 0.40, g = 0.40, b = 0.55, a = 1.00 }
    o.background         = true
    o._animals           = {}
    o._selectedRow       = nil
    return o
end

function HBDebugPanel:createChildren()
    -- Guard: ISCollapsableWindow:initialise() calls createChildren internally
    -- in some B42 builds, and open() calls it explicitly. Without this guard
    -- the children are built twice, producing visibly duplicated buttons and
    -- log panes.
    if self._childrenBuilt then return end
    self._childrenBuilt = true

    ISCollapsableWindow.createChildren(self)

    -- ─── Layout geometry computed BEFORE any children are constructed ────
    -- ISScrollingListBox caches its content bounds at construction time;
    -- setWidth / setHeight after the fact only updates the outer frame and
    -- leaves item rendering at the original width. So we size up-front.
    local thTop = self:titleBarHeight()
    local rsBot = self:resizeWidgetHeight()
    local innerW = self.width - PAD * 2

    local statusTop    = thTop + PAD
    local statusBlockH = 16 * 3                        -- three status lines
    local headerY      = statusTop + statusBlockH
    local logY         = self.height - rsBot - LOG_H - PAD
    local btnY         = logY - BTN_H - PAD
    local listY        = headerY + HEADER_H
    local listH        = btnY - listY - PAD

    self.headerY = headerY
    self.statusTop = statusTop  -- remembered for prerender drawText

    -- ─── Status strip rendered directly via prerender drawText ───────────
    -- Avoids ISLabel's width/clip quirks; gives full control over truncation.
    -- Initial values; updated by onRefresh / onSelectionChanged / clock tick.
    self._statusText    = "ready — press Refresh"
    self._selectionText = "selection: (none)"
    self._clockText     = "clock: (pending)"

    -- ─── Scrollable list with FINAL dimensions ───────────────────────────
    self.list = HBAnimalList:new(PAD, listY, innerW, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight       = ROW_H
    self.list.drawBorder       = true
    self.list.backgroundColor  = { r = 0.02, g = 0.02, b = 0.03, a = 1.0 }
    self.list.selected         = 0
    self:addChild(self.list)

    -- ─── Log pane with FINAL dimensions ──────────────────────────────────
    self.logList = HBLogList:new(PAD, logY, innerW, LOG_H)
    self.logList:initialise()
    self.logList:instantiate()
    self.logList.itemheight      = LOG_ROW_H
    self.logList.drawBorder      = true
    self.logList.backgroundColor = { r = 0.015, g = 0.015, b = 0.02, a = 1.0 }
    self:addChild(self.logList)

    -- ─── Button row ──────────────────────────────────────────────────────
    self.btnRefresh   = self:makeButton("Refresh",   80, HBDebugPanel.onRefresh)
    self.btnProbe     = self:makeButton("Probe",     70, HBDebugPanel.onProbe)
    self.btnTeleport  = self:makeButton("Teleport",  80, HBDebugPanel.onTeleport)
    self.btnRefill    = self:makeButton("Refill",    75, HBDebugPanel.onRefill)
    self.btnStarve    = self:makeButton("Starve",    75, HBDebugPanel.onStarve)
    self.btnTimePush  = self:makeButton("Sleep 20h", 95, HBDebugPanel.onTimePush)
    self.btnCopyLog   = self:makeButton("Copy Log",  85, HBDebugPanel.onCopyLog)
    self.btnClearLog  = self:makeButton("Clear Log", 85, HBDebugPanel.onClearLog)

    local bx = PAD
    for _, b in ipairs({ self.btnRefresh, self.btnProbe, self.btnTeleport, self.btnRefill, self.btnStarve, self.btnTimePush, self.btnCopyLog, self.btnClearLog }) do
        b:setX(bx)
        b:setY(btnY)
        bx = bx + b.width + 6
    end

    self:updateClockDisplay()

    self:logLine("[panel] initialized")
    self:logLine(string.format("[init] panel=%dx%d  list=%dx%d  log=%dx%d",
        self.width, self.height, self.list.width, self.list.height,
        self.logList.width, self.logList.height))
    self:logLine("[panel] press Refresh for test data")
end

function HBDebugPanel:makeButton(label, w, handler)
    local b = ISButton:new(0, 0, w, BTN_H, label, self, handler)
    b:initialise()
    b.backgroundColor       = { r = 0.15, g = 0.18, b = 0.22, a = 1.0 }
    b.backgroundColorMouseOver = { r = 0.25, g = 0.30, b = 0.38, a = 1.0 }
    b.borderColor           = { r = 0.40, g = 0.45, b = 0.55, a = 1.0 }
    self:addChild(b)
    return b
end

-- Re-layout called on window resize. Children were constructed with correct
-- dimensions; resize updates the outer frame and we best-effort setWidth
-- the scrollboxes. If the scrollbox internals don't fully honor setWidth on
-- resize, the panel can still be reopened at the desired size.
function HBDebugPanel:layoutChildren()
    if not self._childrenBuilt then return end

    local thTop = self:titleBarHeight()
    local rsBot = self:resizeWidgetHeight()
    local innerW = self.width - PAD * 2

    local statusTop    = thTop + PAD
    local statusBlockH = 16 * 3
    local headerY      = statusTop + statusBlockH
    local logY         = self.height - rsBot - LOG_H - PAD
    local btnY         = logY - BTN_H - PAD
    local listY        = headerY + HEADER_H
    local listH        = btnY - listY - PAD

    self.headerY = headerY
    self.statusTop = statusTop

    self.list:setX(PAD);    self.list:setY(listY)
    self.list:setWidth(innerW); self.list:setHeight(listH)

    self.logList:setX(PAD); self.logList:setY(logY)
    self.logList:setWidth(innerW); self.logList:setHeight(LOG_H)

    local bx = PAD
    for _, b in ipairs({ self.btnRefresh, self.btnProbe, self.btnTeleport, self.btnRefill, self.btnStarve, self.btnTimePush, self.btnCopyLog, self.btnClearLog }) do
        b:setX(bx); b:setY(btnY)
        bx = bx + b.width + 6
    end
end

-- Live game-clock readout. Called from prerender so it ticks every frame.
function HBDebugPanel:updateClockDisplay()
    local gt = getGameTime()
    if not gt then return end
    local tod = gt:getTimeOfDay() or 0
    local hr  = math.floor(tod)
    local mn  = math.floor((tod - hr) * 60)
    self._clockText = string.format(
        "clock:  D=%d  M=%d  Y=%d   %02d:%02d   (tod=%.3f)",
        gt:getDay() or -1, gt:getMonth() or -1, gt:getYear() or -1, hr, mn, tod)
end

function HBDebugPanel:onResize()
    ISCollapsableWindow.onResize(self)
    self:layoutChildren()
end

-- Draw column headers each frame (row of bold-ish green-on-dark tabs).
function HBDebugPanel:prerender()
    self:updateClockDisplay()
    self:refreshSelectedHighlight()
    ISCollapsableWindow.prerender(self)

    local fontStatus = UIFont.Small
    local tm = getTextManager()
    local innerW = self.width - PAD * 2

    -- Status strip: three lines drawn directly, each truncated to fit innerW.
    local function drawStatusLine(text, y, r, g, b)
        local s = text or ""
        if tm:MeasureStringX(fontStatus, s) > innerW then
            s = truncateToWidth(fontStatus, s, innerW)
        end
        self:drawText(s, PAD, y, r, g, b, 1, fontStatus)
    end
    local sTop = self.statusTop or (self:titleBarHeight() + PAD)
    drawStatusLine(self._statusText,    sTop,        0.70, 0.85, 1.00)
    drawStatusLine(self._selectionText, sTop + 16,   0.65, 0.65, 0.72)
    drawStatusLine(self._clockText,     sTop + 32,   0.85, 0.75, 0.55)

    -- Header background
    self:drawRect(PAD, self.headerY, innerW, HEADER_H, 1.0, 0.10, 0.12, 0.17)
    self:drawRectBorder(PAD, self.headerY, innerW, HEADER_H, 1.0, 0.30, 0.32, 0.40)

    local font = UIFont.Code
    local x = PAD + 4
    for _, c in ipairs(COLS) do
        local label = c.label
        if c.align == "right" then
            local sw = tm:MeasureStringX(font, label)
            self:drawText(label, x + c.w - sw - 6, self.headerY + 4, 0.55, 0.85, 0.55, 1, font)
        else
            self:drawText(label, x, self.headerY + 4, 0.55, 0.85, 0.55, 1, font)
        end
        x = x + c.w
    end

    -- Thin separator line under header
    self:drawRect(PAD, self.headerY + HEADER_H - 1, innerW, 1, 1.0, 0.35, 0.35, 0.45)
end

-- Per-frame outline-highlight refresh on the currently-selected animal.
-- Engine clears setOutlineHighlight each frame, so we re-set continually
-- while a row is selected (DBD pattern, ISAnimalContextMenu does the same).
function HBDebugPanel:refreshSelectedHighlight()
    if not self._highlightedOid then return end
    local animal = getAnimal(self._highlightedOid)
    if not animal then return end
    local player = getPlayer()
    if not player then return end
    local pn = player:getPlayerNum()
    pcall(function() animal:setOutlineHighlight(pn, true) end)
    pcall(function() animal:setOutlineHighlightCol(pn, 0.95, 0.65, 0.45, 1) end)
end

function HBDebugPanel:clearSelectedHighlight()
    if not self._highlightedOid then return end
    local prev = getAnimal(self._highlightedOid)
    local player = getPlayer()
    if prev and player then
        pcall(function() prev:setOutlineHighlight(player:getPlayerNum(), false) end)
    end
    self._highlightedOid = nil
end

-- ─── Log pane helpers ────────────────────────────────────────────────────

-- Trim from the front so the latest entries always fit visibly without
-- needing a scrollbar. ISScrollingListBox's setYScroll math was rendering
-- items above the box bounds when content overflowed; trimming sidesteps it.
function HBDebugPanel:logLine(text)
    if not self.logList then return end
    self.logList:addItem(text, { text = text })
    local maxRows = math.max(1, math.floor(self.logList.height / self.logList.itemheight))
    while #self.logList.items > maxRows do
        table.remove(self.logList.items, 1)
    end
end

function HBDebugPanel:onClearLog()
    self.logList.items = {}
    self.logList.selected = 0
    self:logLine("[log] cleared")
end

function HBDebugPanel:onCopyLog()
    if not self.logList or not self.logList.items or #self.logList.items == 0 then
        self:logLine("[clipboard] log is empty")
        return
    end
    local lines = {}
    for _, item in ipairs(self.logList.items) do
        local txt = item and item.item and item.item.text
        if type(txt) == "string" then lines[#lines + 1] = txt end
    end
    if #lines == 0 then return end
    local text = table.concat(lines, "\n")
    local ok, err = pcall(function() Clipboard.setClipboard(text) end)
    if ok then
        self:logLine(string.format("[clipboard] copied %d log lines", #lines))
        pcall(function() getSoundManager():playUISound("UISelectListItem") end)
    else
        self:logLine("[clipboard] error: " .. tostring(err))
    end
end

-- ─── Selection ───────────────────────────────────────────────────────────

function HBDebugPanel:onSelectionChanged(rowIdx)
    -- Clear outline on previously-selected animal first.
    self:clearSelectedHighlight()

    self._selectedRow = rowIdx
    local items = self.list.items or {}
    if rowIdx and items[rowIdx] then
        local row = items[rowIdx].item
        self._selectionText = string.format(
            "selection: OID=%s  %s (%s)",
            tostring(row.oid), tostring(row.name), tostring(row.species))
        if row.oid and row.oid ~= 0 then
            self._highlightedOid = row.oid
        end
    else
        self._selectionText = "selection: (none)"
    end
end

function HBDebugPanel:getSelectedRow()
    local idx = self.list.selected
    if not idx or idx == 0 then return nil end
    local items = self.list.items or {}
    if items[idx] then return items[idx].item end
    return nil
end

-- ─── Button handlers ─────────────────────────────────────────────────────

function HBDebugPanel:onRefresh()
    self._animals = scanCellAnimals()
    self.list.items = {}
    self.list.selected = 0
    self.list:setYScroll(0)
    for _, row in ipairs(self._animals) do
        self.list:addItem(row.name or "?", row)
    end
    local loose, trailer, hutch = 0, 0, 0
    for _, r in ipairs(self._animals) do
        if r.loc == "loose" then loose = loose + 1
        elseif r.loc == "hutch" then hutch = hutch + 1
        else trailer = trailer + 1 end
    end
    local enabled = SandboxVars and SandboxVars.RFTDHusbandry and SandboxVars.RFTDHusbandry.Enable
    self._statusText = string.format(
        "Enable=%s   animals=%d (loose=%d, trailer=%d, hutch=%d)   refresh=%s",
        tostring(enabled), #self._animals, loose, trailer, hutch, os.date("%H:%M:%S"))
    self:onSelectionChanged(nil)
    self:logLine(string.format("[refresh] scanned cell: %d animals (%d loose, %d trailer, %d hutch)",
        #self._animals, loose, trailer, hutch))
end

-- Batched stat write applied to every visible animal. Refill = value 0
-- (full / sated). Starve = value 0.9 (parched / starving but not lethal).
-- Health is left alone here; for safety we don't accidentally HP-zero.
function HBDebugPanel:_applyToAll(value, label)
    if not self._animals or #self._animals == 0 then
        self:logLine("[" .. label .. "] no animals scanned (press Refresh first)")
        return
    end
    local player = getPlayer()
    if not player then return end
    local oids = {}
    for _, row in ipairs(self._animals) do
        if row.oid and row.oid ~= 0 then
            oids[#oids + 1] = tostring(row.oid)
        end
    end
    if #oids == 0 then
        self:logLine("[" .. label .. "] no valid OIDs in current scan")
        return
    end
    self:logLine(string.format("[%s] target=%.2f, sending %d OIDs", label, value, #oids))
    sendClientCommand(player, "RQ", HBCmd.DEBUG_REFILL, {
        oids = table.concat(oids, ","),
        value = tostring(value),
    })
end

function HBDebugPanel:onRefill()
    self:_applyToAll(0.0, "refill")
end

function HBDebugPanel:onStarve()
    self:_applyToAll(0.9, "starve")
end

function HBDebugPanel:onProbe()
    local row = self:getSelectedRow()
    if not row then
        self:logLine("[probe] no row selected")
        return
    end
    local player = getPlayer()
    if not player then return end
    self:logLine(string.format("[probe] requesting server probe for OID %s", tostring(row.oid)))
    sendClientCommand(player, "RQ", HBCmd.DEBUG_PROBE, { id = tostring(row.oid) })
end

-- Teleport the player to the selected animal. MP-aware: player position
-- writes are client-authoritative in PZ, so a direct setX/Y/Z works in
-- both SP and MP without a server roundtrip.
--
-- Two-step coordinate resolution per location class:
--   1. Try the location-appropriate square — gives clean centered coords
--      and a fixed reference even for objects that move between frames.
--   2. Fall back to raw obj:getX/Y/Z — handles transient nil-square states
--      (far-edge animals, just-spawned, vehicle in motion).
--
-- Dispatch on row.loc rather than calling getCurrentSquare() blindly, since
-- containerised animals always return nil from it (same case the cheat-mode
-- override at onRightMouseUp guards against):
--   loose      → animal sq, then animal coords
--   tr:<vid>   → vehicle sq, then vehicle coords
--   hutch      → hutch  sq, then hutch  coords
function HBDebugPanel:onTeleport()
    local row = self:getSelectedRow()
    if not row then
        self:logLine("[teleport] no row selected")
        return
    end
    if not row.oid or row.oid == 0 then
        self:logLine("[teleport] selected row has no OID")
        return
    end
    local animal = getAnimal(row.oid)
    if not animal then
        self:logLine(string.format("[teleport] OID %s no longer resolvable", tostring(row.oid)))
        return
    end
    local player = getPlayer()
    if not player then return end

    local tx, ty, tz
    local function fromSquare(sq)
        if not sq then return false end
        tx, ty, tz = sq:getX() + 0.5, sq:getY() + 0.5, sq:getZ()
        return true
    end
    local function fromObject(obj)
        if not obj then return false end
        local ax, ay, az
        pcall(function() ax, ay, az = obj:getX(), obj:getY(), obj:getZ() end)
        if not ax or not ay then return false end
        tx, ty, tz = ax, ay, az or 0
        return true
    end

    local loc = row.loc or "loose"
    if loc == "loose" then
        local sq; pcall(function() sq = animal:getCurrentSquare() end)
        if not fromSquare(sq) then fromObject(animal) end
    elseif string.sub(loc, 1, 3) == "tr:" then
        local v;  pcall(function() v = animal:getVehicle() end)
        local sq; pcall(function() if v then sq = v:getCurrentSquare() end end)
        if not fromSquare(sq) then fromObject(v) end
    elseif loc == "hutch" then
        local h;  pcall(function() h = animal:getHutch() end)
        local sq; pcall(function() if h then sq = h:getSquare() end end)
        if not fromSquare(sq) then fromObject(h) end
    end

    if not tx then
        self:logLine(string.format("[teleport] no coords resolvable for %s (loc=%s)",
            tostring(row.name), tostring(row.loc)))
        return
    end

    -- setX/Y/Z is the canonical position write. setLx/Ly/Lz update the
    -- "last position" used for movement interpolation so the engine doesn't
    -- visually snap us back from the old spot — but those methods aren't
    -- present on IsoPlayer in every B42 build (verified absent here, was
    -- crashing with "tried to call nil"), so existence-guard each one.
    local fx, fy, fz = player:getX(), player:getY(), player:getZ()
    local ok, err = pcall(function()
        player:setX(tx); player:setY(ty); player:setZ(tz)
        if player.setLx then player:setLx(tx) end
        if player.setLy then player:setLy(ty) end
        if player.setLz then player:setLz(tz) end
    end)
    if not ok then
        self:logLine("[teleport] ERROR: " .. tostring(err))
        return
    end
    self:logLine(string.format("[teleport] %s (OID %s) :: (%.1f,%.1f,%d) -> (%.1f,%.1f,%d)",
        tostring(row.name), tostring(row.oid), fx, fy, fz, tx, ty, tz))
end

-- Hook the player into vanilla's sleep loop to advance time by 20 hours.
-- Mirrors the call sequence in ISWorldObjectContextMenu.onSleepWalkToComplete
-- (lines 1103-1105) and ISSleepDialog.lua (lines 73-75).
--
-- Why max FATIGUE first: vanilla's sleep duration is fatigue × 10..13 hours
-- (ISWorldObjectContextMenu.lua:1074), and the engine auto-wakes when fatigue
-- normalises. setForceWakeUpTime overrides the *target*, but if fatigue clears
-- before then the engine still wakes early. Maxing fatigue gives the sleep
-- loop enough fuel to run the full requested duration.
function HBDebugPanel:onTimePush()
    local player = getPlayer()
    if not player then return end

    -- Vanilla MP sleep gates world-clock acceleration on all-players-asleep.
    -- An admin alone-sleeping just hangs at the black-screen until everyone
    -- else hits a bedroll. Refuse rather than trap the admin.
    if isClient() then
        local n = 0
        pcall(function()
            local online = getOnlinePlayers()
            n = online and online:size() or 0
        end)
        if n > 1 then
            self:logLine(string.format(
                "[sleep] this can't be used while other players are online (%d other%s connected)",
                n - 1, n - 1 == 1 and "" or "s"))
            return
        end
    end

    local gt = getGameTime()
    local sleepFor = 20.0
    local target = (gt:getTimeOfDay() + sleepFor) % 24.0

    self:logLine(string.format("[sleep] tod=%.2f -> wake target=%.2f (%.0fh)",
        gt:getTimeOfDay(), target, sleepFor))

    local ok, err = pcall(function()
        player:getStats():set(CharacterStat.FATIGUE, 1.0)
        player:setForceWakeUpTime(target)
        player:setAsleepTime(0.0)
        player:setAsleep(true)
        if getSleepingEvent then
            getSleepingEvent():setPlayerFallAsleep(player, sleepFor)
        end
    end)
    if not ok then
        self:logLine("[sleep] ERROR: " .. tostring(err))
    end
end

-- ─── Open / close ────────────────────────────────────────────────────────

function HBDebugPanel:close()
    self:clearSelectedHighlight()
    self:setVisible(false)
    self:removeFromUIManager()
    HBDebugPanel._instance = nil
end

function HBDebugPanel.open()
    -- When Dragonfly admin panel is installed, the canonical surface is its
    -- Animals tab. Defer to it so admins don't have two competing windows
    -- showing the same data with different idioms.
    if DFPanel and DFRegistry and DFRegistry.tabs and DFRegistry.tabs["animals"] then
        DFPanel.open()
        if DFPanel.instance then DFPanel.instance:showTab("animals") end
        return
    end
    if HBDebugPanel._instance and HBDebugPanel._instance:isVisible() then
        HBDebugPanel._instance:onRefresh()
        return
    end
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local minW = PAD * 2 + totalColW() + 20   -- +20 for scrollbar
    local w = math.max(minW, 1000)
    local h = 600
    local ui = HBDebugPanel:new((sw - w) / 2, (sh - h) / 2, w, h)
    ui.minimumWidth = minW
    ui:initialise()
    ui:createChildren()
    ui:addToUIManager()
    ui:setVisible(true)
    HBDebugPanel._instance = ui
end

-- Exposed for HBAnimalsTab so it can reuse the same two-pass scan
-- (loose animals via cell object list + trailer/hutch animals via grid
-- walk). Wraps the local function rather than rewriting the scan twice.
function HBDebugPanel.scanCell()
    return scanCellAnimals()
end

-- ─── Server→client probe result echo ─────────────────────────────────────

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RQ" then return end
    if command ~= HBCmd.DEBUG_PROBE_RESULT then return end
    local panel = HBDebugPanel._instance
    if not panel or not panel:isVisible() then return end
    panel:logLine(tostring(args and args.line or "(no line)"))
end)

-- ─── Startup probe: player position API surface ──────────────────────────
-- Logs once per game start which IsoPlayer position-write methods this build
-- exposes. The L-suffix interpolation setters (setLx/setLy/setLz) are absent
-- on IsoPlayer in B42 17 despite being a documented vanilla pattern; calling
-- them throws "tried to call nil". Surface the absence at load time so the
-- next time the binding shifts (either way) it's visible in DebugLog.txt
-- without waiting for a teleport click to crash.
--
-- Per CLAUDE.md §10.3, every dependency on an unverified vanilla API gets a
-- probe entry. This is the player-side equivalent of HBAPIProbe.
Events.OnGameStart.Add(function()
    local player = getPlayer()
    if not player then return end
    local function has(name) return type(player[name]) == "function" end
    local methods = {
        "setX", "setY", "setZ",
        "setLx", "setLy", "setLz",
    }
    local present, absent = {}, {}
    for _, m in ipairs(methods) do
        table.insert(has(m) and present or absent, m)
    end
    print(string.format("[HB probe] IsoPlayer position API: present={%s}  absent={%s}",
        table.concat(present, ","), table.concat(absent, ",")))
end)

-- ─── Admin panel integration ─────────────────────────────────────────────

local _origAdminCreate = ISAdminPanelUI.create
function ISAdminPanelUI:create()
    local FONT_HGT_SMALL  = getTextManager():getFontHeight(UIFont.Small)
    local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
    local BORDER = 10
    local btnH = FONT_HGT_SMALL + 6

    local btn = ISButton:new(BORDER + 1, FONT_HGT_MEDIUM + BORDER * 2 + 1,
                             200, btnH, "** HB Debug **", self, HBDebugPanel.open)
    btn.internal = ""
    btn:initialise()
    btn:instantiate()
    btn.borderColor = self.buttonBorderColor
    self:addChild(btn)

    _origAdminCreate(self)
end
