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
--
-- MULTI-SELECT (ctrl-toggle / shift-range) is on the list, but only SOME actions
-- are bulk-capable, so the pane has to say which. Two rules hold it together:
--   * selectedName remains the PRIMARY row. Every single-target button still
--     reads it, which is why none of them needed to change.
--   * a bulk-capable button shows its count ("Restore Memoir (5)"). If a button
--     shows no count it acts on the primary row alone. The detail title says so
--     out loud whenever more than one row is selected.
-- Bulk actions are capped and never loop sendClientCommand - see BULK_MAX.

if isServer() then return end

require "ISUI/ISScrollingListBox"
require "ISUI/ISComboBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"

-- Selection model lives in Core so this tab, Reaper's necro tab and
-- Reclamation's vehicle tab share one set of click semantics. RDSelect sits in
-- media/lua/shared, which the client walks BEFORE media/lua/client, so this
-- require is belt-and-braces rather than load-order critical - keep it anyway:
-- the family rule since the 42.19 boot crashes is that a file-scope use of an
-- RD* global is declared, never assumed, and the alias below is exactly that.
require "RDSelect"
local Select = RDSelect

local MODULE = "RFTDDragonfly"
local FONT   = UIFont.Code

-- Ceiling on one bulk click, client side. Mirrors MMRestore's own MAX_BATCH so
-- the panel and the authority agree on the limit instead of the server silently
-- trimming what the panel promised.
local BULK_MAX = 10

-- Default for the XP% dial beside Restore Memoir. 100 = the behaviour that
-- shipped before the dial existed, so leaving the field alone changes nothing.
local XP_PCT_DEFAULT = 100

local PlayersTab = {
    rows         = {},
    selectedName = nil,           -- PRIMARY row: what single-target buttons hit
    sel          = Select.new(),  -- full selection, keyed by username
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

-- ─────────────────────────────────────────────────────────────────────────
-- Selection views
--
-- Two DIFFERENT orderings, and conflating them is a bug:
--   orderedNames  what the list is showing right now, after the filter. Shift
--                 ranges and bulk ordering are computed against this, and
--                 sel:list() drops anything absent - so a bulk action can never
--                 touch a player the admin cannot currently see.
--   rosterNames   every online player regardless of filter. PRUNING uses this.
--                 Pruning against the filtered view instead would delete the
--                 selection every time a snapshot arrived with a filter active.
-- ─────────────────────────────────────────────────────────────────────────

local function orderedNames()
    local out = {}
    local lb = PlayersTab.listBox
    if not lb or not lb.items then return out end
    for _, it in ipairs(lb.items) do
        if it.item and it.item.username then out[#out + 1] = it.item.username end
    end
    return out
end

local function rosterNames()
    local out = {}
    for _, r in ipairs(PlayersTab.rows) do
        if r.username then out[#out + 1] = r.username end
    end
    return out
end

-- Selection in display order, visible rows only.
local function selectedNames()
    return PlayersTab.sel:list(orderedNames())
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

    local names = selectedNames()

    -- The primary row goes stale when its player disconnects or the filter hides
    -- them. Re-point it at the selection rather than blanking a pane that still
    -- has selected rows in it.
    if PlayersTab.selectedName and not findRowByName(PlayersTab.selectedName) then
        PlayersTab.selectedName = names[1]
    end

    local row = findRowByName(PlayersTab.selectedName)
    if not row then
        d.title:setName("No player selected")
        d.accessCombo:setVisible(false)
        for _, b in ipairs(d.actionButtons or {}) do b:setVisible(false) end
        return
    end
    d.accessCombo:setVisible(true)
    for _, b in ipairs(d.actionButtons or {}) do b:setVisible(true) end

    local vis, total = #names, PlayersTab.sel:count()
    if vis > 1 then
        -- Say the quiet part out loud: which buttons are bulk, which row the
        -- others hit, and that the filter is hiding part of the selection. Kept
        -- terse because this is one ISLabel on a fixed-width pane - it clips
        -- rather than wraps.
        local hidden = ""
        if total > vis then
            hidden = string.format("  [+%d hidden]", total - vis)
        end
        d.title:setName(string.format("%d selected - counted buttons hit all %d, others hit %s%s",
            vis, vis, row.username, hidden))
    else
        d.title:setName(string.format("%s  (%s) - %s @ %d,%d,%d",
            row.username, row.display or row.username, row.access or "none",
            row.x or 0, row.y or 0, row.z or 0))
    end

    -- Bulk-capable buttons carry the count so it is never ambiguous how far a
    -- click reaches. No count shown means primary row only.
    if d.restoreButton then
        d.restoreButton:setTitle(vis > 1 and ("Restore Memoir (" .. vis .. ")") or "Restore Memoir")
    end
    if d.bringButton then
        d.bringButton:setTitle(vis > 1 and ("Bring to me (" .. vis .. ")") or "Bring to me")
    end

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
        -- Players disconnect mid-selection. Drop them from the set rather than
        -- firing a bulk action at someone who left, and SAY the selection shrank
        -- so the admin does not read a smaller count as the action misfiring.
        local dropped = PlayersTab.sel:prune(rosterNames())
        if dropped > 0 and DFFeedback then
            DFFeedback.bad(string.format("%d selected player%s no longer online.",
                dropped, dropped == 1 and "" or "s"))
        end
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

    if PlayersTab.sel:has(row.username) then
        if PlayersTab.selectedName == row.username then
            -- Primary row reads brighter than the rest of the selection, so a
            -- five-row selection still shows WHICH row "Kick" would hit.
            self:drawRect(0, y, self.width, self.itemheight - 1, 0.35, 0.25, 0.55, 0.85)
        else
            self:drawRect(0, y, self.width, self.itemheight - 1, 0.26, 0.16, 0.34, 0.62)
        end
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
    local name = item.item.username

    local ctrl, shift = Select.modifiers()
    PlayersTab.sel:click(name, orderedNames(), ctrl, shift)

    -- A ctrl-click that DEselected the clicked row must not leave it primary, or
    -- the single-target buttons would keep acting on a row drawn as unselected.
    if PlayersTab.sel:has(name) then
        PlayersTab.selectedName = name
    else
        PlayersTab.selectedName = selectedNames()[1]
    end
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

-- Audit/label text for a set of targets. Names are useful up to a point; past
-- that a count reads better and keeps the audit line a sane length.
local function targetLabel(names)
    if #names == 0 then return "?" end
    if #names == 1 then return names[1] end
    if #names <= 3 then return table.concat(names, ",") end
    return #names .. " players"
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

-- Bulk sibling of withSelected: hands the handler the whole visible selection in
-- display order instead of one row. Same client-side capability gate; the server
-- re-validates once for the batch, because one capability covers every target.
local function withSelection(actionLabel, capability, fn)
    return function()
        local names = selectedNames()
        if #names == 0 then
            if DFFeedback then DFFeedback.bad("Select a player first.") end
            return
        end
        if capability and not DFCore.roleHas(getPlayer(), capability) then
            if DFFeedback then DFFeedback.bad("Missing capability for " .. actionLabel) end
            return
        end
        fn(names)
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Detail pane builder
-- ─────────────────────────────────────────────────────────────────────────

local function buildDetail(panel, x, y, w, h)
    -- was PAD = 6 here and PAD = 8 further down in this same file
    local PAD   = DFKit.metrics.pad
    local BTN_H = DFKit.metrics.btnH
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

    local accApply = DFKit.button(panel, x + PAD + 176, row1Y, 70, "Apply", panel,
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
    d.actionButtons[#d.actionButtons + 1] = accApply

    -- Restore Memoir: disaster-recovery rebuild from the server's memoir archive
    -- (Lua/Memoirs/<player>/latest.json). Lives on row 1 because row 2 is full.
    -- Always-confirm: it overwrites the target's build/XP with the archived
    -- snapshot at 100% (server re-gates on capability + once-per-life).
    --
    -- BULK-CAPABLE, and each target is restored from THEIR OWN archive: the
    -- command carries the username list and MMRestore.runMany resolves each name
    -- independently. That is the whole reason this sends one command with a list
    -- instead of looping sendClientCommand - DFServer drops everything past 20
    -- commands/sec SILENTLY, so a loop could restore four of five people and
    -- still report success for all five.
    -- The XP% dial, read at click time and sent with the command.
    --
    -- It scales EARNED xp only. The saved build's profession and trait grants
    -- always restore in full, so no value - not even 0 - can land a character
    -- below a fresh spawn of their own build. The label says "Earned" because an
    -- admin who reads it as "% of their XP bar" will dial the wrong number: 60
    -- here does NOT mean the character ends up at 60% of what they had.
    --
    -- Primary use is not disaster recovery but season migration: set 60, restore
    -- the returning players, and they carry a defined fraction of last season's
    -- work across. Left at 100 it is exactly the behaviour that shipped before.
    local xpLbl = ISLabel:new(x + PAD + 438, row1Y + 4, 16, "Earned XP %:",
        0.85, 0.85, 0.85, 1, UIFont.Small, true)
    xpLbl:initialise(); xpLbl:instantiate()
    panel:addChild(xpLbl)
    d.actionButtons[#d.actionButtons + 1] = xpLbl

    local xpEntry = ISTextEntryBox:new(tostring(XP_PCT_DEFAULT), x + PAD + 514, row1Y, 46, BTN_H)
    xpEntry.align  = "center"
    xpEntry.valign = "middle"
    xpEntry:initialise(); xpEntry:instantiate()
    panel:addChild(xpEntry)
    d.xpEntry = xpEntry
    d.actionButtons[#d.actionButtons + 1] = xpEntry

    -- Unparseable falls back to the DEFAULT, deliberately not to 0: a stray
    -- keystroke in this field must never quietly strip everyone's earned XP. The
    -- server re-clamps regardless - this is so the admin acts on a sane number.
    local function xpPercent()
        local v = tonumber(xpEntry:getText())
        if v == nil then return XP_PCT_DEFAULT end
        if v < 0 then v = 0 elseif v > 100 then v = 100 end
        return math.floor(v + 0.5)
    end

    local restoreBtn = DFKit.button(panel, x + PAD + 300, row1Y, 130, "Restore Memoir", panel,
        withSelection("Restore Memoir", Capability.CanModifyPlayerStatsInThePlayerStatsUI, function(names)
            -- Captured at CLICK time so the value the admin just looked at is the
            -- one that gets applied, not whatever the field holds later.
            local pct = xpPercent()
            local function send()
                sendClientCommand(getPlayer(), MODULE, "memoirRestore",
                    { usernames = names, xpPercent = pct })
                notify(string.format("Restore Memoir (%d%% earned XP)", pct), targetLabel(names))
            end
            -- DFConfirm.ask is a fixed 440x180 modal that splits on newlines but
            -- does NOT wrap, so the text has to stay bounded. That rules out
            -- listing ten usernames; the count is the fact that matters and the
            -- selected rows are highlighted in the list behind the dialog.
            local head
            if #names == 1 then
                head = "Restore " .. names[1] .. "'s character from the memoir archive?"
            else
                head = "Restore " .. #names .. " selected characters, each from their OWN archive?"
            end
            local body
            if pct >= 100 then
                body = "Current build and XP are overwritten by that snapshot\n"
                    .. "(anything earned since still adds on top)."
            else
                -- Spell out the floor. "I set 0 and they still have skills" is
                -- otherwise a guaranteed ticket.
                body = string.format("Earned XP restored at %d%%. Profession and trait grants\n", pct)
                    .. "still restore in full, so nobody lands below a fresh\n"
                    .. "spawn of their own build."
            end
            if DFConfirm and DFConfirm.ask then
                DFConfirm.ask(head .. "\n\n" .. body .. "\n\n"
                    .. "Offline / dead / already-recalled players are skipped -\n"
                    .. "per-player results appear in the Console tab.", send)
            else send() end
        end))
    d.actionButtons[#d.actionButtons + 1] = restoreBtn
    d.restoreButton = restoreBtn

    -- Action button row
    local row2Y = row1Y + BTN_H + PAD
    local function mkButton(label, bx, bw, callback, kind)
        local btn = DFKit.button(panel, x + PAD + bx, row2Y, bw, label, panel, callback, kind)
        d.actionButtons[#d.actionButtons + 1] = btn
        return btn
    end
    local function mkAction(label, bx, bw, cap, handler)
        return mkButton(label, bx, bw, withSelected(label, cap, handler))
    end
    local function mkBulkAction(label, bx, bw, cap, handler)
        return mkButton(label, bx, bw, withSelection(label, cap, handler))
    end

    mkAction("Teleport to", 0, 100, Capability.TeleportToPlayer, function(row)
        SendCommandToServer("/teleport " .. quote(row.username))
        notify("Teleport to", row.username)
    end)

    -- BULK-CAPABLE. No batched teleport exists, and these are vanilla chat
    -- commands that bypass DFServer entirely (SendCommandToServer), so the
    -- 20/sec dispatcher limit does not apply - but a loop of chat commands is
    -- still worth capping, and herding an event crowd is the use case, not
    -- teleporting the whole server onto one tile.
    d.bringButton = mkBulkAction("Bring to me", 104, 100,
        Capability.TeleportPlayerToAnotherPlayer, function(names)
            local function send()
                local me   = getPlayer():getUsername()
                local sent = 0
                for _, n in ipairs(names) do
                    if sent >= BULK_MAX then break end
                    SendCommandToServer("/teleportplayer " .. quote(n) .. " " .. quote(me))
                    sent = sent + 1
                end
                notify("Bring to me", targetLabel(names))
                if DFFeedback and #names > 1 then
                    if sent < #names then
                        DFFeedback.bad(string.format(
                            "Brought %d of %d - %d per click is the cap.", sent, #names, BULK_MAX))
                    else
                        DFFeedback.good(string.format("Brought %d players to you.", sent))
                    end
                end
            end
            -- Confirm only for a real bulk teleport; a single bring stays a
            -- one-click action, as it has always been. Count only, for the same
            -- fixed-modal reason as the restore confirm above.
            if #names > 1 and DFConfirm and DFConfirm.ask then
                DFConfirm.ask(string.format(
                    "Teleport %d selected players to your position?", #names), send)
            else send() end
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
    PlayersTab.sel:clear()

    local PAD       = DFKit.metrics.pad
    local BTN_H     = DFKit.metrics.btnH
    local HEADER_H  = DFKit.metrics.headerH
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

    -- Filter changes rebuild the list but must NOT prune: a hidden row stays
    -- selected and comes back when the filter is cleared. refreshDetail then
    -- reports how many of the selection the filter is hiding.
    local origSelect = filterCombo.select
    filterCombo.select = function(self_, ...)
        origSelect(self_, ...)
        rebuildList()
        refreshDetail()
    end

    local refreshBtn = DFKit.button(panel, PAD + 170, cursorY, 90, "Refresh",
        panel, requestSnapshot)

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
    DFKit.well(list)
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
