-- SPDX-License-Identifier: GPL-3.0-or-later
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
    -- Whether `rows` includes clean zombies. The server withholds them by
    -- default, so a filter that needs them has to re-request rather than
    -- filter a set that never had them.
    haveClean        = false,
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
        NecroTab.highlightTarget:setOutlineHighlight(false)
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

-- Paged cull. An OnlineID costs ~16 estimated bytes on the wire (a Double key
-- plus a Double value), so a bloom-scale selection sent whole is the same
-- oversize payload the snapshot used to be, pointed upstream. Kept in step with
-- RPServer's RDWire.declareChunked budget for this key by hand - the server
-- declares it, and the client has no meter to read the declaration back from.
local CULL_ID_CHUNK = 150

local cullToken = 0

local function sendCullIds(ids)
    if #ids == 0 then return end
    cullToken = cullToken + 1
    local token = tostring(cullToken)
    local total = math.ceil(#ids / CULL_ID_CHUNK)
    for i = 1, total do
        local base, slice = (i - 1) * CULL_ID_CHUNK, {}
        for k = 1, CULL_ID_CHUNK do
            local id = ids[base + k]
            if not id then break end
            slice[k] = id
        end
        sendClientCommand(getPlayer(), MODULE, "cullIds",
            { ids = slice, token = token, seq = i, total = total })
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Snapshot request / reply
-- ─────────────────────────────────────────────────────────────────────────

-- Chunked snapshot reassembly. The server pages big snapshots into
-- SnapshotChunk commands; gen ties chunks to a single request, and a chunk from
-- a newer gen abandons any half-built one.
--
-- RECOVERY, which this had none of. Completion was a bare count - got >= total -
-- with no seq tracking, no timeout, no retry and nothing shown to the admin. One
-- chunk short of twenty-one and NecroTab.rows was simply never assigned: an empty
-- tab, no error, forever, and a Refresh only re-rolled the same dice under a new
-- gen. That is the failure a paged transport has to expect, so it now tracks
-- which sequence numbers actually landed, gives up out loud, and names the gap.
local pendingSnap = nil

local SNAP_TIMEOUT_TICKS = 300   -- ~10s at 30Hz with no new chunk

-- What we asked for last, and what the rows we are holding actually contain.
-- The two differ while a request is in flight, which is why they are separate.
local requestedClean = false

local function requestSnapshot(includeClean)
    includeClean = includeClean == true
    requestedClean = includeClean
    pendingSnap = nil   -- abandon any half-built stream; a newer gen supersedes it
    sendClientCommand(getPlayer(), MODULE, "requestSnapshot",
        { includeClean = includeClean })
end

local function missingSeqs(p)
    local out = {}
    for i = 1, (p.total or 0) do
        if not p.seen[i] then
            if #out >= 8 then out[#out + 1] = "..."; break end
            out[#out + 1] = tostring(i)
        end
    end
    return table.concat(out, ",")
end

Events.OnTick.Add(function()
    local p = pendingSnap
    if not p then return end
    p.idle = p.idle + 1
    if p.idle < SNAP_TIMEOUT_TICKS then return end
    pendingSnap = nil
    print(string.format("[Reaper] snapshot gen=%s incomplete: %d/%d chunks, missing %s",
        tostring(p.gen), p.got, p.total, missingSeqs(p)))
    if DFFeedback then
        DFFeedback.bad(string.format(
            "Snapshot incomplete: %d of %d chunks arrived. Refresh to retry.",
            p.got, p.total))
    end
end)

local function applyFilter(rows, filter)
    -- "suspects" and "all" are both already-scoped server-side, so neither
    -- filters again here - what came down is exactly what was asked for.
    if not filter or filter == "all" or filter == "suspects" then return rows end
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

local function currentFilter()
    local combo = NecroTab.filterCombo
    if not combo or not combo.getOptionData then return "suspects" end
    return combo:getOptionData(combo.selected) or "suspects"
end

local function rebuildList()
    if not NecroTab.listBox then return end
    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(NecroTab.listBox, function(box)
        for _, row in ipairs(applyFilter(NecroTab.rows, currentFilter())) do
            box:addItem("", row)
        end
    end)
end

-- The two views that need rows the default request deliberately leaves on the
-- server. Selecting one re-requests rather than filtering a set that never
-- contained them, which would silently show an empty list instead.
local NEEDS_CLEAN = { all = true, clean = true }

local function onFilterChanged()
    if NEEDS_CLEAN[currentFilter()] and not NecroTab.haveClean then
        requestSnapshot(true)
    else
        rebuildList()
    end
end

local function updateStats(snap)
    if not NecroTab.statsLabel then return end
    local listed   = #(snap.zombies or {})
    local clusters = 0
    for _, e in ipairs(snap.zombies or {}) do
        if e.verdict == "cluster" then clusters = clusters + 1 end
    end
    local clean = snap.cleanCount or 0
    local tail  = (clean > 0) and string.format("   Clean (not sent): %d", clean) or ""
    NecroTab.statsLabel:setName(string.format(
        "Listed: %d   Cluster candidates: %d%s   Total culls: %d   Cull queue: %d",
        listed, clusters, tail, (snap.stats and snap.stats.culled) or 0,
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
            pendingSnap = { gen = args.gen, total = args.total or 1,
                            rows = {}, seen = {}, got = 0, idle = 0 }
        end
        local p = pendingSnap
        p.idle  = 0
        p.total = args.total or p.total

        -- Counted by sequence number, not by arrival. A duplicate must not
        -- complete a stream that is still a chunk short.
        local seq = tonumber(args.seq) or (p.got + 1)
        if not p.seen[seq] then
            p.seen[seq] = true
            p.got = p.got + 1
            for _, e in ipairs(args.zombies or {}) do
                p.rows[#p.rows + 1] = e
            end
        end

        if args.stats      then p.stats      = args.stats end
        if args.cleanCount then p.cleanCount = args.cleanCount end
        if args.loaded     then p.loaded     = args.loaded end

        if p.got >= p.total then
            pendingSnap = nil
            NecroTab.rows      = p.rows
            NecroTab.haveClean = requestedClean
            rebuildList()
            updateStats({ zombies = p.rows, stats = p.stats, cleanCount = p.cleanCount })
        end
    elseif command == "CullResult" and args then
        if DFFeedback then
            if args.incomplete then
                DFFeedback.bad(string.format(
                    "Cull batch never completed; %d ids dropped. Try again.",
                    args.requested or 0))
            else
                DFFeedback.good(string.format("Culled %d of %d requested.",
                    args.removed or 0, args.requested or 0))
            end
        end
        requestSnapshot(NecroTab.haveClean == true)
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
        -- The registered handler belongs to another mod. One failed action
        -- must not prevent the menu's independent options from running.
        local opt = context:addOption(spec.label, row, function(rowData)
            local ok, err = pcall(spec.handler, rowData)
            if not ok then
                print("[Reaper] row action '" .. tostring(spec.label) .. "' failed: " .. tostring(err))
            end
        end)
        if not enabled then opt.notAvailable = true end
    end
end

function NecroList:prerender()
    ISScrollingListBox.prerender(self)
    if NecroTab.highlightTarget then
        NecroTab.highlightTarget:setOutlineHighlight(true)
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

-- ─────────────────────────────────────────────────────────────────────────
-- Triage model
--
-- Reaper already renders a verdict for every row. The tab's job is to SAY it,
-- not to hand the admin a column of identical "clean" cells to re-derive it
-- from. Everything below is computed from the snapshot the server already
-- sends - drift from tile vs birthTile, siblings from the row set itself - so
-- none of this costs a byte on the wire.
-- ─────────────────────────────────────────────────────────────────────────

local SEVERITY = { clean = 0, seq = 1, stack = 2, cluster = 3 }

-- Which rule produced the verdict. Naming it turns a label into an
-- explanation, and doubles as live feedback while tuning the thresholds.
local RULE_FIRED = {
    seq     = "sequential IDs within seqGap",
    stack   = "stacked past the stack threshold",
    cluster = "outfit cluster past minClu",
}

local function thresholdValue(key, fallback)
    local e = NecroTab.thresholdEntries and NecroTab.thresholdEntries[key]
    local v = e and tonumber(e:getText())
    return v or fallback
end

local function parseTile(s)
    if type(s) ~= "string" then return nil end
    local sx, sy = s:match("^(-?%d+),(-?%d+)")
    if not sx then return nil end
    return tonumber(sx), tonumber(sy)
end

-- How far this zombie has wandered from where it was born. This is the actual
-- bloom signal, and in the old layout it was not shown at all.
local function driftOf(r)
    local bx, by = parseTile(r.birthTile)
    if not bx or not r.x then return nil end
    local dx, dy = r.x - bx, r.y - by
    return math.sqrt(dx * dx + dy * dy)
end

local function siblingsOf(r)
    local prox = thresholdValue("outfitProximity", 75)
    local n, r2 = 0, prox * prox
    for _, o in ipairs(NecroTab.rows) do
        if o.id ~= r.id and o.x and r.x then
            local dx, dy = o.x - r.x, o.y - r.y
            if dx * dx + dy * dy <= r2 then n = n + 1 end
        end
    end
    return n, prox
end

local function firstSelectedRow()
    local ids = selectedIdList()
    if #ids == 0 then return nil end
    for _, e in ipairs(NecroTab.rows) do
        if e.id == ids[1] then return e end
    end
    return nil
end

-- The worst thing on screen, how big it is, and where its centre sits. A
-- triage surface leads with the incident; the table is the audit trail.
local function worstIncident()
    local worst, n, sx, sy = nil, 0, 0, 0
    for _, e in ipairs(NecroTab.rows) do
        local s = SEVERITY[e.verdict or "clean"] or 0
        if s > 0 then
            if not worst or s > SEVERITY[worst] then worst, n, sx, sy = e.verdict, 0, 0, 0 end
            if e.verdict == worst then
                n, sx, sy = n + 1, sx + (e.x or 0), sy + (e.y or 0)
            end
        end
    end
    if not worst or n == 0 then return nil end
    return { verdict = worst, n = n, x = math.floor(sx / n), y = math.floor(sy / n) }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Chrome: verdict band, detail pane, column header, empty state.
-- All drawn, not widgets - it is read-only text that changes every frame.
-- ─────────────────────────────────────────────────────────────────────────

local function drawBand(el)
    local b = NecroTab.bandRect
    if not b then return end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    local inc = worstIncident()

    el:drawRect(b.x, b.y, b.w, b.h, DFKit.alpha.card, C.panel.r, C.panel.g, C.panel.b)

    if not inc then
        -- Quiet. The screen being calm IS the information; do not render a
        -- table to prove it.
        local msg = string.format("NO BLOOMS      %d loaded", #NecroTab.rows)
        el:drawText(msg, b.x + 10, b.y + 6, C.ok.r, C.ok.g, C.ok.b, 0.95, fL)
        return
    end

    local c = (inc.verdict == "cluster" and C.danger)
           or (inc.verdict == "stack" and C.warn)
           or C.warn
    el:drawRect(b.x, b.y, 3, b.h, 1, c.r, c.g, c.b)
    el:drawText(string.format("%s  %d zombies", string.upper(inc.verdict), inc.n),
        b.x + 12, b.y + 4, c.r, c.g, c.b, 1, fL)
    el:drawText(string.format("near %d,%d  -  %s", inc.x, inc.y,
        RULE_FIRED[inc.verdict] or "rule fired"),
        b.x + 12, b.y + 20, C.textDim.r, C.textDim.g, C.textDim.b, 0.9, fL)
end

local function drawDetail(el)
    local d = NecroTab.detailRect
    if not d then return end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    el:drawRect(d.x, d.y, d.w, d.h, DFKit.alpha.inset, C.panel.r, C.panel.g, C.panel.b)

    local r = firstSelectedRow()
    if not r then
        DFKit.drawEmpty(el, d.x, d.y, d.w, d.h, "select a row")
        return
    end

    el:drawText("oid " .. tostring(r.id), d.x + 10, d.y + 8, C.text.r, C.text.g, C.text.b, 1, fL)

    local drift = driftOf(r)
    local sibs, prox = siblingsOf(r)
    local rows = {
        { "tile",     string.format("%d,%d,%d", r.x or 0, r.y or 0, r.z or 0) },
        { "birth",    tostring(r.birthTile or "-") },
        { "drift",    drift and string.format("%.1f tiles", drift) or "-" },
        { "outfit",   tostring(r.outfit or "?") },
        { "dirge",    tostring(r.dirgeType or "-") },
        { "siblings", string.format("%d in %d", sibs, prox) },
    }
    local yy = d.y + 30
    for _, kv in ipairs(rows) do
        el:drawText(kv[1], d.x + 10, yy, C.textDim.r, C.textDim.g, C.textDim.b, 0.85, fL)
        local tw = getTextManager():MeasureStringX(fL, kv[2])
        el:drawText(kv[2], d.x + d.w - 10 - tw, yy, C.text.r, C.text.g, C.text.b, 1, fL)
        yy = yy + 18
    end

    local v = r.verdict or "clean"
    local c = (v == "clean" and C.ok) or (v == "cluster" and C.danger) or C.warn
    local msg = (v == "clean") and "passed all 5 cluster rules"
                                or (RULE_FIRED[v] or "flagged")
    el:drawRect(d.x + 10, yy + 6, d.w - 20, 20, 0.18, c.r, c.g, c.b)
    el:drawText(msg, d.x + 16, yy + 8, c.r, c.g, c.b, 1, fL)
end

local function attachChrome(panel)
    panel.drawNecroChrome = function(self_)
        DFColumns.drawHeader(self_, COLS, NecroTab.headerX or 8, NecroTab.headerY or 8, FONT)
        drawBand(self_)
        drawDetail(self_)
        if #NecroTab.rows == 0 and NecroTab.listRect then
            local l = NecroTab.listRect
            DFKit.drawEmpty(self_, l.x, l.y, l.w, l.h, "nothing to triage")
        end
    end
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        self_:drawNecroChrome()
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Tab build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    NecroTab.sel = RDSelect.new()
    NecroTab.thresholdEntries = {}
    clearHighlight()

    local PAD       = DFKit.metrics.pad
    local BTN_H     = DFKit.metrics.btnH
    local HEADER_H  = DFKit.metrics.headerH

    -- Layout, computed up front so each row lands where triage wants it rather
    -- than wherever a running cursor happened to arrive. The order that matters:
    -- the VERDICT leads, the work row sits under it, and the destructive mass
    -- actions plus the tuning row are pushed BELOW the list - they were at the
    -- top, above the thing they act on, which is how "mass" ended up the
    -- loudest control on screen.
    local BAND_H   = 40
    local bandY    = PAD
    local toolbarY = bandY + BAND_H + PAD
    local headerY  = toolbarY + BTN_H + PAD
    local bodyY    = headerY + HEADER_H

    local statsY   = h - PAD - 18
    local ruleY    = statsY - PAD - BTN_H
    local massY    = ruleY - PAD - BTN_H
    local bodyH    = massY - PAD - bodyY
    if bodyH < 120 then bodyH = 120 end

    -- Body splits: the audit table keeps the left, the detail pane takes the
    -- right. The table stops being the whole tab and becomes the evidence.
    --
    -- The detail pane is FIXED, not a percentage. Its content is short
    -- key/value text that gains nothing from extra width - a wider pane only
    -- pushes the label away from its value. The table is what actually needs
    -- width: the six COLS total 620px at DFColumns' default 4px gap, and a
    -- percentage split narrower than that clipped the Dirge column clean off
    -- the right edge while the header kept drawing at full width over the
    -- detail pane.
    local DETAIL_W = 300
    local colsW    = DFColumns.totalWidth(COLS, 4) + 16   -- + the list's own inset
    local listW    = w - PAD * 3 - DETAIL_W
    if listW < colsW then listW = colsW end               -- never clip a column
    local maxList  = w - PAD * 3 - 160                    -- but leave the pane readable
    if listW > maxList then listW = maxList end
    local detailX  = PAD * 2 + listW
    NecroTab.bandRect   = { x = PAD, y = bandY, w = w - PAD * 2, h = BAND_H }
    NecroTab.listRect   = { x = PAD, y = bodyY, w = listW, h = bodyH }
    NecroTab.detailRect = { x = detailX, y = bodyY, w = w - PAD - detailX, h = bodyH }

    local cursorY = toolbarY

    -- "Suspects only" leads and is the default: it is what the server sends
    -- unasked, and at bloom scale it is the only view that is actually
    -- readable. The two views below it that need clean rows re-request them.
    local filterCombo = ISComboBox:new(PAD, cursorY, 160, BTN_H, panel)
    filterCombo:initialise(); filterCombo:instantiate()
    filterCombo:addOptionWithData("Suspects only",   "suspects")
    filterCombo:addOptionWithData("All zombies",     "all")
    filterCombo:addOptionWithData("Cluster only",    "cluster")
    filterCombo:addOptionWithData("Stack only",      "stack")
    filterCombo:addOptionWithData("Sequential only", "seq")
    filterCombo:addOptionWithData("Clean only",      "clean")
    filterCombo:addOptionWithData("Dirge specials",  "dirge")
    panel:addChild(filterCombo)
    NecroTab.filterCombo = filterCombo

    local origSelect = filterCombo.select
    filterCombo.select = function(self_, ...) origSelect(self_, ...); onFilterChanged() end

    -- Delegates to the shared primitive; call sites unchanged. Pass a `kind` to
    -- DFKit.button for the destructive ones - mass cull should not render with
    -- the same weight as Refresh.
    local function mkBtn(label, bx, bw, handler, kind, opts)
        return DFKit.button(panel, bx, cursorY, bw, label, panel, handler, kind, opts)
    end

    -- Refresh re-asks for whatever the current view needs, not always the
    -- default scope, or refreshing out of "All zombies" would empty the list.
    mkBtn("Refresh",       PAD + 170, 90, function()
        requestSnapshot(NEEDS_CLEAN[currentFilter()] == true)
    end)
    mkBtn("Cull selected", PAD + 270, 110, function()
        local ids = selectedIdList()
        if #ids == 0 then
            if DFFeedback then DFFeedback.bad("No zombies selected.") end
            return
        end
        sendCullIds(ids)
        NecroTab.sel:clear()
    end, "primary")   -- the scoped, intended action: it leads
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
        if p then p:setX(target.x); p:setY(target.y); p:setZ(target.z) end
        if DFFeedback then
            DFFeedback.good(string.format("Teleported to %d,%d,%d.",
                target.x, target.y, target.z))
        end
    end)

    cursorY = massY

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
    DFKit.label(panel, PAD, cursorY + 4, "Mass:", DFKit.col.textDim)

    mkBtn("Remove chunk", PAD + 64, 110, function()
        mass("removeChunkZombies", "Remove all zombies in your current chunk.")
    end, "danger", { hold = true })

    DFKit.label(panel, PAD + 196, cursorY + 4, "Radius:")

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
    end, "danger", { hold = true })

    mkBtn("Remove ALL loaded", PAD + 444, 140, function()
        mass("removeAllLoadedZombies",
            "Remove every zombie currently loaded across all players' cells.")
    end, "danger", { hold = true })

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

    -- Row 2: column header + the rest of the chrome (verdict band, detail pane,
    -- empty state) - all drawn in one prerender hook rather than as widgets.
    NecroTab.headerX, NecroTab.headerY = PAD, headerY
    attachChrome(panel)

    -- Row 3: the audit table, now sharing the body with the detail pane
    local list = NecroList:new(PAD, bodyY, listW, bodyH)
    list.itemheight = 32   -- bumped from 18 for breathing room between rows
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    panel:addChild(list)
    NecroTab.listBox = list

    cursorY = ruleY

    -- Row 4: threshold tuning. Explicit x positions tuned in ScribeView so
    -- each value-entry has breathing room from its label and the next pair.
    -- Entries center-align their text since the contents are short numerics.
    local function addThreshold(label, key, default, labelX, entryX)
        DFKit.label(panel, labelX, cursorY + 4, label)
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
    -- Row 5: stats line
    NecroTab.statsLabel = DFKit.label(panel, PAD, statsY,
        "Loaded: -   Cluster candidates: -   Total culls: -   Cull queue: -",
        DFKit.col.textDim)

    -- Z-order: combo's dropdown popup must render above the scrolling list.
    -- ISUI draws siblings in addChild order (later = on top); the list was
    -- added after the combo so it overdraws the popup. bringToTop promotes
    -- the combo back above so its expanded options aren't hidden behind rows.
    filterCombo:bringToTop()

    -- Fresh combo defaults to "Suspects only", so the opening request matches it.
    requestSnapshot(false)
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
