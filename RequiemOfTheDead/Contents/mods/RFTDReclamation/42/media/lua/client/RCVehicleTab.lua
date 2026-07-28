-- RCVehicleTab - the "Vehicles" tab on Dragonfly's admin panel (DESIGN §7).
--
-- Soft dependency (the RFTD integration contract): registration defers to
-- OnGameStart and bails if the DFRegistry global is absent, so Reclaimation
-- runs headless without Dragonfly. Couples to the DF* globals, never the
-- mod id.
--
-- Lists the vehicles STREAMED TO THIS CLIENT (the admin's loaded area),
-- read from getCell():getVehicles() on demand at refresh - so the tab costs
-- ZERO network and never touches the server or the registry. Row tools:
--   * Teleport to - moves the ADMIN to the car (people to cars: a vehicle's
--     position is a physics Transform, there is no clean Lua relocate)
--   * Spawn... - opens the staff vehicle spawner (RCSpawnWindow; the world
--     right-click is its other door). Visibility follows the sandbox access
--     ladder; the server re-gates every spawn command regardless.
--   * Delete - vanilla remove semantics (the mechanics-UI cheat): vehicle +
--     contents simply gone. NOT a dismantle on purpose (owner's call - an
--     admin cleaning up wants deletion, not scrap mechanics; the field
--     radial is where dismantling lives). Ledgered; a claimed car's index
--     entry is pruned server-side. BULK-CAPABLE via RDSelect (ctrl toggles,
--     shift takes a range) - the removals go one packet per car because that
--     is vanilla's channel, but the ledger travels as a single dismantledMany
--     so a rate-limited loop can never leave cars destroyed and unrecorded.
--     Teleport stays single-target; there is nowhere to teleport to for six.
-- Will later host the §4 recycle admin controls.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"

-- Shared selection model (Core). Same click semantics as the necro and players
-- tabs, so the muscle memory transfers between tabs. Reclaimation hard-requires
-- RFTDCore, and RDSelect lives in media/lua/shared which the client walks before
-- media/lua/client - so this require is belt-and-braces, kept because a
-- file-scope use of an RD* global is declared, never assumed.
require "RDSelect"
local Select = RDSelect

RCVehicleTab = RCVehicleTab or {}

local FONT = UIFont.Code -- monospace, columns line up

-- Ceiling on one bulk delete. Deliberately below RCServer's DISMANTLE_BATCH_MAX
-- so the panel never promises more than the ledger will accept, and low because
-- each target costs a separate vanilla removal packet - see deleteRows.
local BULK_MAX = 10

local COLS = {
    { label = "ID",      w = 62,  get = function(r) return tostring(r.vid) end },
    { label = "Vehicle", w = 200, get = function(r) return r.script end },
    { label = "Dist",    w = 52,  get = function(r) return tostring(r.dist) end },
    { label = "Eng",     w = 46,  get = function(r) return r.engine and tostring(r.engine) or "-" end },
    { label = "Kind",    w = 66,  get = function(r) return r.kind end },
    { label = "Inside",  w = 56,  get = function(r) return r.occupied > 0 and tostring(r.occupied) or "-" end },
    { label = "Owner",   w = 140, get = function(r) return r.owner or "-" end },
}

-- getCell():getVehicles() is a Set - get(i) crashes; :iterator() is the
-- supported path (the RCSession idiom). On-demand only, never a timer.
local function forEachClientVehicle(fn)
    local cell = getCell and getCell()
    if not cell then return end
    local vs = cell:getVehicles()
    if not vs then return end
    local ok, it = pcall(function() return vs:iterator() end)
    if not ok or not it then return end
    while it:hasNext() do
        local v = it:next()
        if v then pcall(fn, v) end
    end
end

local function snapshotRows()
    local me = getPlayer()
    local rows = {}
    forEachClientVehicle(function(v)
        local r = { vid = v:getId(), occupied = 0 }
        r.script = v:getScriptName() or "?"
        r.dist = me and math.floor(me:DistTo(v:getX(), v:getY())) or 0
        pcall(function()
            local eng = v:getPartById("Engine")
            if eng then r.engine = eng:getCondition() end
        end)
        r.kind = RCShared.isWreck(v) and "wreck"
            or (RCShared.isTrailer(v) and "trailer" or "car")
        pcall(function()
            local script = v:getScript()
            local seats = script and script:getPassengerCount() or 0
            for s = 0, seats - 1 do
                if v:isSeatOccupied(s) then r.occupied = r.occupied + 1 end
            end
        end)
        r.owner = RCClaim.getOwner(v)
        rows[#rows + 1] = r
    end)
    table.sort(rows, function(a, b) return a.dist < b.dist end)
    return rows
end

-- Rows carry only the id; actions re-resolve the live object at click time
-- (the vehicle may have streamed out / been removed since the refresh).
local function findByVid(vid)
    local found
    forEachClientVehicle(function(v)
        if not found and v:getId() == vid then found = v end
    end)
    return found
end

-- ---------------------------------------------------------------------------
-- List widget
-- ---------------------------------------------------------------------------
local VehList = ISScrollingListBox:derive("RCVehicleTabList")

-- Vehicle ids in the order the list is currently showing them. Shift ranges and
-- bulk ordering are computed against this, and sel:list() drops anything absent -
-- so a bulk delete can never reach a vehicle the admin cannot see.
local function orderedVids(list)
    local out = {}
    if not list or not list.items then return out end
    for _, it in ipairs(list.items) do
        if it.item and it.item.vid then out[#out + 1] = it.item.vid end
    end
    return out
end

function VehList:doDrawItem(y, item, alt)
    local r = item.item
    if not r then return y + self.itemheight end
    if RCVehicleTab.sel and RCVehicleTab.sel:has(r.vid) then
        if self.selected == item.index then
            -- The primary row reads brighter: with six cars selected it must
            -- still be obvious which one "Teleport to" will take you to.
            self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
        else
            self:drawRect(0, y, self.width, self.itemheight - 1, 0.26, 0.16, 0.34, 0.62)
        end
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    local x = 4
    for _, col in ipairs(COLS) do
        local ok, txt = pcall(col.get, r)
        -- claimed rows tint the owner cell; everything else neutral
        self:drawText(ok and txt or "?", x, y + 2, 0.85, 0.85, 0.85, 1, FONT)
        x = x + col.w
    end
    return y + self.itemheight
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- Base ISScrollingListBox sets self.selected for us; this only adds the
-- multi-row model on top, so every existing single-target path keeps working
-- off list.selected exactly as before.
function VehList:onMouseDown(mx, my)
    ISScrollingListBox.onMouseDown(self, mx, my)
    local it = self.items[self.selected]
    local vid = it and it.item and it.item.vid
    if vid == nil or not RCVehicleTab.sel then return end

    local ctrl, shift = Select.modifiers()
    RCVehicleTab.sel:click(vid, orderedVids(self), ctrl, shift)

    -- A ctrl-click that DEselected the clicked row must not leave it primary, or
    -- Teleport/Delete would act on a row drawn as unselected.
    if not RCVehicleTab.sel:has(vid) then
        local first = RCVehicleTab.sel:list(orderedVids(self))[1]
        for i, row in ipairs(self.items) do
            if row.item and row.item.vid == first then self.selected = i; break end
        end
    end
    if RCVehicleTab.onSelectionChanged then RCVehicleTab.onSelectionChanged() end
end

local function selectedRow(list)
    local it = list.items[list.selected]
    return it and it.item or nil
end

-- Selection in display order, visible rows only.
local function selectedRows(list)
    local out = {}
    if not RCVehicleTab.sel then return out end
    local want = {}
    for _, vid in ipairs(RCVehicleTab.sel:list(orderedVids(list))) do want[vid] = true end
    for _, it in ipairs(list.items or {}) do
        if it.item and want[it.item.vid] then out[#out + 1] = it.item end
    end
    return out
end

local function teleportToRow(row, status)
    local v = findByVid(row.vid)
    if not v then status:setName("Vehicle no longer loaded - refresh."); return end
    local me = getPlayer()
    pcall(function() me:teleportTo(v:getX(), v:getY(), math.floor(v:getZ())) end)
end

-- Instant admin DELETE, vanilla remove semantics. Removal must be SERVER-
-- side: a client-side permanentlyRemove() is local-only (no packet) and the
-- server re-streams the car - the "panel dismantle respawned the vehicle"
-- bug, found live 2026-07-02. Vanilla's own cheat idiom
-- (ISVehicleMechanics.onCheatRemoveAux) is the fix. The report carries
-- owner/claimId so the server prunes the claim index of a claimed car.
-- Build the ledger report for one vehicle. Read BEFORE the removal - afterwards
-- the object is gone and its claim modData with it.
local function reportFor(row, v)
    local report = { via = "panel", delete = true, vehicle = row.script }
    pcall(function()
        report.wreck = RCShared.isWreck(v)
        report.x = math.floor(v:getX())
        report.y = math.floor(v:getY())
        report.z = math.floor(v:getZ())
        if RCClaim.isClaimed(v) then
            report.owner   = RCClaim.getOwner(v)
            report.claimId = RCClaim.getClaimId(v)
        end
    end)
    return report
end

-- Delete a SELECTION. The two halves travel differently on purpose:
--
--   * the removals are vanilla's own "vehicle"/remove channel and cannot be
--     batched - one packet per car, and it must be the SERVER that removes,
--     because a client-side permanentlyRemove() is local-only and the server
--     re-streams the car (the "panel dismantle respawned the vehicle" bug, found
--     live 2026-07-02)
--   * the ledger is ONE dismantledMany carrying every report, never a loop of
--     dismantled: RCServer drops commands past 20/sec silently, so a loop could
--     destroy ten cars and ledger only the first few. An audit that
--     under-reports a destructive staff action is worse than none, because it
--     reads as authoritative.
--
-- Capped at BULK_MAX. Each car re-resolves at click time and any that streamed
-- out since the refresh is skipped rather than guessed at.
local function deleteRows(rows, status, refresh)
    local me = getPlayer()
    local reports, gone, failed = {}, 0, 0
    local capped = false

    for _, row in ipairs(rows) do
        if #reports >= BULK_MAX then capped = true; break end
        local v = findByVid(row.vid)
        if not v then
            gone = gone + 1
        else
            local report = reportFor(row, v)
            local removed = pcall(function()
                if isClient() then
                    sendClientCommand(me, "vehicle", "remove", { vehicle = v:getId() })
                else
                    v:permanentlyRemove()
                end
            end)
            if removed then reports[#reports + 1] = report else failed = failed + 1 end
        end
    end

    if #reports > 0 then
        pcall(function()
            sendClientCommand(me, RCShared.MODULE, "dismantledMany", { reports = reports })
        end)
    end

    -- Say what actually happened, including what was NOT done. A silent
    -- shortfall on a destructive action reads as "all of them went".
    local parts = { string.format("Deleted %d", #reports) }
    if gone > 0   then parts[#parts + 1] = string.format("%d already gone", gone) end
    if failed > 0 then parts[#parts + 1] = string.format("%d failed", failed) end
    if capped     then parts[#parts + 1] = string.format("cap %d per click", BULK_MAX) end
    status:setName(table.concat(parts, " - ") .. ".")

    if RCVehicleTab.sel then RCVehicleTab.sel:clear() end
    refresh()
end

local function confirmDelete(rows, status, refresh)
    local label
    if #rows == 1 then
        local row = rows[1]
        label = string.format(
            "Delete %s (id %s)%s?\n\nThe vehicle and everything inside it are removed from the world for good.",
            tostring(row.script), tostring(row.vid),
            row.owner and (" - CLAIMED by " .. tostring(row.owner)) or "")
    else
        -- Count claimed cars separately: deleting someone's claimed vehicle is a
        -- different act from clearing wrecks, and at six rows the admin cannot
        -- see the Owner column behind this dialog.
        local claimed = 0
        for _, r in ipairs(rows) do if r.owner then claimed = claimed + 1 end end
        label = string.format("Delete %d selected vehicles?%s\n\n"
            .. "They and everything inside them are removed from the world\n"
            .. "for good. This cannot be undone.",
            #rows, claimed > 0 and ("\n\n" .. claimed .. " of them are CLAIMED.") or "")
    end
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 80,
        440, 180, label, true, nil,
        function(_, button)
            if button.internal == "YES" then deleteRows(rows, status, refresh) end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- ---------------------------------------------------------------------------
-- Tab build (DFPanel calls build(spec, panel, x, y, w, h) at panel-open)
-- ---------------------------------------------------------------------------
local function build(spec, panel, x, y, w, h)
    local PAD = 6
    local BTN_H = 22

    -- Fresh selection every time the tab is built. A stale set of vehicle ids
    -- from a previous panel session would point at cars that may since have been
    -- removed, and this is the one tab where acting on the wrong row is
    -- unrecoverable.
    RCVehicleTab.sel = Select.new()

    -- header row: one label per column at its x offset
    local hx = x + PAD + 4
    for _, col in ipairs(COLS) do
        local lbl = ISLabel:new(hx, y + PAD, BTN_H, col.label, 0.7, 0.7, 0.9, 1, FONT, true)
        lbl:initialise()
        panel:addChild(lbl)
        hx = hx + col.w
    end

    local list = VehList:new(
        x + PAD,
        y + PAD + BTN_H,
        w - PAD * 2,
        h - (PAD * 3 + BTN_H * 2 + PAD))
    list.itemheight = 18
    list.drawBorder = true
    list:initialise()
    list:instantiate()
    panel:addChild(list)

    local btnY = y + h - PAD - BTN_H

    local status = ISLabel:new(x + PAD + 450, btnY, BTN_H, "", 0.8, 0.8, 0.8, 1, FONT, true)
    status:initialise()
    panel:addChild(status)

    -- Forward-declared so onMouseDown can retitle the Delete button the moment
    -- the selection changes rather than waiting for a refresh.
    local delBtn

    local function selectionSuffix(n)
        if n > 1 then return string.format("  (%d selected)", n) end
        return ""
    end

    local function syncSelectionUI()
        local n = RCVehicleTab.sel and #selectedRows(list) or 0
        if delBtn then delBtn:setTitle(n > 1 and ("Delete (" .. n .. ")") or "Delete") end
        return n
    end
    RCVehicleTab.onSelectionChanged = function()
        local n = syncSelectionUI()
        if n > 1 then
            -- Only counted buttons go wide; say which row the others use.
            local row = selectedRow(list)
            status:setName(string.format("%d selected - Delete applies to all %d; Teleport uses %s",
                n, n, row and tostring(row.vid) or "?"))
        elseif n == 1 then
            local row = selectedRow(list)
            status:setName("1 selected" .. (row and (" - id " .. tostring(row.vid)) or ""))
        else
            -- Must not leave a stale "6 selected" line up after the set is
            -- emptied; that is the message an admin would act on.
            status:setName("Nothing selected.")
        end
    end

    local function refresh()
        list:clear()
        local rows = snapshotRows()
        for _, r in ipairs(rows) do list:addItem("", r) end
        -- Vehicles stream in and out constantly, so a stale selection is normal
        -- here rather than exceptional. Drop what is gone and SAY so - a bulk
        -- delete quietly applying to fewer cars than the admin can see is
        -- exactly the failure this tab cannot afford.
        local dropped = 0
        if RCVehicleTab.sel then dropped = RCVehicleTab.sel:prune(orderedVids(list)) end
        local n = syncSelectionUI()
        local msg = string.format("%d vehicle(s) loaded nearby%s", #rows, selectionSuffix(n))
        if dropped > 0 then
            msg = msg .. string.format(" - %d selected no longer loaded", dropped)
        end
        status:setName(msg)
    end

    local refreshBtn = ISButton:new(x + PAD, btnY, 90, BTN_H, "Refresh", panel, refresh)
    refreshBtn.borderColor.a = 0.3
    refreshBtn:initialise()
    refreshBtn:instantiate()
    panel:addChild(refreshBtn)

    local tpBtn = ISButton:new(x + PAD + 100, btnY, 110, BTN_H, "Teleport to", panel, function()
        local row = selectedRow(list)
        if row then teleportToRow(row, status) else status:setName("Select a vehicle first.") end
    end)
    tpBtn.borderColor.a = 0.3
    tpBtn:initialise()
    tpBtn:instantiate()
    panel:addChild(tpBtn)

    delBtn = ISButton:new(x + PAD + 220, btnY, 110, BTN_H, "Delete", panel, function()
        -- Bulk-capable: acts on the whole visible selection. Falls back to the
        -- primary row so a plain click-and-Delete behaves exactly as it always
        -- has when nothing multi-row is going on.
        -- No fallback to list.selected on purpose. Ctrl-clicking the only
        -- selected row empties the set while the base widget still has that row
        -- as self.selected - falling back would then delete the row the admin
        -- had just UNSELECTED. On a destructive action, an empty selection means
        -- do nothing.
        local rows = selectedRows(list)
        if #rows > 0 then confirmDelete(rows, status, refresh)
        else status:setName("Select a vehicle first.") end
    end)
    delBtn.borderColor.a = 0.3
    delBtn:initialise()
    delBtn:instantiate()
    panel:addChild(delBtn)

    -- Spawner door #2 (the world right-click is #1; both open RCSpawnWindow).
    -- Decorative gate - the server re-checks the sender on every spawn command.
    if RCShared.canUseSpawner(getPlayer()) then
        local spawnBtn = ISButton:new(x + PAD + 330, btnY, 110, BTN_H, getText("IGUI_RC_SpawnOpenBtn"), panel, function()
            if RCSpawnWindow and RCSpawnWindow.open then RCSpawnWindow.open(getPlayer()) end
        end)
        spawnBtn.borderColor.a = 0.3
        spawnBtn:initialise()
        spawnBtn:instantiate()
        panel:addChild(spawnBtn)
    end

    refresh()
end

-- Deferred registration: DFRegistry may not exist (no Dragonfly) and load
-- order within a session is alphabetical - OnGameStart is the level ground.
Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id         = "rcVehicles",
            label      = "Vehicles",
            capability = Capability.ChangeWeather,
            order      = 6,
            build      = build,
        }
    end)
    if not ok then print("[RC] RCVehicleTab registerTab error: " .. tostring(err)) end
end)
