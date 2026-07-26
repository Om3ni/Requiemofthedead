-- HBAnimalsTab - registers an Animals tab on Dragonfly's admin panel.
--
-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry isn't
-- loaded. Husbandry's standalone HBDebugPanel keeps working in that case.
--
-- Columnar layout via DFColumns - same idiom as HBDebugPanel itself uses
-- internally. Reuses HBDebugPanel.scanCell() for the two-pass animal scan
-- so this tab doesn't reimplement the loose-and-trailer-and-hutch walk.
-- Probe output goes to an inline log pane at the bottom of the tab, the
-- way the original HBDebugPanel renders it.

if isServer() then return end

-- DFRegistry check happens inside the OnGameStart callback below, not here.
-- Top-of-file early return would prevent the OnGameStart hook from ever
-- being registered if Husbandry loads before DragonflyAdmin.

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

local FONT = UIFont.Code

local AnimalsTab = {
    rows            = {},
    listBox         = nil,
    logBox          = nil,
    statsLabel      = nil,
    selectedOid     = nil,
    highlightTarget = nil,  -- IsoAnimal kept lit while its row is selected
}

-- World-outline pattern lifted from RPNecroTab. Outline state on the animal
-- decays when the panel stops re-asserting it each frame, so we (re)apply
-- in the list's prerender and clear when selection moves away.
local function clearHighlight()
    if AnimalsTab.highlightTarget then
        pcall(function() AnimalsTab.highlightTarget:setOutlineHighlight(false) end)
        AnimalsTab.highlightTarget = nil
    end
end

local function applyHighlight(oid)
    clearHighlight()
    if not oid or oid == 0 then return end
    local a
    pcall(function() a = getAnimal(tonumber(oid)) end)
    if a then AnimalsTab.highlightTarget = a end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Column model - matches HBDebugPanel's COLS shape so the eye flows the
-- same between the standalone panel and this tab. A few columns trimmed
-- to fit the Dragonfly panel width.
-- ─────────────────────────────────────────────────────────────────────────

local function divergeColor(row, _)
    -- Hunger/thirst values: amber when getHunger() and stats:get diverge,
    -- since that's the API divergence the dual columns exist to surface.
    return { 1, 1, 1 }
end

local COLS = {
    { key = "oid",     label = "OID",      w = 70, align = "center",
      format = function(r) return tostring(r.oid or 0) end },
    { key = "id",      label = "RQHB",     w = 80, align = "center",
      format = function(r) return tostring(r.id or "-") end },
    { key = "species", label = "Species",  w = 70, align = "center" },
    { key = "name",    label = "Name",     w = 130, align = "center" },
    { key = "sex",     label = "S",        w = 18, align = "center" },
    { key = "age",     label = "Age",      w = 50, align = "center" },
    { key = "hp",      label = "HP",       w = 44, align = "center",
      format = function(r) return string.format("%.0f", r.hp or 0) end,
      color  = function(r)
          if (r.hp or 0) < 30 then return { 0.95, 0.40, 0.40 } end
          if (r.hp or 0) < 60 then return { 0.95, 0.80, 0.40 } end
          return { 1, 1, 1 }
      end },
    { key = "hngA", label = "Hng:get",  w = 64, align = "center",
      format = function(r) return r.hngA and string.format("%.2f", r.hngA) or "-" end,
      color  = function(r)
          if r.hngA and r.hngB and math.abs(r.hngA - r.hngB) > 0.001 then
              return { 0.95, 0.55, 0.30 }
          end
          return { 0.85, 0.95, 0.85 }
      end },
    { key = "hngB", label = "Hng:stat", w = 64, align = "center",
      format = function(r) return r.hngB and string.format("%.2f", r.hngB) or "-" end,
      color  = function(r)
          if r.hngA and r.hngB and math.abs(r.hngA - r.hngB) > 0.001 then
              return { 0.95, 0.55, 0.30 }
          end
          return { 0.85, 0.95, 0.85 }
      end },
    { key = "thrA", label = "Thr:get",  w = 64, align = "center",
      format = function(r) return r.thrA and string.format("%.2f", r.thrA) or "-" end },
    { key = "thrB", label = "Thr:stat", w = 64, align = "center",
      format = function(r) return r.thrB and string.format("%.2f", r.thrB) or "-" end },
    { key = "stress", label = "Strs", w = 44, align = "center",
      format = function(r) return r.stress and string.format("%.2f", r.stress) or "-" end },
    { key = "loc",   label = "Loc",   w = 70, align = "center" },
}

-- ─────────────────────────────────────────────────────────────────────────
-- List rendering
-- ─────────────────────────────────────────────────────────────────────────

local AnimalsList = ISScrollingListBox:derive("HBAnimalsList")

function AnimalsList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    -- Compare via tonumber - getOnlineID() returns a Java short; if either
    -- side stays Java-boxed the equality fails silently and the highlight
    -- never appears even though the click handler ran.
    local sel = AnimalsTab.selectedOid
    if sel and row.oid and tonumber(sel) == tonumber(row.oid) then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)

    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

function AnimalsList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if item and item.item then
        -- Force to Lua number so the doDrawItem equality check below doesn't
        -- get tripped up by Java short vs Lua number.
        AnimalsTab.selectedOid = tonumber(item.item.oid) or 0
        self.selected = idx
        -- Light the animal up in the world so the admin can spot it without
        -- teleporting first. Same pattern as RPNecroTab's zombie outline.
        applyHighlight(AnimalsTab.selectedOid)
    end
end

-- Re-assert the outline every frame while a row is selected. The engine's
-- outline flag is consumed/cleared by the render loop, so a single setter
-- call would only persist for one frame.
function AnimalsList:prerender()
    ISScrollingListBox.prerender(self)
    if AnimalsTab.highlightTarget then
        pcall(function() AnimalsTab.highlightTarget:setOutlineHighlight(true) end)
    end
end

-- Wrap render with explicit stencil clipping. B42's ISScrollingListBox
-- doesn't always restrict drawing to its visible box, so rows can paint
-- past the list's bounds and overdraw sibling widgets above (action row,
-- column header). Stencil rect forces all drawing inside render to clip
-- to the list's local 0,0,width,height.
function AnimalsList:render()
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
-- Log pane (probe results land here)
-- ─────────────────────────────────────────────────────────────────────────

local LogList = ISScrollingListBox:derive("HBAnimalsLogList")

function LogList:doDrawItem(y, item, alt)
    if not item.item then return y + self.itemheight end
    if alt then self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08) end
    self:drawText(tostring(item.item), 4, y + 1, 0.85, 0.85, 0.85, 1, FONT)
    return y + self.itemheight
end

-- Match HBDebugPanel:logLine - cap visible rows at what fits in the box and
-- drop oldest. Avoids the overflow we saw where probe results spilled out
-- the top of the log pane; vanilla ISScrollingListBox's stencil clipping
-- alone wasn't keeping them inside.
local function logLine(text)
    local box = AnimalsTab.logBox
    if not box then return end
    box:addItem("", tostring(text or ""))
    local maxRows = math.max(1, math.floor(box.height / box.itemheight))
    while #box.items > maxRows do
        table.remove(box.items, 1)
    end
    box.selected = #box.items
end

-- ─────────────────────────────────────────────────────────────────────────
-- Data + actions
-- ─────────────────────────────────────────────────────────────────────────

local function refresh()
    if not AnimalsTab.listBox then return end
    AnimalsTab.listBox:clear()
    local rows = (HBDebugPanel and HBDebugPanel.scanCell) and HBDebugPanel.scanCell() or {}
    AnimalsTab.rows = rows
    for _, row in ipairs(rows) do
        AnimalsTab.listBox:addItem("", row)
    end
    if AnimalsTab.statsLabel then
        AnimalsTab.statsLabel:setName(string.format("Loaded animals: %d", #rows))
    end
end

local function selectedRow()
    if not AnimalsTab.selectedOid then return nil end
    for _, e in ipairs(AnimalsTab.rows) do
        if e.oid == AnimalsTab.selectedOid then return e end
    end
    return nil
end

local function teleportToSelected()
    local row = selectedRow()
    if not row then
        if DFFeedback then DFFeedback.bad("No animal selected.") end
        return
    end
    local animal = getAnimal(row.oid)
    if not animal then
        if DFFeedback then DFFeedback.bad("Animal no longer resolvable.") end
        return
    end
    local sq
    pcall(function() sq = animal:getCurrentSquare() end)
    local tx, ty, tz
    if sq then
        tx, ty, tz = sq:getX() + 0.5, sq:getY() + 0.5, sq:getZ()
    else
        pcall(function() tx, ty, tz = animal:getX(), animal:getY(), animal:getZ() end)
    end
    if not (tx and ty) then return end
    local p = getPlayer()
    pcall(function() p:setX(tx); p:setY(ty); p:setZ(tz or 0) end)
    logLine(string.format("[teleport] -> %s @ %d,%d", row.name or row.species or "?", tx, ty))
    if DFFeedback then
        DFFeedback.good(string.format("Teleported to %s.", row.name or row.species or "animal"))
    end
end

local function probeSelected()
    local row = selectedRow()
    if not row then
        logLine("[probe] no animal selected")
        return
    end
    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_PROBE, { id = tostring(row.oid) })
    logLine(string.format("[probe] requested OID %d", row.oid or 0))
end

local function refillAll()
    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.0, label = "refill" })
    logLine("[refill] sent (all animals -> 0.0)")
end

-- Copy every line in the log pane to the system clipboard so the admin can
-- paste the probe output into Discord / a bug report without retyping it.
-- Clipboard is exposed via LuaManager.setExposed at boot.
local function copyLog()
    if not AnimalsTab.logBox then return end
    local items = AnimalsTab.logBox.items
    if not items or #items == 0 then
        if DFFeedback then DFFeedback.bad("Log is empty.") end
        return
    end
    local buf = {}
    for _, it in ipairs(items) do
        buf[#buf + 1] = tostring(it.item or "")
    end
    local text = table.concat(buf, "\n")
    local ok = pcall(function() Clipboard.setClipboard(text) end)
    if ok then
        if DFFeedback then
            DFFeedback.good(string.format("Copied %d log line(s) to clipboard.", #buf))
        end
    else
        if DFFeedback then DFFeedback.bad("Clipboard call failed.") end
    end
end

local function starveAll()
    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.9, label = "starve" })
    logLine("[starve] sent (all animals -> 0.9)")
end

-- Probe results echo here (inline) AND get pushed to DFLog for the Console
-- tab's cross-admin view. Two surfaces, same data; admins reading either
-- get the same picture.
local function onServerCommand(module, command, args)
    if module ~= "RQ" then return end
    if command ~= HBCmd.DEBUG_PROBE_RESULT then return end
    if not args then return end
    local line = tostring(args.line or "(probe: no line)")
    logLine(line)
    if DFLog then
        DFLog.push{ source = "Mod:RFTDHusbandry", level = "info", text = line }
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- ─────────────────────────────────────────────────────────────────────────
-- Tab build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    AnimalsTab.selectedOid = nil
    clearHighlight()

    local PAD      = 8
    local BTN_H    = 24
    local HEADER_H = 20
    local LOG_H    = 130

    -- Row 1: action buttons
    local cursorY = PAD

    local function mkBtn(label, bx, bw, handler)
        local b = ISButton:new(bx, cursorY, bw, BTN_H, label, panel, handler)
        b.borderColor.a = 0.4
        b:initialise(); b:instantiate()
        panel:addChild(b)
        return b
    end

    mkBtn("Refresh",     PAD,        90,  refresh)
    mkBtn("Teleport to", PAD + 100,  110, teleportToSelected)
    mkBtn("Probe",       PAD + 220,  80,  probeSelected)
    mkBtn("Refill all",  PAD + 310,  100, refillAll)
    mkBtn("Starve all",  PAD + 420,  100, starveAll)
    mkBtn("Clear log",   PAD + 540,  100, function() if AnimalsTab.logBox then AnimalsTab.logBox:clear() end end)
    mkBtn("Copy log",    PAD + 650,  100, copyLog)

    cursorY = cursorY + BTN_H + PAD

    -- Row 2: column header (drawn via panel.prerender)
    local headerY = cursorY
    attachHeader(panel, PAD, headerY)
    cursorY = cursorY + HEADER_H

    -- Row 3: animal list (above the log pane)
    local listH = h - cursorY - (LOG_H + PAD * 2 + 22)
    local list = AnimalsList:new(PAD, cursorY, w - PAD * 2, listH)
    list.itemheight = 32   -- bumped from 18 for breathing room between rows
    list.drawBorder = true
    list:initialise(); list:instantiate()
    panel:addChild(list)
    AnimalsTab.listBox = list
    cursorY = cursorY + listH + PAD

    -- Row 4: log pane (probe results / action audits)
    local log = LogList:new(PAD, cursorY, w - PAD * 2, LOG_H)
    log.itemheight = 14
    log.drawBorder = true
    log:initialise(); log:instantiate()
    panel:addChild(log)
    AnimalsTab.logBox = log
    cursorY = cursorY + LOG_H + PAD

    -- Row 5: stats line
    local stats = ISLabel:new(PAD, cursorY, 16, "Loaded animals: -",
        0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    AnimalsTab.statsLabel = stats

    refresh()
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id    = "animals",
        label = "Animals",
        order = 6,
        build = build,
    }
    print("[Husbandry] HBAnimalsTab registered into Dragonfly")
end)
