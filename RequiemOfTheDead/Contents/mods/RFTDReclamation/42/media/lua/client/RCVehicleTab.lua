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
--     entry is pruned server-side.
-- Will later host the §4 recycle admin controls.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISModalDialog"

RCVehicleTab = RCVehicleTab or {}

local FONT = UIFont.Code -- monospace, columns line up

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

function VehList:doDrawItem(y, item, alt)
    local r = item.item
    if not r then return y + self.itemheight end
    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
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

local function selectedRow(list)
    local it = list.items[list.selected]
    return it and it.item or nil
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
local function deleteRow(row, status, refresh)
    local v = findByVid(row.vid)
    if not v then status:setName("Vehicle no longer loaded - refresh."); return end
    local me = getPlayer()

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

    local removed = pcall(function()
        if isClient() then
            sendClientCommand(me, "vehicle", "remove", { vehicle = v:getId() })
        else
            v:permanentlyRemove()
        end
    end)
    if removed then
        pcall(function() sendClientCommand(me, RCShared.MODULE, "dismantled", report) end)
        status:setName("Deleted " .. tostring(row.script))
    else
        status:setName("Delete failed - see log.")
    end
    refresh()
end

local function confirmDelete(row, status, refresh)
    local label = string.format("Delete %s (id %s)%s?\n\nThe vehicle and everything inside it are removed from the world for good.",
        tostring(row.script), tostring(row.vid),
        row.owner and (" - CLAIMED by " .. tostring(row.owner)) or "")
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 80,
        440, 180, label, true, nil,
        function(_, button)
            if button.internal == "YES" then deleteRow(row, status, refresh) end
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

    local function refresh()
        list:clear()
        local rows = snapshotRows()
        for _, r in ipairs(rows) do list:addItem("", r) end
        status:setName(string.format("%d vehicle(s) loaded nearby", #rows))
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

    local delBtn = ISButton:new(x + PAD + 220, btnY, 110, BTN_H, "Delete", panel, function()
        local row = selectedRow(list)
        if row then confirmDelete(row, status, refresh) else status:setName("Select a vehicle first.") end
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
