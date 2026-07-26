-- HBHutchesTab — registers a Hutches tab on Dragonfly's admin panel.
--
-- Lists hutches (chicken coops / rabbit hutches) loaded near the admin and
-- lets them manage bedding: "spawn" hay into a hutch to keep it clean. Hay
-- continuously eats hutch/nest-box dirt but decays over time, so it has to be
-- replenished — the cleaning + decay run server-side in HBBedding, driven from
-- HBKeepAlive's hutch scan. This tab is just the reader + the spawn button.
--
-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry is absent.
-- Mirrors HBAnimalsTab's structure (DFColumns layout, "RQ" command module,
-- DFFeedback for inline feedback). Values in the list are read LIVE from each
-- hutch every frame, so a bedding top-up / cleaning pass shows up without a
-- manual rescan.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

local FONT = UIFont.Code
local SCAN_RANGE = 20  -- ±squares around the player (matches HBKeepAlive)

local HutchesTab = {
    rows        = {},
    listBox     = nil,
    statsLabel  = nil,
    selectedKey = nil,  -- "x,y,z" of the selected hutch row
}

-- ─────────────────────────────────────────────────────────────────────────
-- Live reads (row.hutch is a live IsoHutch ref captured at scan time)
-- ─────────────────────────────────────────────────────────────────────────

-- Read via HBBedding.getStatus, which prefers the synced ModData mirror over
-- the native hutchDirt field (the latter isn't replicated to dedicated-server
-- clients). Falls back to 0 if HBBedding isn't present.
local function status(hutch)
    if HBBedding and HBBedding.getStatus then return HBBedding.getStatus(hutch) end
    return { dirt = 0, nbDirt = 0, bedding = 0, max = 100 }
end
local function liveDirt(hutch)     return status(hutch).dirt end
local function liveNestDirt(hutch) return status(hutch).nbDirt end
local function liveBedding(hutch)  return status(hutch).bedding end

-- ─────────────────────────────────────────────────────────────────────────
-- Column model
-- ─────────────────────────────────────────────────────────────────────────

local COLS = {
    { key = "coords", label = "Coords", w = 110, align = "center",
      format = function(r) return string.format("%d, %d", r.x or 0, r.y or 0) end },
    { key = "z",      label = "Z",      w = 28,  align = "center",
      format = function(r) return tostring(r.z or 0) end },
    { key = "dist",   label = "Dist",   w = 50,  align = "center",
      format = function(r) return string.format("%d", r.dist or 0) end },
    { key = "anim",   label = "Animals", w = 60, align = "center",
      format = function(r) return tostring(r.animals or 0) end },
    { key = "dirt",   label = "Dirt",   w = 64,  align = "center",
      format = function(r) return string.format("%.0f", liveDirt(r.hutch)) end,
      color  = function(r)
          -- Animals only heal below 20 dirt; flag at/above that threshold.
          return liveDirt(r.hutch) >= 20 and { 0.95, 0.40, 0.40 } or { 0.60, 0.95, 0.60 }
      end },
    { key = "nest",   label = "Nest",   w = 64,  align = "center",
      format = function(r) return string.format("%.0f", liveNestDirt(r.hutch)) end,
      color  = function(r)
          return liveNestDirt(r.hutch) >= 20 and { 0.95, 0.40, 0.40 } or { 0.60, 0.95, 0.60 }
      end },
    { key = "bed",    label = "Bedding", w = 90, align = "center",
      format = function(r)
          local max = (HBBedding and HBBedding.MAX) or 100
          return string.format("%d%%", math.floor((liveBedding(r.hutch) / max) * 100 + 0.5))
      end,
      color  = function(r)
          return liveBedding(r.hutch) > 0 and { 0.70, 0.90, 1.00 } or { 0.6, 0.6, 0.6 }
      end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- List rendering
-- ─────────────────────────────────────────────────────────────────────────

local HutchList = ISScrollingListBox:derive("HBHutchList")

function HutchList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    if HutchesTab.selectedKey and row.key == HutchesTab.selectedKey then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)

    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

function HutchList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if item and item.item then
        HutchesTab.selectedKey = item.item.key
        self.selected = idx
    end
end

function HutchList:render()
    self:setStencilRect(0, 0, self.width, self.height)
    ISScrollingListBox.render(self)
    self:clearStencilRect()
end

local function attachHeader(panel, listX, headerY)
    panel.drawColumnsHeader = function(self_)
        DFColumns.drawHeader(self_, COLS, listX, headerY, FONT)
    end
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        self_:drawColumnsHeader()
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Scan: walk grid squares around the player and collect loaded hutches.
-- Mirrors HBDebugPanel.scanCell's hutch pass — def-free (getAnimal(pos), never
-- getMaxAnimals) and only loaded-square hutches (never the stale zone list).
-- ─────────────────────────────────────────────────────────────────────────

local function scanHutches()
    local rows = {}
    local cell = getCell()
    local player = getPlayer()
    if not cell or not player then return rows end

    local sq = player:getCurrentSquare()
    if not sq then return rows end
    local px, py, pz = sq:getX(), sq:getY(), sq:getZ()
    local seen = {}

    for dx = -SCAN_RANGE, SCAN_RANGE do
        for dy = -SCAN_RANGE, SCAN_RANGE do
            pcall(function()
                local s = cell:getGridSquare(px + dx, py + dy, pz)
                if not s then return end
                local objs = s:getObjects()
                if not objs then return end
                for k = 0, objs:size() - 1 do
                    local obj = objs:get(k)
                    if obj and instanceof(obj, "IsoHutch") then
                        -- Skip slave halves of multi-tile coops; they share the
                        -- master's square (→ duplicate rows) and hold no real
                        -- dirt/animals. isSlave = linkedX>0 && linkedY>0.
                        local slave = false
                        pcall(function() slave = obj:isSlave() end)
                        local key = tostring(obj)
                        if not slave and not seen[key] then
                            seen[key] = true
                            local hx, hy, hz = s:getX(), s:getY(), s:getZ()
                            -- Count occupants (def-free slot walk, slots small).
                            local animals = 0
                            pcall(function()
                                if obj:getAnimalInside() then
                                    for pos = 0, 63 do
                                        if obj:getAnimal(pos) then animals = animals + 1 end
                                    end
                                end
                            end)
                            rows[#rows + 1] = {
                                key     = string.format("%d,%d,%d", hx, hy, hz),
                                hutch   = obj,
                                x = hx, y = hy, z = hz,
                                animals = animals,
                                dist    = math.max(math.abs(dx), math.abs(dy)),
                            }
                        end
                    end
                end
            end)
        end
    end

    table.sort(rows, function(a, b) return (a.dist or 0) < (b.dist or 0) end)
    return rows
end

-- ─────────────────────────────────────────────────────────────────────────
-- Data + actions
-- ─────────────────────────────────────────────────────────────────────────

local function refresh()
    if not HutchesTab.listBox then return end
    HutchesTab.listBox:clear()
    local rows = scanHutches()
    HutchesTab.rows = rows
    for _, row in ipairs(rows) do
        HutchesTab.listBox:addItem("", row)
    end
    if HutchesTab.statsLabel then
        HutchesTab.statsLabel:setName(string.format("Loaded hutches near you: %d", #rows))
    end
end

local function selectedRow()
    if not HutchesTab.selectedKey then return nil end
    for _, r in ipairs(HutchesTab.rows) do
        if r.key == HutchesTab.selectedKey then return r end
    end
    return nil
end

-- Send the server an "add hay" for one hutch (admin spawn — no item cost).
-- The server derives the per-add amount from the sandbox option.
local function spawnHay(row)
    if not row then return end
    sendClientCommand(getPlayer(), "RQ", HBCmd.ADD_BEDDING,
        { x = row.x, y = row.y, z = row.z })
end

local function addHaySelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No hutch selected.") end
        return
    end
    spawnHay(row)
    if DFFeedback then DFFeedback.good(string.format("Hay added to hutch %d,%d.", row.x, row.y)) end
end

local function addHayAll()
    local n = 0
    for _, row in ipairs(HutchesTab.rows) do
        spawnHay(row); n = n + 1
    end
    if DFFeedback then
        if n > 0 then DFFeedback.good(string.format("Hay added to %d hutch(es).", n))
        else DFFeedback.bad("No hutches in range.") end
    end
end

local function teleportToSelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No hutch selected.") end
        return
    end
    local p = getPlayer()
    pcall(function() p:setX(row.x + 0.5); p:setY(row.y + 0.5); p:setZ(row.z or 0) end)
    if DFFeedback then DFFeedback.good(string.format("Teleported to hutch %d,%d.", row.x, row.y)) end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Tab build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    HutchesTab.selectedKey = nil

    local PAD      = 8
    local BTN_H    = 24
    local HEADER_H = 20

    local cursorY = PAD

    local function mkBtn(label, bx, bw, handler)
        local b = ISButton:new(bx, cursorY, bw, BTN_H, label, panel, handler)
        b.borderColor.a = 0.4
        b:initialise(); b:instantiate()
        panel:addChild(b)
        return b
    end

    mkBtn("Refresh",      PAD,        90,  refresh)
    mkBtn("Teleport to",  PAD + 100,  110, teleportToSelected)
    mkBtn("Add Hay",      PAD + 220,  90,  addHaySelected)
    mkBtn("Add Hay: all", PAD + 320,  110, addHayAll)

    cursorY = cursorY + BTN_H + PAD

    local headerY = cursorY
    attachHeader(panel, PAD, headerY)
    cursorY = cursorY + HEADER_H

    local listH = h - cursorY - (PAD * 2 + 22)
    local list = HutchList:new(PAD, cursorY, w - PAD * 2, listH)
    list.itemheight = 28
    list.drawBorder = true
    list:initialise(); list:instantiate()
    panel:addChild(list)
    HutchesTab.listBox = list
    cursorY = cursorY + listH + PAD

    local stats = ISLabel:new(PAD, cursorY, 16, "Loaded hutches near you: -",
        0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    HutchesTab.statsLabel = stats

    refresh()
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id    = "hutches",
        label = "Hutches",
        order = 7,  -- just after the Animals tab (order 6)
        build = build,
    }
    print("[Husbandry] HBHutchesTab registered into Dragonfly")
end)
