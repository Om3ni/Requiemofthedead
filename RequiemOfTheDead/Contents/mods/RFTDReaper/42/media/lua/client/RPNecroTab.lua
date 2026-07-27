-- RPNecroTab - registers the Necro tab on Dragonfly's admin panel.
--
-- Soft dependency on Dragonfly: defers registration to OnGameStart so this
-- file works regardless of mod load order. Without Dragonfly, the file
-- loads and does nothing; Reaper keeps running headless.
--
-- Columnar layout (DFColumns) - this is a dense inspector, not a visual
-- browser. Header row, fixed column widths, right-aligned numerics,
-- per-cell color for verdict severity.

if isServer() then return end

-- DFRegistry check happens inside the OnGameStart callback below, not here.
-- Top-of-file early return would prevent the OnGameStart hook from ever
-- being registered if Reaper loads before DragonflyAdmin.

require "ISUI/ISScrollingListBox"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

-- Core's shared selection model. Explicit rather than riding the alphabetical
-- walk, per the family rule since the 42.19 boot-log crashes; Reaper
-- hard-requires Core so this is always resolvable.
require "RDSelect"

local MODULE = "RFTDReaper"
local FONT   = UIFont.Code  -- monospace; columns line up better

local NecroTab = {
    rows             = {},
    -- RDSelect instance, reset per build(). Safe to depend on unconditionally:
    -- RDSelect lives in Core and Reaper hard-requires Core. (It briefly lived in
    -- Dragonfly, which Reaper only soft-depends on, and that forced a
    -- create-inside-build dance to avoid breaking servers without Dragonfly.)
    sel              = nil,
    listBox          = nil,
    filterCombo      = nil,
    statsLabel       = nil,
    thresholdEntries = {},
    highlightTarget  = nil,
    radiusEntry      = nil,
}

local DEFAULT_MASS_RADIUS = 25

-- Verdict color: worse = redder.
local VERDICT_COLOR = {
    clean   = { 0.85, 0.85, 0.85 },
    seq     = { 0.95, 0.80, 0.35 },
    stack   = { 0.95, 0.55, 0.30 },
    cluster = { 0.95, 0.40, 0.40 },
}

local COLS = {
    { key = "id",     label = "OID",     w = 70, align = "center" },
    { key = "tile",   label = "Tile",    w = 130, align = "center",
      format = function(r) return string.format("%d,%d,%d", r.x or 0, r.y or 0, r.z or 0) end },
    { key = "outfit", label = "Outfit",  w = 140, align = "center",
      format = function(r) return tostring(r.outfit or "?") end },
    { key = "verdict", label = "Verdict", w = 70, align = "center",
      format = function(r) return string.upper(tostring(r.verdict or "?")) end,
      color  = function(r) return VERDICT_COLOR[r.verdict] or VERDICT_COLOR.clean end },
    { key = "birth", label = "Birth tile", w = 110, align = "center",
      format = function(r) return tostring(r.birthTile or "-") end },
    { key = "dirge", label = "Dirge", w = 80, align = "center",
      format = function(r) return tostring(r.dirgeType or "-") end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Local helpers
-- ─────────────────────────────────────────────────────────────────────────

local function findZombieById(id)
    local p = getPlayer()
    if not p then return nil end
    local cell = p:getCell()
    if not cell then return nil end
    local zlist = cell:getZombieList()
    if not zlist then return nil end
    for i = 0, zlist:size() - 1 do
        local z = zlist:get(i)
        if z and z:getOnlineID() == id then return z end
    end
    return nil
end

local function clearHighlight()
    if NecroTab.highlightTarget then
        pcall(function() NecroTab.highlightTarget:setOutlineHighlight(false) end)
        NecroTab.highlightTarget = nil
    end
end

local function applyHighlight(id)
    clearHighlight()
    local z = findZombieById(id)
    if z then NecroTab.highlightTarget = z end
end

-- Ids in the order the list is currently DRAWN, which is what a shift range has
-- to walk: the span the admin sees between two clicks, filter and all. Also
-- makes selectedIdList() return display order instead of hash order, so a cull
-- applies top-to-bottom.
local function orderedIds()
    local out = {}
    local lb = NecroTab.listBox
    if not lb or not lb.items then return out end
    for _, it in ipairs(lb.items) do
        if it.item and it.item.id then out[#out + 1] = it.item.id end
    end
    return out
end

local function selectedIdList()
    if not NecroTab.sel then return {} end
    return NecroTab.sel:list(orderedIds())
end

-- ─────────────────────────────────────────────────────────────────────────
-- Snapshot request / reply
-- ─────────────────────────────────────────────────────────────────────────

local function requestSnapshot()
    sendClientCommand(getPlayer(), MODULE, "requestSnapshot", {})
end

-- Chunked snapshot reassembly. The server pages big snapshots into
-- SnapshotChunk commands (one per tick); gen ties chunks to a single
-- request, and a chunk from a newer gen abandons any half-built one.
local pendingSnap = nil

local function applyFilter(rows, filter)
    if not filter or filter == "all" then return rows end
    local out = {}
    for _, e in ipairs(rows) do
        local keep = false
        if filter == "cluster" or filter == "stack" or filter == "seq" or filter == "clean" then
            keep = (e.verdict == filter)
        elseif filter == "dirge" then
            keep = (e.dirgeType ~= nil)
        end
        if keep then out[#out + 1] = e end
    end
    return out
end

local function rebuildList()
    if not NecroTab.listBox then return end
    NecroTab.listBox:clear()
    local filter = "all"
    if NecroTab.filterCombo and NecroTab.filterCombo.getOptionData then
        filter = NecroTab.filterCombo:getOptionData(NecroTab.filterCombo.selected) or "all"
    end
    for _, row in ipairs(applyFilter(NecroTab.rows, filter)) do
        NecroTab.listBox:addItem("", row)
    end
end

local function updateStats(snap)
    if not NecroTab.statsLabel then return end
    local total    = #(snap.zombies or {})
    local clusters = 0
    for _, e in ipairs(snap.zombies or {}) do
        if e.verdict == "cluster" then clusters = clusters + 1 end
    end
    NecroTab.statsLabel:setName(string.format(
        "Loaded: %d   Cluster candidates: %d   Total culls: %d   Cull queue: %d",
        total, clusters, (snap.stats and snap.stats.culled) or 0,
        (snap.stats and snap.stats.queued) or 0))
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    if command == "Snapshot" then           -- legacy single-packet form
        NecroTab.rows = (args and args.zombies) or {}
        rebuildList()
        updateStats(args or {})
    elseif command == "SnapshotChunk" and args then
        if not pendingSnap or pendingSnap.gen ~= args.gen then
            pendingSnap = { gen = args.gen, total = args.total or 1, rows = {}, got = 0 }
        end
        for _, e in ipairs(args.zombies or {}) do
            pendingSnap.rows[#pendingSnap.rows + 1] = e
        end
        if args.stats then pendingSnap.stats = args.stats end
        pendingSnap.got = pendingSnap.got + 1
        if pendingSnap.got >= pendingSnap.total then
            NecroTab.rows = pendingSnap.rows
            rebuildList()
            updateStats({ zombies = pendingSnap.rows, stats = pendingSnap.stats })
            pendingSnap = nil
        end
    elseif command == "CullResult" and args then
        if DFFeedback then
            DFFeedback.good(string.format("Culled %d of %d requested.",
                args.removed or 0, args.requested or 0))
        end
        requestSnapshot()
    elseif command == "ThresholdAck" and args then
        if DFFeedback then
            DFFeedback.good(string.format("Threshold %s = %s applied.",
                tostring(args.key), tostring(args.value)))
        end
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- ─────────────────────────────────────────────────────────────────────────
-- List rendering (columnar)
-- ─────────────────────────────────────────────────────────────────────────

local NecroList = ISScrollingListBox:derive("RPNecroList")

function NecroList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    if NecroTab.sel and NecroTab.sel:has(row.id) then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)

    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
    return y + self.itemheight
end

function NecroList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if not item or not item.item then return end
    local id = item.item.id
    if not NecroTab.sel then return end

    local ctrl, shift = RDSelect.modifiers()
    NecroTab.sel:click(id, orderedIds(), ctrl, shift)

    -- Highlight only when the click resolved to a single zombie. Highlighting
    -- one of forty is noise, and that is also why a plain click (which always
    -- resolves to one) behaves exactly as it did before this was shared out.
    if NecroTab.sel:count() == 1 and NecroTab.sel:has(id) then
        self.selected = idx
        applyHighlight(id)
    end
end

function NecroList:onRightMouseUp(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if not item or not item.item then return end
    local row = item.item

    local actions = DFRegistry.getRowActions("necro")
    if not actions or #actions == 0 then return end

    local context = ISContextMenu.get(0, getMouseX() + 8, getMouseY() + 8)
    for _, spec in ipairs(actions) do
        local enabled = true
        if spec.capability then enabled = DFCore.roleHas(getPlayer(), spec.capability) end
        local opt = context:addOption(spec.label, row, function(rowData) pcall(spec.handler, rowData) end)
        if not enabled then opt.notAvailable = true end
    end
end

function NecroList:prerender()
    ISScrollingListBox.prerender(self)
    if NecroTab.highlightTarget then
        pcall(function() NecroTab.highlightTarget:setOutlineHighlight(true) end)
    end
end

-- Wrap render with explicit stencil clipping. B42's ISScrollingListBox
-- doesn't always restrict drawing to its visible box, so rows can paint
-- past the list's bounds and overdraw sibling widgets (most visibly: the
-- filter dropdown above, when it's open). Stencil rect forces all drawing
-- inside render to be clipped to the list's local 0,0,width,height.
function NecroList:render()
    self:setStencilRect(0, 0, self.width, self.height)
    ISScrollingListBox.render(self)
    self:clearStencilRect()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Header row above the list (manual prerender on the content panel)
-- ─────────────────────────────────────────────────────────────────────────

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
-- Tab build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    NecroTab.sel = RDSelect.new()
    NecroTab.thresholdEntries = {}
    clearHighlight()

    local PAD       = 8
    local BTN_H     = 24
    local HEADER_H  = 20

    -- Row 1: filter + action buttons
    local cursorY = PAD

    local filterCombo = ISComboBox:new(PAD, cursorY, 160, BTN_H, panel)
    filterCombo:initialise(); filterCombo:instantiate()
    filterCombo:addOptionWithData("All zombies",     "all")
    filterCombo:addOptionWithData("Cluster only",    "cluster")
    filterCombo:addOptionWithData("Stack only",      "stack")
    filterCombo:addOptionWithData("Sequential only", "seq")
    filterCombo:addOptionWithData("Clean only",      "clean")
    filterCombo:addOptionWithData("Dirge specials",  "dirge")
    panel:addChild(filterCombo)
    NecroTab.filterCombo = filterCombo

    local origSelect = filterCombo.select
    filterCombo.select = function(self_, ...) origSelect(self_, ...); rebuildList() end

    local function mkBtn(label, bx, bw, handler)
        local b = ISButton:new(bx, cursorY, bw, BTN_H, label, panel, handler)
        b.borderColor.a = 0.4
        b:initialise(); b:instantiate()
        panel:addChild(b)
        return b
    end

    mkBtn("Refresh",       PAD + 170, 90, requestSnapshot)
    mkBtn("Cull selected", PAD + 270, 110, function()
        local ids = selectedIdList()
        if #ids == 0 then
            if DFFeedback then DFFeedback.bad("No zombies selected.") end
            return
        end
        sendClientCommand(getPlayer(), MODULE, "cullIds", { ids = ids })
        NecroTab.sel:clear()
    end)
    mkBtn("Find siblings", PAD + 390, 110, function()
        local ids = selectedIdList()
        if #ids == 0 then return end
        local seedRows = {}
        for _, e in ipairs(NecroTab.rows) do
            for _, id in ipairs(ids) do
                if e.id == id then seedRows[#seedRows + 1] = e; break end
            end
        end
        for _, seed in ipairs(seedRows) do
            for _, e in ipairs(NecroTab.rows) do
                local idGap = math.abs(e.id - seed.id)
                local dx, dy = e.x - seed.x, e.y - seed.y
                if idGap <= 15 and (dx*dx + dy*dy) <= 2500 then
                    NecroTab.sel:add(e.id)
                end
            end
        end
        if DFFeedback then
            DFFeedback.good("Selected " .. NecroTab.sel:count() .. " siblings.")
        end
    end)
    mkBtn("Teleport to",   PAD + 510, 100, function()
        local ids = selectedIdList()
        local target
        for _, e in ipairs(NecroTab.rows) do
            if ids[1] and e.id == ids[1] then target = e; break end
        end
        if not target then
            if DFFeedback then DFFeedback.bad("Pick a zombie first.") end
            return
        end
        local p = getPlayer()
        pcall(function() p:setX(target.x); p:setY(target.y); p:setZ(target.z) end)
        if DFFeedback then
            DFFeedback.good(string.format("Teleported to %d,%d,%d.",
                target.x, target.y, target.z))
        end
    end)

    cursorY = cursorY + BTN_H + PAD

    -- Row 1b: mass actions. Routes to DragonflyAdmin's removeChunk /
    -- removeRadius / removeAllLoaded handlers (server-side), guarded by
    -- DFConfirm.askIfOthersOnline since they affect everyone's world.
    local function mass(action, label, args)
        local function send()
            sendClientCommand(getPlayer(), DFCore and DFCore.MODULE or "RFTDDragonfly",
                action, args or {})
        end
        if DFConfirm then
            DFConfirm.askIfOthersOnline(label, send)
        else
            send()
        end
    end

    -- X offsets in this row were tuned in ScribeView; nudged from the
    -- original tight-pack to give the widgets visible breathing room.
    local massLbl = ISLabel:new(PAD, cursorY + 4, 16, "Mass:", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    massLbl:initialise(); massLbl:instantiate()
    panel:addChild(massLbl)

    mkBtn("Remove chunk", PAD + 64, 110, function()
        mass("removeChunkZombies", "Remove all zombies in your current chunk.")
    end)

    local rLbl = ISLabel:new(PAD + 196, cursorY + 4, 16, "Radius:", 0.85, 0.85, 0.85, 1, UIFont.Small, true)
    rLbl:initialise(); rLbl:instantiate()
    panel:addChild(rLbl)

    local rEntry = ISTextEntryBox:new(tostring(DEFAULT_MASS_RADIUS),
        PAD + 250, cursorY, 50, BTN_H)
    rEntry.align  = "center"
    rEntry.valign = "middle"
    rEntry:initialise(); rEntry:instantiate()
    panel:addChild(rEntry)
    NecroTab.radiusEntry = rEntry

    mkBtn("Remove radius", PAD + 312, 120, function()
        local r = tonumber(rEntry:getText()) or DEFAULT_MASS_RADIUS
        mass("removeRadiusZombies",
            string.format("Remove all zombies within %d tiles of your position.", r),
            { radius = r })
    end)

    mkBtn("Remove ALL loaded", PAD + 444, 140, function()
        mass("removeAllLoadedZombies",
            "Remove every zombie currently loaded across all players' cells.")
    end)

    -- Dirge: refund every loaded zombie's consumed spawn roll and re-run
    -- the conversion sweep now. Routes to Dirge's own server module (not
    -- Dragonfly's), so it's only offered when Dirge is actually running;
    -- the result toast comes back via Dirge's adminRerollResult handler.
    if getActivatedMods():contains("RFTDDirge") then
        mkBtn("Reroll Dirge", PAD + 596, 120, function()
            local function send()
                sendClientCommand(getPlayer(), "RFTDDirge", "adminReroll", {})   -- Dirge's token (the legacy bare token is dead)
                if DFFeedback then DFFeedback.good("Dirge reroll requested.") end
            end
            if DFConfirm then
                DFConfirm.askIfOthersOnline(
                    "Reroll Dirge specials for every loaded zombie? New specials will appear near players.",
                    send)
            else
                send()
            end
        end)
    end

    cursorY = cursorY + BTN_H + PAD

    -- Row 2: column header (drawn via panel.prerender, not a child widget)
    local headerY = cursorY
    attachHeader(panel, PAD, headerY)
    cursorY = cursorY + HEADER_H

    -- Row 3: zombie list (everything between header and threshold row)
    local listH = h - cursorY - (PAD * 2 + BTN_H + 22)
    local list = NecroList:new(PAD, cursorY, w - PAD * 2, listH)
    list.itemheight = 32   -- bumped from 18 for breathing room between rows
    list.drawBorder = true
    list:initialise(); list:instantiate()
    panel:addChild(list)
    NecroTab.listBox = list
    cursorY = cursorY + listH + PAD

    -- Row 4: threshold tuning. Explicit x positions tuned in ScribeView so
    -- each value-entry has breathing room from its label and the next pair.
    -- Entries center-align their text since the contents are short numerics.
    local function addThreshold(label, key, default, labelX, entryX)
        local lbl = ISLabel:new(labelX, cursorY + 4, 16, label, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
        lbl:initialise(); lbl:instantiate()
        panel:addChild(lbl)
        local entry = ISTextEntryBox:new(tostring(default), entryX, cursorY, 50, BTN_H)
        entry.align  = "center"
        entry.valign = "middle"
        entry:initialise(); entry:instantiate()
        panel:addChild(entry)
        NecroTab.thresholdEntries[key] = entry
    end
    addThreshold("seqGap:", "sequentialThreshold", 2,  PAD,       PAD + 74)
    addThreshold("stack:",  "stackThreshold",      5,  PAD + 130, PAD + 192)
    addThreshold("idGap:",  "outfitIdGap",         15, PAD + 247, PAD + 312)
    addThreshold("minClu:", "outfitMinCluster",    3,  PAD + 365, PAD + 431)
    addThreshold("prox:",   "outfitProximity",     75, PAD + 485, PAD + 548)
    mkBtn("Apply tuning", PAD + 607, 110, function()
        for key, entry in pairs(NecroTab.thresholdEntries) do
            local v = tonumber(entry:getText())
            if v then
                sendClientCommand(getPlayer(), MODULE, "setThreshold",
                    { key = key, value = v })
            end
        end
    end)
    cursorY = cursorY + BTN_H + PAD

    -- Row 5: stats line
    local stats = ISLabel:new(PAD, cursorY, 16,
        "Loaded: -   Cluster candidates: -   Total culls: -   Cull queue: -",
        0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    NecroTab.statsLabel = stats

    -- Z-order: combo's dropdown popup must render above the scrolling list.
    -- ISUI draws siblings in addChild order (later = on top); the list was
    -- added after the combo so it overdraws the popup. bringToTop promotes
    -- the combo back above so its expanded options aren't hidden behind rows.
    filterCombo:bringToTop()

    requestSnapshot()
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id         = "necro",
        label      = "Necro",
        capability = Capability.ChangeWeather,
        order      = 5,
        build      = build,
    }
    print("[Reaper] RPNecroTab registered into Dragonfly")
end)
