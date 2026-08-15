-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSTab - the "Longstrider" tab inside the Dragonfly admin panel.
--
-- Left: the list of tours (add / rename / delete / select), each in its colour.
-- Right: the map with every tour drawn; the selected one is editable.
-- Bottom: shared Cell size / Dwell / Grid toggle + selected-region coords, then
-- Run Selected / Run All / Abort with a live progress readout.
--
-- Gated by Capability.TeleportToCoordinates. Pure client; teleport is the
-- vanilla /teleportto. Tours persist via LSTours (client-local file).

if isServer() then return end

require "ISUI/ISLabel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextBox"

local MODULE_TAG = "[Dragonfly] LSTab"
local CELL_MIN, CELL_MAX = 24, 150
local FONT_HGT = getTextManager():getFontHeight(UIFont.Small)

local function num(field) return tonumber(field and field:getText()) end

-- ---------------------------------------------------------------------------
-- Tours list widget
-- ---------------------------------------------------------------------------

local ToursList = ISScrollingListBox:derive("LSToursList")

function ToursList:doDrawItem(y, item, alt)
    local t = item.item
    if not t then return y + self.itemheight end
    if LSTours.selectedId == t.id then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.85, 0.25, 0.20, 0.45)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.10, 1, 1, 1)
    local c = t.color
    self:drawRect(6, y + 6, 12, 12, 1, c[1], c[2], c[3])
    self:drawRectBorder(6, y + 6, 12, 12, 0.8, 1, 1, 1)
    self:drawText(t.name or ("Tour " .. tostring(t.id)), 26,
        y + math.floor((self.itemheight - FONT_HGT) / 2), 0.92, 0.92, 0.92, 1, UIFont.Small)
    return y + self.itemheight
end

function ToursList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if not item or not item.item then return end
    self.selected = idx
    if self.onSelectTour then self.onSelectTour(item.item.id) end
end

-- ---------------------------------------------------------------------------
-- Tab build
-- ---------------------------------------------------------------------------

local function build(spec, panel, x, y, w, h)
    local player = getPlayer()
    if not player then return end

    LSTours.load()

    -- Metrics from DFKit so this tab cannot drift from the family. ROW/LBL stay
    -- local: they are Longstrider's own list-row and label rhythm, not shared.
    local PAD, BTN_H = DFKit.metrics.pad, DFKit.metrics.btnH
    local ROW, LBL   = 28, 16
    local LEFT_W   = 210
    local headH    = ROW
    local bottomH  = ROW * 2 + PAD
    local midY     = headH
    local midH     = h - headH - bottomH - PAD
    if midH < 140 then midH = 140 end

    local mapX = LEFT_W + PAD
    local mapW = w - mapX - PAD

    -- ---- Map (cached, re-parented across tab rebuilds) ----
    local map = LSMap.acquire(player, mapW, midH)
    if map.parent and map.parent ~= panel then
        -- vanilla ISUI Lua (removeChild -> UIElement internals, unverifiable
        -- against the decompile); a stale parent from a torn-down tab must not
        -- kill this rebuild
        pcall(function() map.parent:removeChild(map) end)
    end
    map:setX(mapX); map:setY(midY); map:setMapSize(mapW, midH)
    panel:addChild(map)

    -- Sync the big 300-tile CellGrid to the saved toggle. Only the API can be
    -- missing; setBoolean itself is instanceof-guarded (WorldMapRenderer:697)
    -- on a final renderer (UIWorldMap:85, UIWorldMapV1:29).
    local mapApi = map:getAPI()
    if mapApi then mapApi:setBoolean("CellGrid", LSTours.gridOn) end

    -- ---- Overlay (cached on the map instance) ----
    local overlay = map._lsOverlay
    if not overlay then
        overlay = LSGridOverlay:new(map)
        map._lsOverlay = overlay
    end
    overlay:hookNow()
    overlay:setTours(LSTours.list)
    overlay:setSelectedId(LSTours.selectedId)
    overlay:setCellSize(LSTours.cellSize)
    overlay:setGridOn(LSTours.gridOn)
    overlay:setMaxCells(LSTours.maxCells)

    -- Forward declarations
    local toursList, cornerFields, cellField, dwellField, gridBtn
    local runSelBtn, runAllBtn, abortBtn, progress, stats, renameBtn, deleteBtn
    local rebuildList, recompute, syncFields, selectTour

    -- ---- Header: "Tours" label (left) + stats (over map) ----
    local lblTours = ISLabel:new(PAD, 4, LBL, "Tours", 0.85, 0.90, 0.95, 1, UIFont.Small, true)
    lblTours:initialise(); lblTours:instantiate(); panel:addChild(lblTours)

    stats = ISLabel:new(mapX, 4, LBL, "", 0.80, 0.88, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate(); panel:addChild(stats)

    -- ---- Left column: list + add/rename/delete ----
    local listBtnY = midY + midH - ROW
    local listH    = (listBtnY - PAD) - midY
    if listH < 60 then listH = 60 end

    toursList = ToursList:new(PAD, midY, LEFT_W - PAD, listH)
    toursList.itemheight = 24
    toursList.drawBorder = true
    DFKit.well(toursList)
    toursList:initialise(); toursList:instantiate()
    toursList.onSelectTour = function(id) selectTour(id) end
    panel:addChild(toursList)

    -- The fourth copy of this helper in the family; now a one-line delegate so
    -- the call sites below are untouched. LSTab keeps its hand-rolled region
    -- maths for now - the cached map is re-parented across rebuilds and needs
    -- setMapSize alongside any reflow, so it gets no `resize` hook until that
    -- is done deliberately rather than blind.
    local function mkBtn(label, bx, bw, by, cb)
        return DFKit.button(panel, bx, by, bw, label, panel, cb)
    end

    local addBtn = mkBtn("Add", PAD, 58, listBtnY, function()
        local api = map:getAPI()
        if not api then DFFeedback.bad("Map not ready yet."); return end
        local cx = math.floor(api:uiToWorldX(map.map:getWidth() / 2, map.map:getHeight() / 2))
        local cy = math.floor(api:uiToWorldY(map.map:getWidth() / 2, map.map:getHeight() / 2))
        local half = math.max(LSTours.cellSize * 2, 60)
        local t = LSTours.add({ cx - half, cy - half, cx + half, cy + half })
        overlay:setTours(LSTours.list)
        overlay:setSelectedId(t.id)
        rebuildList(); syncFields(); recompute()
        DFFeedback.good("Added " .. t.name .. " - drag its handles to size it.")
    end)
    -- vanilla ISUI Lua (ISButton colour helper, unverifiable against the
    -- decompile); losing the green tint must not lose the button
    pcall(function() addBtn:enableAcceptColor() end)

    renameBtn = mkBtn("Rename", PAD + 62, 66, listBtnY, function()
        local t = LSTours.getSelected()
        if not t then DFFeedback.bad("Select a tour first."); return end
        -- vanilla ISTextBox construction chain (ISUI Lua, unverifiable against
        -- the decompile); a modal that fails to build must not break the tab
        pcall(function()
            local modal
            modal = ISTextBox:new(getCore():getScreenWidth() / 2 - 150, getCore():getScreenHeight() / 2 - 60,
                300, 120, "Rename tour:", t.name, nil, function(_, btn)
                    if btn.internal == "OK" and modal and modal.entry then
                        LSTours.rename(t.id, modal.entry:getText())
                        rebuildList()
                    end
                end, player:getPlayerNum())
            modal:initialise(); modal:addToUIManager()
        end)
    end)

    deleteBtn = mkBtn("Delete", PAD + 132, 66, listBtnY, function()
        local t = LSTours.getSelected()
        if not t then DFFeedback.bad("Select a tour first."); return end
        LSTours.remove(t.id)
        overlay:setTours(LSTours.list)
        overlay:setSelectedId(LSTours.selectedId)
        rebuildList(); syncFields(); recompute()
        DFFeedback.good("Deleted " .. t.name .. ".")
    end)
    -- vanilla ISUI Lua (ISButton colour helper, existence-checked because older
    -- builds lack it; the body stays unverifiable against the decompile)
    pcall(function() if deleteBtn.enableCancelColor then deleteBtn:enableCancelColor() end end)

    -- ---- Bottom row 1: Cell / Dwell / Grid / coords ----
    local r1y = midY + midH + PAD
    local r2y = r1y + ROW
    local cur = PAD

    local function addLabel(text, rowY)
        local l = ISLabel:new(cur, rowY + 4, LBL, text, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
        l:initialise(); l:instantiate(); panel:addChild(l)
        cur = cur + getTextManager():MeasureStringX(UIFont.Small, text) + 4
    end
    local function addField(initText, width, rowY, onlyNums, onChange)
        local f = ISTextEntryBox:new(initText, cur, rowY, width, BTN_H)
        f:initialise(); f:instantiate()
        -- vanilla ISTextEntryBox Lua (unverifiable against the decompile); a
        -- field without the digit filter still works, just accepts junk
        if onlyNums then pcall(function() f:setOnlyNumbers(true) end) end
        if onChange then f.onTextChange = onChange end
        panel:addChild(f)
        cur = cur + width + PAD
        return f
    end

    -- NOTE: no onTextChange here. ISTextEntryBox fires it one keystroke behind,
    -- so committing the value there drops the last digit (e.g. "2500" -> 250).
    -- The prerender poll reads these fields each frame (always current) instead.
    addLabel("Cell", r1y)
    cellField = addField(tostring(LSTours.cellSize), 46, r1y, true, nil)

    addLabel("Dwell ms", r1y)
    dwellField = addField(tostring(LSTours.dwellMs), 58, r1y, true, nil)

    gridBtn = mkBtn(LSTours.gridOn and "Grid: ON" or "Grid: OFF", cur, 92, r1y, function()
        local on = not LSTours.gridOn
        LSTours.setGridOn(on)
        overlay:setGridOn(on)
        -- same shape as the build-time sync above: only the API can be missing
        local api = map:getAPI()
        if api then api:setBoolean("CellGrid", on) end
        gridBtn:setTitle(on and "Grid: ON" or "Grid: OFF")
    end)
    cur = cur + 92 + PAD

    -- Selected-region coords
    cornerFields = {}
    for _, name in ipairs({ "X1", "Y1", "X2", "Y2" }) do
        addLabel(name, r1y)
        cornerFields[#cornerFields + 1] = addField("", 54, r1y, false, nil)
    end
    local setBtn = mkBtn("Set", cur, 54, r1y, function()
        local t = LSTours.getSelected()
        if not t then DFFeedback.bad("Select a tour first."); return end
        local x1, y1, x2, y2 = num(cornerFields[1]), num(cornerFields[2]), num(cornerFields[3]), num(cornerFields[4])
        if not (x1 and y1 and x2 and y2) then DFFeedback.bad("Enter all four corners."); return end
        if math.abs(x2 - x1) < 1 or math.abs(y2 - y1) < 1 then DFFeedback.bad("Region too small."); return end
        local nr = LSTours.setRegion(t.id, { x1, y1, x2, y2 })   -- returns the normalised rect
        if nr then map:zoomAndCentreMapToBounds(nr[1], nr[2], nr[3], nr[4]) end
        recompute()
    end)

    -- ---- Bottom row 2: Run Selected / Run All / Abort / progress ----
    local function preflight(jobs, label)
        if not DFCore.roleHas(player, Capability.TeleportToCoordinates) then
            DFFeedback.bad("You lack the Teleport-to-coordinates capability."); return
        end
        local n = LSTour.countCells(jobs, LSTours.cellSize)
        if n == 0 then DFFeedback.bad("Nothing to populate."); return end
        if n > LSTours.maxCells then
            DFFeedback.bad(string.format("%d cells exceeds the %d cap - raise Cell size or split it up.", n, LSTours.maxCells))
            return
        end
        local etaS = math.ceil(n * LSTours.dwellMs / 1000)
        DFConfirm.askIfOthersOnline(
            string.format("%s: %d cells across %d region(s), ~%ds. You will teleport across the map.", label, n, #jobs, etaS),
            function()
                local ok, err = LSTour.start(jobs, LSTours.cellSize, { dwellMs = LSTours.dwellMs })
                if ok then overlay:setLocked(true); DFFeedback.good("Tour started.")
                else DFFeedback.bad(err or "Could not start.") end
            end)
    end

    runSelBtn = mkBtn("Run Selected", PAD, 120, r2y, function()
        local t = LSTours.getSelected()
        if not t then DFFeedback.bad("Select a tour first."); return end
        -- snapshot region BY VALUE so an edit during the confirm modal can't change what runs
        preflight({ { name = t.name, region = { t.region[1], t.region[2], t.region[3], t.region[4] } } }, "Run " .. t.name)
    end)

    runAllBtn = mkBtn("Run All", PAD + 128, 100, r2y, function()
        if #LSTours.list == 0 then DFFeedback.bad("No tours defined."); return end
        local jobs = {}
        for _, t in ipairs(LSTours.list) do
            jobs[#jobs + 1] = { name = t.name, region = { t.region[1], t.region[2], t.region[3], t.region[4] } }
        end
        preflight(jobs, "Run all " .. #jobs .. " tours")
    end)

    abortBtn = mkBtn("Abort", PAD + 236, 90, r2y, function()
        LSTour.abort(); overlay:setLocked(false); DFFeedback.good("Tour aborted.")
    end)

    progress = ISLabel:new(PAD + 336, r2y + 4, LBL, "", 0.95, 0.90, 0.50, 1, UIFont.Small, true)
    progress:initialise(); progress:instantiate(); panel:addChild(progress)

    -- ---- Helpers ----
    rebuildList = function()
        local selIdx
        -- DFKit.refillList: a bare clear() leaves the scroll height behind and
        -- addItem stacks onto it, which eventually scrolls the list off its own
        -- rows. See that function's header.
        DFKit.refillList(toursList, function(box)
            for i, t in ipairs(LSTours.list) do
                box:addItem(t.name, t)
                if t.id == LSTours.selectedId then selIdx = i end
            end
        end)
        toursList.selected = selIdx or 0
    end

    syncFields = function()
        local t = LSTours.getSelected()
        if not t or not t.region then
            for i = 1, 4 do cornerFields[i]:setText("") end
            return
        end
        local r = t.region
        cornerFields[1]:setText(tostring(r[1])); cornerFields[2]:setText(tostring(r[2]))
        cornerFields[3]:setText(tostring(r[3])); cornerFields[4]:setText(tostring(r[4]))
    end

    recompute = function()
        local sel = LSTours.getSelected()
        local allJobs = {}
        for _, t in ipairs(LSTours.list) do allJobs[#allJobs + 1] = { name = t.name, region = t.region } end
        local allN = LSTour.countCells(allJobs, LSTours.cellSize)
        local allEta = math.ceil(allN * LSTours.dwellMs / 1000)

        if sel then
            local r = sel.region
            -- Count, don't build. A region is no longer clamped to the cap while
            -- it is being drawn, so materialising its cells for a status line is
            -- unbounded work on every handle release.
            local selN = LSTour.cellCountOf(r, LSTours.cellSize)
            local selEta = math.ceil(selN * LSTours.dwellMs / 1000)
            local over = selN > LSTours.maxCells
            stats:setName(string.format(
                "%s: %dx%d  %d cells ~%ds%s    |    All %d tours: %d cells ~%ds  (cap %d)",
                sel.name, r[3] - r[1], r[4] - r[2], selN, selEta,
                over and "  OVER CAP" or "",
                #LSTours.list, allN, allEta, LSTours.maxCells))
            runSelBtn.enable = selN > 0 and not over
        else
            stats:setName(#LSTours.list == 0
                and "No tours yet - click Add to drop a region, then shape it with the handles."
                or "Select a tour (click it in the list or on the map).")
            runSelBtn.enable = false
        end
        runAllBtn.enable = allN > 0 and allN <= LSTours.maxCells
    end

    selectTour = function(id)
        LSTours.select(id)
        overlay:setSelectedId(id)
        rebuildList(); syncFields(); recompute()
    end

    -- ---- Overlay callbacks ----
    overlay.onSelect = function(id) selectTour(id) end
    overlay.onRegionEdited = function(id)
        local t = LSTours.get(id)
        if t then LSTours.setRegion(id, t.region) end   -- normalise + persist
        syncFields(); recompute()
    end

    -- ---- Live poll ----
    local origPre = panel.prerender
    panel.prerender = function(self_)
        if origPre then origPre(self_) end

        -- Commit Cell/Dwell by reading the fields here (current value, no
        -- one-keystroke lag). Only writes when the value actually changes.
        local cv = tonumber(cellField:getText())
        if cv then
            cv = math.max(CELL_MIN, math.min(CELL_MAX, math.floor(cv)))
            if cv ~= LSTours.cellSize then
                LSTours.setCellSize(cv); overlay:setCellSize(cv); recompute()
            end
        end
        local dv = tonumber(dwellField:getText())
        if dv then
            dv = math.max(250, math.floor(dv))
            if dv ~= LSTours.dwellMs then LSTours.setDwellMs(dv); recompute() end
        end

        local st = LSTour.status()
        if st.running then
            overlay:setLocked(true)
            overlay:setRunner({ cells = st.cells, current = st.idx })
            runSelBtn.enable, runAllBtn.enable, abortBtn.enable = false, false, true
            progress:setName(string.format("Touring %s: cell %d / %d  ~%ds left",
                tostring(st.jobName or "?"), st.idx, st.total, math.ceil(st.etaMs / 1000)))
        else
            overlay:setLocked(false)
            overlay:setRunner(nil)
            abortBtn.enable = false
            progress:setName("")
        end
    end

    -- ---- Initial paint ----
    rebuildList(); syncFields(); recompute()
    local sel = LSTours.getSelected()
    if sel and sel.region then
        map:zoomAndCentreMapToBounds(sel.region[1], sel.region[2], sel.region[3], sel.region[4])
    end
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

print(MODULE_TAG .. " body loaded; deferring registration to OnGameStart")

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    -- DFRegistry is Core's: containment for a foreign-mod API whose contract
    -- may change; a refusal must not kill this OnGameStart listener.
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id         = "longstrider",
            label      = "Longstrider",
            order      = 60,
            capability = Capability.TeleportToCoordinates,
            build      = build,
        }
    end)
    if not ok then print(MODULE_TAG .. " registerTab error: " .. tostring(err)) end
end)

-- Dragonfly Longstrider v0.3.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
