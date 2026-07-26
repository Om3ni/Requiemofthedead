-- DFPlayersTab - registers the Players tab on Dragonfly's admin panel.
--
-- Dense columnar list of online players plus a detail pane for the selected
-- row: an access-level dropdown and a stack of action buttons that route
-- through either DFServer handlers or vanilla chat commands (kick / ban /
-- teleport) the same way DFScoreboard does. Per-action capability gating
-- client-side (greyed out), server re-validates.
--
-- Role ASSIGNMENT was deliberately removed (the B42 Role column stays,
-- read-only): the in-panel role dropdown double-dutied with vanilla's role
-- management, leaving two sources of truth for a player's role. Existing
-- assignments in Dragonfly_PlayerRoles.txt still re-apply on connect via
-- DFPlayerRoles_Server, which stays until those are migrated to vanilla.
--
-- v1 ships without a right-click context menu - actions are explicit buttons
-- in the detail pane. v2 will add the row context menu via
-- DFRegistry.getRowActions("players") for consumer-mod extension.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISComboBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"

local MODULE = "RFTDDragonfly"
local FONT   = UIFont.Code

local PlayersTab = {
    rows         = {},
    selectedName = nil,
    listBox      = nil,
    filterCombo  = nil,
    statsLabel   = nil,
    detail       = {},  -- holds dropdowns/buttons rebuilt on selection
}

local ACCESS_LEVELS = { "admin", "moderator", "overseer", "gm", "observer", "none" }

local ROW_COLOR_ADMIN = { 0.95, 0.85, 0.50 }
local ROW_COLOR_SELF  = { 0.55, 0.80, 0.95 }
local ROW_COLOR_BASE  = { 0.92, 0.92, 0.92 }

local function rowTint(row)
    if row.isSelf then return ROW_COLOR_SELF end
    local lvl = string.lower(tostring(row.access or "none"))
    if lvl == "admin" or lvl == "moderator" or lvl == "gm" or lvl == "overseer" then
        return ROW_COLOR_ADMIN
    end
    return ROW_COLOR_BASE
end

local COLS = {
    { key = "username", label = "Username", w = 130, align = "left" },
    { key = "display",  label = "Display",  w = 130, align = "left",
      format = function(r) return tostring(r.display or r.username or "?") end },
    { key = "role",     label = "B42 Role", w = 110, align = "left",
      format = function(r) return tostring(r.role or "-") end },
    { key = "access",   label = "Access",   w = 80,  align = "center",
      format = function(r) return tostring(r.access or "none") end,
      color  = function(r) return rowTint(r) end },
    { key = "pos",      label = "Position", w = 130, align = "center",
      format = function(r) return string.format("%d,%d,%d", r.x or 0, r.y or 0, r.z or 0) end },
    { key = "chunk",    label = "Chunk",    w = 70,  align = "center",
      format = function(r) return string.format("%d,%d",
          math.floor((r.x or 0) / 10), math.floor((r.y or 0) / 10)) end },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Snapshot
-- ─────────────────────────────────────────────────────────────────────────

local function requestSnapshot()
    sendClientCommand(getPlayer(), MODULE, "playersList", {})
end

local function applyFilter(rows, filter)
    if not filter or filter == "all" then return rows end
    local out = {}
    for _, r in ipairs(rows) do
        local lvl = string.lower(tostring(r.access or "none"))
        local isStaff = (lvl == "admin" or lvl == "moderator"
                      or lvl == "gm" or lvl == "overseer")
        if filter == "staff" and isStaff then out[#out + 1] = r
        elseif filter == "players" and not isStaff then out[#out + 1] = r
        end
    end
    return out
end

local function findRowByName(name)
    if not name then return nil end
    for _, r in ipairs(PlayersTab.rows) do
        if r.username == name then return r end
    end
    return nil
end

local function rebuildList()
    if not PlayersTab.listBox then return end
    PlayersTab.listBox:clear()
    local filter = "all"
    if PlayersTab.filterCombo and PlayersTab.filterCombo.getOptionData then
        filter = PlayersTab.filterCombo:getOptionData(PlayersTab.filterCombo.selected) or "all"
    end
    for _, r in ipairs(applyFilter(PlayersTab.rows, filter)) do
        PlayersTab.listBox:addItem("", r)
    end
end

local function updateStats()
    if not PlayersTab.statsLabel then return end
    local total, staff = 0, 0
    for _, r in ipairs(PlayersTab.rows) do
        total = total + 1
        local lvl = string.lower(tostring(r.access or "none"))
        if lvl == "admin" or lvl == "moderator" or lvl == "gm" or lvl == "overseer" then
            staff = staff + 1
        end
    end
    PlayersTab.statsLabel:setName(string.format("Online: %d   Staff: %d", total, staff))
end

local function refreshDetail()
    local d = PlayersTab.detail
    if not d.panel then return end
    local row = findRowByName(PlayersTab.selectedName)
    if not row then
        d.title:setName("No player selected")
        d.accessCombo:setVisible(false)
        for _, b in ipairs(d.actionButtons or {}) do b:setVisible(false) end
        return
    end
    d.title:setName(string.format("%s  (%s) - %s @ %d,%d,%d",
        row.username, row.display or row.username, row.access or "none",
        row.x or 0, row.y or 0, row.z or 0))
    d.accessCombo:setVisible(true)
    for _, b in ipairs(d.actionButtons or {}) do b:setVisible(true) end

    -- God-mode / invisible buttons are stateful toggles: labels reflect the
    -- target's current state so the admin sees ON/OFF rather than a blind toggle.
    if d.godButton then
        d.godButton:setTitle(row.god and "God: ON" or "God: OFF")
    end
    if d.invisButton then
        d.invisButton:setTitle(row.invis and "Invis: ON" or "Invis: OFF")
    end

    -- Pre-select the dropdown to the player's current value.
    if d.accessCombo.options then
        for i, opt in ipairs(d.accessCombo.options) do
            if opt.text == tostring(row.access or "none") then d.accessCombo.selected = i; break end
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    if command == "PlayersList" then
        PlayersTab.rows = (args and args.players) or {}
        rebuildList()
        updateStats()
        refreshDetail()
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- ─────────────────────────────────────────────────────────────────────────
-- List widget
-- ─────────────────────────────────────────────────────────────────────────

local PlayerList = ISScrollingListBox:derive("DFPlayerList")

function PlayerList:doDrawItem(y, item, alt)
    local row = item.item
    if not row then return y + self.itemheight end

    if PlayersTab.selectedName == row.username then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.18, 0.08, 0.08, 0.08)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight, 0.12, 1, 1, 1)
    DFColumns.drawRow(self, COLS, row, 4, y, FONT, rowTint(row), 4, self.itemheight)
    return y + self.itemheight
end

function PlayerList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx <= 0 then return end
    local item = self.items[idx]
    if not item or not item.item then return end
    PlayersTab.selectedName = item.item.username
    self.selected = idx
    refreshDetail()
end

function PlayerList:render()
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
-- Actions
-- ─────────────────────────────────────────────────────────────────────────

local function quote(s) return "\"" .. tostring(s or "") .. "\"" end

local function notify(action, target)
    DFLog.push{ source = "Admin", level = "audit",
        text = string.format("%s by %s (target=%s)",
            action, getPlayer():getUsername(), tostring(target or "?")) }
    pcall(sendClientCommand, getPlayer(), MODULE, "auditOnly",
        { action = action, target = target })
end

local function withSelected(actionLabel, capability, fn)
    return function()
        local row = findRowByName(PlayersTab.selectedName)
        if not row then
            if DFFeedback then DFFeedback.bad("Select a player first.") end
            return
        end
        if capability and not DFCore.roleHas(getPlayer(), capability) then
            if DFFeedback then DFFeedback.bad("Missing capability for " .. actionLabel) end
            return
        end
        fn(row)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Detail pane builder
-- ─────────────────────────────────────────────────────────────────────────

local function buildDetail(panel, x, y, w, h)
    local PAD   = 6
    local BTN_H = 24
    local d     = PlayersTab.detail
    d.panel = panel
    d.actionButtons = {}

    panel:drawRect(x, y, w, h, 0.18, 0.08, 0.08, 0.08)

    local title = ISLabel:new(x + PAD, y + PAD, 16, "No player selected",
        0.85, 0.85, 0.95, 1, UIFont.Medium, true)
    title:initialise(); title:instantiate()
    panel:addChild(title)
    d.title = title

    local row1Y = y + PAD + 22

    -- Access dropdown + Apply. (Role assignment was deliberately stripped from
    -- this tab: it double-dutied with vanilla's role management and left two
    -- sources of truth for a player's role. Access level stays because vanilla
    -- has no equivalent panel surface and the chat-command route persists.)
    local accLbl = ISLabel:new(x + PAD, row1Y + 4, 16, "Access:",
        0.85, 0.85, 0.85, 1, UIFont.Small, true)
    accLbl:initialise(); accLbl:instantiate()
    panel:addChild(accLbl)

    local accCombo = ISComboBox:new(x + PAD + 60, row1Y, 110, BTN_H, panel)
    accCombo:initialise(); accCombo:instantiate()
    for _, lvl in ipairs(ACCESS_LEVELS) do accCombo:addOption(lvl) end
    panel:addChild(accCombo)
    d.accessCombo = accCombo

    local accApply = ISButton:new(x + PAD + 176, row1Y, 70, BTN_H, "Apply", panel,
        withSelected("Set Access", Capability.ChangeAccessLevel, function(row)
            local idx = accCombo.selected or 0
            local opt = accCombo.options and accCombo.options[idx]
            local lvl = opt and opt.text
            if not lvl then return end
            -- Route through vanilla's chat command. Server-side
            -- target:setAccessLevel only mutates the live IsoPlayer in memory;
            -- vanilla's whitelist DB write happens inside /setaccesslevel's
            -- command handler, so on reconnect the engine would snap them
            -- back to the persisted access. Going through the chat command
            -- gets the persistence for free.
            SendCommandToServer(string.format(
                "/setaccesslevel %s %s", quote(row.username), lvl))
            notify("Set Access", row.username)
            if DFFeedback then
                DFFeedback.good(string.format(
                    "Set %s's access to %s.", row.username, lvl))
            end
        end))
    accApply.borderColor.a = 0.4
    accApply:initialise(); accApply:instantiate()
    panel:addChild(accApply)
    d.actionButtons[#d.actionButtons + 1] = accApply

    -- Restore Memoir: disaster-recovery rebuild from the server's memoir archive
    -- (Lua/Memoirs/<player>/latest.json). Lives on row 1 because row 2 is full.
    -- Always-confirm: it overwrites the target's build/XP with the archived
    -- snapshot at 100% (server re-gates on capability + once-per-life).
    local restoreBtn = ISButton:new(x + PAD + 300, row1Y, 130, BTN_H, "Restore Memoir", panel,
        withSelected("Restore Memoir", Capability.CanModifyPlayerStatsInThePlayerStatsUI, function(row)
            local function send()
                sendClientCommand(getPlayer(), MODULE, "memoirRestore", { username = row.username })
                notify("Restore Memoir", row.username)
            end
            if DFConfirm and DFConfirm.ask then
                DFConfirm.ask("Restore " .. row.username .. "'s character from the memoir archive?\n\n"
                    .. "Their current build and XP will be overwritten by the archived snapshot\n"
                    .. "(anything earned since the archive still adds on top).", send)
            else send() end
        end))
    restoreBtn.borderColor.a = 0.4
    restoreBtn:initialise(); restoreBtn:instantiate()
    panel:addChild(restoreBtn)
    d.actionButtons[#d.actionButtons + 1] = restoreBtn

    -- Action button row
    local row2Y = row1Y + BTN_H + PAD
    local function mkAction(label, bx, bw, cap, handler)
        local btn = ISButton:new(x + PAD + bx, row2Y, bw, BTN_H, label, panel,
            withSelected(label, cap, handler))
        btn.borderColor.a = 0.4
        btn:initialise(); btn:instantiate()
        panel:addChild(btn)
        d.actionButtons[#d.actionButtons + 1] = btn
        return btn
    end

    mkAction("Teleport to", 0, 100, Capability.TeleportToPlayer, function(row)
        SendCommandToServer("/teleport " .. quote(row.username))
        notify("Teleport to", row.username)
    end)
    mkAction("Bring to me", 104, 100, Capability.TeleportPlayerToAnotherPlayer, function(row)
        SendCommandToServer("/teleportplayer "
            .. quote(row.username) .. " " .. quote(getPlayer():getUsername()))
        notify("Bring to me", row.username)
    end)
    mkAction("Inspect Stats", 208, 110, Capability.CanSeePlayersStats, function(row)
        local target = getPlayerFromUsername(row.username)
        if not target then
            if DFFeedback then DFFeedback.bad("Stats target is not loaded.") end
            return
        end
        pcall(function()
            if ISPlayerStatsUI.instance then ISPlayerStatsUI.instance:close() end
        end)
        local modal = ISPlayerStatsUI:new(50, 50,
            800 + (getCore():getOptionFontSizeReal() * 50), 800, target, getPlayer())
        modal:initialise(); modal:addToUIManager(); modal:setVisible(true)
        notify("Inspect Stats", row.username)
    end)
    mkAction("Inspect Inv", 322, 100, Capability.InspectPlayerInventory, function(row)
        if not DFPlayerInventoryModal then
            if DFFeedback then DFFeedback.bad("DFPlayerInventoryModal not loaded.") end
            return
        end
        DFPlayerInventoryModal.open(row.username)
        notify("Inspect Inv", row.username)
    end)
    mkAction("Medical", 426, 80, Capability.CanMedicalCheat, function(row)
        local target = getPlayerFromUsername(row.username)
        if not target then
            if DFFeedback then DFFeedback.bad("Medical target is not loaded.") end
            return
        end
        if DFMedicalCheck and DFMedicalCheck.performAdmin then
            DFMedicalCheck.performAdmin(getPlayer(), target)
            notify("Medical", row.username)
        end
    end)
    mkAction("Kick", 510, 70, Capability.KickUser, function(row)
        local function send()
            SendCommandToServer("/kickuser " .. quote(row.username))
            notify("Kick", row.username)
        end
        if DFConfirm then
            DFConfirm.askIfOthersOnline("Kick " .. row.username .. " from the server.", send)
        else send() end
    end)
    mkAction("Ban", 584, 70, Capability.BanUnbanUser, function(row)
        local function send()
            SendCommandToServer("/banuser " .. quote(row.username))
            notify("Ban", row.username)
        end
        if DFConfirm then
            DFConfirm.askIfOthersOnline("Ban " .. row.username .. " from the server.", send)
        else send() end
    end)

    -- God-mode toggle. Routed through vanilla's /godmodplayer chat command (same
    -- rationale as access changes above): the engine handler sets godmod on the
    -- live IsoPlayer AND broadcasts state via sendPlayerExtraInfo, so the target
    -- client syncs for free. We send the EXPLICIT -true/-false form (not the
    -- bare toggle) keyed off the snapshot's god flag, so two admins clicking in
    -- quick succession can't desync into opposite states. Optimistically flip
    -- the cached flag for instant label feedback; the next snapshot confirms.
    d.godButton = mkAction("God: OFF", 658, 96, Capability.ToggleGodModEveryone, function(row)
        local turnOn = not row.god
        SendCommandToServer(string.format("/godmodplayer %s %s",
            quote(row.username), turnOn and "-true" or "-false"))
        row.god = turnOn
        notify(turnOn and "God Mode ON" or "God Mode OFF", row.username)
        if DFFeedback then
            DFFeedback.good(string.format("%s god mode for %s.",
                turnOn and "Enabled" or "Disabled", row.username))
        end
        refreshDetail()
    end)

    -- Invisible toggle. Same routing/state rationale as God Mode above; vanilla's
    -- /invisibleplayer also sets ghost mode, so the target both vanishes from
    -- zombies and clips terrain (matches the ESC scoreboard's Invisible button).
    d.invisButton = mkAction("Invis: OFF", 758, 96, Capability.ToggleInvisibleEveryone, function(row)
        local turnOn = not row.invis
        SendCommandToServer(string.format("/invisibleplayer %s %s",
            quote(row.username), turnOn and "-true" or "-false"))
        row.invis = turnOn
        notify(turnOn and "Invisible ON" or "Invisible OFF", row.username)
        if DFFeedback then
            DFFeedback.good(string.format("%s invisibility for %s.",
                turnOn and "Enabled" or "Disabled", row.username))
        end
        refreshDetail()
    end)

    refreshDetail()
end

-- ─────────────────────────────────────────────────────────────────────────
-- Tab build
-- ─────────────────────────────────────────────────────────────────────────

local function build(spec, panel, x, y, w, h)
    PlayersTab.selectedName = nil
    PlayersTab.detail = {}

    local PAD       = 8
    local BTN_H     = 24
    local HEADER_H  = 20
    local DETAIL_H  = 96

    local cursorY = PAD

    -- Filter combo + Refresh button
    local filterCombo = ISComboBox:new(PAD, cursorY, 160, BTN_H, panel)
    filterCombo:initialise(); filterCombo:instantiate()
    filterCombo:addOptionWithData("All players",       "all")
    filterCombo:addOptionWithData("Admins+Mods only",  "staff")
    filterCombo:addOptionWithData("Players only",      "players")
    panel:addChild(filterCombo)
    PlayersTab.filterCombo = filterCombo

    local origSelect = filterCombo.select
    filterCombo.select = function(self_, ...) origSelect(self_, ...); rebuildList() end

    local refreshBtn = ISButton:new(PAD + 170, cursorY, 90, BTN_H, "Refresh",
        panel, requestSnapshot)
    refreshBtn.borderColor.a = 0.4
    refreshBtn:initialise(); refreshBtn:instantiate()
    panel:addChild(refreshBtn)

    -- Stats label, right-justified on the same row
    local stats = ISLabel:new(PAD + 280, cursorY + 4, 16,
        "Online: -   Staff: -", 0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    PlayersTab.statsLabel = stats

    cursorY = cursorY + BTN_H + PAD

    -- Column header
    local headerY = cursorY
    attachHeader(panel, PAD, headerY)
    cursorY = cursorY + HEADER_H

    -- List takes everything between header and detail pane
    local listH = h - cursorY - DETAIL_H - PAD * 2
    if listH < 80 then listH = 80 end

    local list = PlayerList:new(PAD, cursorY, w - PAD * 2, listH)
    list.itemheight = 28
    list.drawBorder = true
    list:initialise(); list:instantiate()
    panel:addChild(list)
    PlayersTab.listBox = list
    cursorY = cursorY + listH + PAD

    -- Detail pane
    buildDetail(panel, PAD, cursorY, w - PAD * 2, DETAIL_H)

    -- Z-order: combos' dropdown popups must render above the scrolling list.
    -- ISUI draws siblings in addChild order (later = on top); the list was
    -- added after filterCombo so it overdraws the popup. bringToTop promotes
    -- each combo back above. Detail-pane combos need it too since they sit
    -- below the list and their popups typically expand upward into list space.
    filterCombo:bringToTop()
    if PlayersTab.detail.accessCombo then PlayersTab.detail.accessCombo:bringToTop() end

    requestSnapshot()
end

print("[Dragonfly] DFPlayersTab body loaded; deferring registration to OnGameStart")

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id         = "players",
            label      = "Players",
            order      = 20,
            capability = Capability.KickUser,
            build      = build,
        }
    end)
    if not ok then
        print("[Dragonfly] DFPlayersTab registerTab error: " .. tostring(err))
    end
end)

-- Dragonfly v0.2.0
