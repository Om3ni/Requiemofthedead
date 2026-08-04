-- DFScoreboard - ESC scoreboard admin extension.
--
-- The vanilla scoreboard has admin buttons scattered along the bottom edge
-- and several useful actions live only in right-click context menus or in
-- separate admin panels. Per Lore's wishlist (cribbed from ebfadminfix),
-- we:
--   1. Hide vanilla admin buttons.
--   2. Build a single vertical column down the right side, top-anchored to
--      the player list and bottom-anchored just above Refresh.
--   3. Auto-size column width to fit the longest localized label.
--   4. Resize the player list to make room for the column before render.
--   5. Gate every button on its appropriate Capability per click.
--   6. Route vanilla actions through SendCommandToServer (kick, ban, etc.);
--      route medical/stats/inventory through direct ISUI openers.
--   7. Send a parallel "auditOnly" event so other admins see what happened
--      in their Console tab even when the action used a chat command.
--
-- Pattern transcribed from ebfadminfix_scoreboard.lua with Dragonfly-shaped
-- routing on top.

if isServer() then return end

require "OptionScreens/ISScoreboard"
require "ISUI/PlayerStats/ISPlayerStatsUI"
require "ISUI/PlayerStats/ISPlayerStatsManageInvUI"

DFScoreboard = DFScoreboard or { patched = false }

local FONT_HGT_SMALL    = getTextManager():getFontHeight(UIFont.Small)
local SCOREBOARD_PAD    = 16
local SCOREBOARD_GAP    = 10
local BUTTON_MIN_WIDTH  = 180
local LIST_MIN_WIDTH    = 240
local LIST_RIGHT_PAD    = 30
local BUTTON_GAP        = 6   -- vertical spacing between power buttons (tighten to group them)

local function quote(name) return '"' .. tostring(name or "") .. '"' end

local function selectedUsername(sb)
    return sb and sb.selectedPlayer
end

local function selectedIsSelf(sb)
    local name = selectedUsername(sb)
    local me = getPlayer()
    return name and me and name == me:getUsername()
end

local function selectedPlayer(sb)
    local name = selectedUsername(sb)
    return name and getPlayerFromUsername(name) or nil
end

local function hideButton(b)
    if not b then return end
    b.enable = false
    b:setVisible(false)
    b:setX(-10000)
    b:setY(-10000)
end

local function hideVanilla(sb)
    hideButton(sb.kickButton)
    hideButton(sb.banButton)
    hideButton(sb.banIpButton)
    hideButton(sb.godmodButton)
    hideButton(sb.invisibleButton)
    hideButton(sb.teleportButton)
    hideButton(sb.teleportToYouButton)
    hideButton(sb.muteButton)
    hideButton(sb.voipmuteButton)
end

local function makeButton(sb, title, internal)
    local height = math.max(FONT_HGT_SMALL + 6, 25)
    local btn = ISButton:new(0, 0, BUTTON_MIN_WIDTH, height, title, sb, ISScoreboard.onContext)
    btn.internal     = internal
    btn.borderColor.a = 0.3
    btn:setAnchorLeft(false)
    btn:setAnchorRight(true)
    btn:initialise()
    btn:instantiate()
    sb:addChild(btn)
    return btn
end

local function notify(action, target)
    -- Local log + cross-admin broadcast via server auditOnly handler.
    DFLog.push{ source = "Admin", level = "audit",
        text = string.format("%s by %s (target=%s)",
            action, getPlayer():getUsername(), tostring(target or "?")) }
    pcall(sendClientCommand, getPlayer(), "RFTDDragonfly", "auditOnly",   -- Dragonfly-optional: handler lives in DFServer; without the panel mod the send is a no-op
        { action = action, target = target })
end

function DFScoreboard.createButtons(sb)
    if sb.dfButtons then return end
    sb.dfButtons = {
        makeButton(sb, getText("UI_Scoreboard_Kick"),         "DF_KICK"),
        makeButton(sb, getText("UI_Scoreboard_Ban"),          "DF_BAN"),
        makeButton(sb, getText("UI_Scoreboard_Invisible"),    "DF_INVISIBLE"),
        makeButton(sb, getText("UI_Scoreboard_GodMod"),       "DF_GODMODE"),
        makeButton(sb, getText("UI_Scoreboard_Teleport"),     "DF_TELEPORT"),
        makeButton(sb, getText("UI_Scoreboard_TeleportToYou"),"DF_TELEPORTTOYOU"),
        makeButton(sb, getText("UI_Scoreboard_Mute"),         "DF_MUTE"),
        makeButton(sb, getText("UI_Scoreboard_VOIPMute"),     "DF_VOIPMUTE"),
        makeButton(sb, getText("ContextMenu_Medical_Check"),  "DF_MEDICAL"),
        makeButton(sb, "Check Stats",                         "DF_STATS"),
        makeButton(sb, getText("ContextMenu_MoveToInventory"),"DF_INVENTORY"),
    }
    if not getSteamModeActive() then
        table.insert(sb.dfButtons, 3,
            makeButton(sb, getText("UI_Scoreboard_BanIp"), "DF_BANIP"))
    end
end

function DFScoreboard.layout(sb)
    if not sb or not sb.listbox then return end
    hideVanilla(sb)

    local buttons = sb.dfButtons or {}

    -- Measure max width across visible button labels (localization-proof).
    local maxWidth = BUTTON_MIN_WIDTH
    for _, btn in ipairs(buttons) do
        local title = btn:getTitle() or ""
        local w = getTextManager():MeasureStringX(btn.font or UIFont.Small, title) + 28
        if w > maxWidth then maxWidth = w end
    end

    local rightX    = sb.width - SCOREBOARD_PAD - maxWidth
    local listX     = sb.listbox:getX()
    local listWidth = math.max(LIST_MIN_WIDTH,
        rightX - SCOREBOARD_GAP - LIST_RIGHT_PAD - listX)
    sb.listbox:setWidth(listWidth)

    local visible = {}
    for _, btn in ipairs(buttons) do
        if btn:getIsVisible() then visible[#visible + 1] = btn end
    end

    local rowHeight = math.max(FONT_HGT_SMALL + 6, 25)
    local topY = sb.listbox:getY()

    -- Group the buttons with a small fixed gap, clustered at the top of the
    -- column (aligned with the list). Previously the gap was computed to
    -- justify the buttons across the full column height, which spread them
    -- edge-to-edge down the whole screen.
    for index, btn in ipairs(visible) do
        local y = topY + (index - 1) * (rowHeight + BUTTON_GAP)
        btn:setWidth(maxWidth)
        btn:setHeight(rowHeight)
        btn:setX(rightX)
        btn:setY(y)
    end
end

function DFScoreboard.update(sb)
    hideVanilla(sb)
    DFScoreboard.createButtons(sb)

    local me = getPlayer()
    local hasSelection = selectedUsername(sb) ~= nil
    local isSelf = selectedIsSelf(sb)

    -- Start every button hidden+disabled; the per-capability checks below
    -- reveal each one. No "is this an admin" master gate -- this mirrors vanilla
    -- ISScoreboard:doAdminButtons, which gates each button purely on the
    -- viewer's own capability. The old master gate required
    -- CanModifyPlayerStatsInThePlayerStatsUI and hid the whole column from
    -- subordinate roles (e.g. Trusted) that hold Teleport/etc. but not that cap.
    for _, btn in ipairs(sb.dfButtons) do
        btn.enable = false
        btn:setVisible(false)
    end

    -- Per-button capability gating + visibility.
    local function byId(id)
        for _, b in ipairs(sb.dfButtons) do if b.internal == id then return b end end
    end

    local pairsCap = {
        DF_KICK          = Capability.KickUser,
        DF_BAN           = Capability.BanUnbanUser,
        DF_BANIP         = Capability.BanUnbanUser,
        DF_TELEPORT      = Capability.TeleportToPlayer,
        DF_TELEPORTTOYOU = Capability.TeleportPlayerToAnotherPlayer,
        DF_MEDICAL       = Capability.CanMedicalCheat,
        DF_STATS         = Capability.CanSeePlayersStats,
        DF_INVENTORY     = Capability.InspectPlayerInventory,
    }
    local anyCap = false
    for id, cap in pairs(pairsCap) do
        local btn = byId(id)
        if btn then
            local has = RDAccess.roleHas(me, cap)
            btn:setVisible(has)
            if has then anyCap = true end
        end
    end

    -- Invisible toggle uses either self-only or everyone cap.
    local invBtn = byId("DF_INVISIBLE")
    local canInvis = RDAccess.roleHas(me, Capability.ToggleInvisibleEveryone)
        or RDAccess.roleHas(me, Capability.ToggleInvisibleHimself)
    if invBtn then
        invBtn:setVisible(canInvis)
        if canInvis then anyCap = true end
    end

    -- God-mode toggle, same self-only / everyone capability split as invisible.
    local godBtn = byId("DF_GODMODE")
    local canGod = RDAccess.roleHas(me, Capability.ToggleGodModEveryone)
        or RDAccess.roleHas(me, Capability.ToggleGodModHimself)
    if godBtn then
        godBtn:setVisible(canGod)
        if canGod then anyCap = true end
    end

    -- Mute / VOIP mute have no capability of their own (local actions). Show
    -- them only when the viewer already holds at least one admin capability,
    -- so the column doesn't sprout for ordinary players.
    local muteBtn = byId("DF_MUTE")
    local voipBtn = byId("DF_VOIPMUTE")
    if muteBtn then muteBtn:setVisible(anyCap) end
    if voipBtn then voipBtn:setVisible(anyCap) end

    if not hasSelection then DFScoreboard.layout(sb); return end

    -- Enable rules per button (with selection).
    for id, _ in pairs(pairsCap) do
        local btn = byId(id)
        if btn then btn.enable = btn:getIsVisible() and not isSelf end
    end
    -- Stats and Inventory may target self.
    local statsBtn = byId("DF_STATS")
    if statsBtn then statsBtn.enable = statsBtn:getIsVisible() end
    local invBtnTarget = byId("DF_INVENTORY")
    if invBtnTarget then invBtnTarget.enable = invBtnTarget:getIsVisible() end

    -- Invisible: self uses self cap, others use everyone cap.
    if invBtn then
        invBtn.enable = isSelf
            and RDAccess.roleHas(me, Capability.ToggleInvisibleHimself)
            or (not isSelf and RDAccess.roleHas(me, Capability.ToggleInvisibleEveryone))
    end

    -- God mode: self uses self cap, others use everyone cap.
    if godBtn then
        godBtn.enable = isSelf
            and RDAccess.roleHas(me, Capability.ToggleGodModHimself)
            or (not isSelf and RDAccess.roleHas(me, Capability.ToggleGodModEveryone))
    end

    -- Mute / VOIP mute enable + toggle labels reflect current state. (muteBtn /
    -- voipBtn were resolved above with the visibility pass.)
    if muteBtn then
        muteBtn.enable = muteBtn:getIsVisible() and not isSelf
        local muted = ISChat.instance and ISChat.instance:isMuted(selectedUsername(sb))
        muteBtn:setTitle(muted
            and getText("UI_Scoreboard_Unmute")
            or  getText("UI_Scoreboard_Mute"))
    end
    if voipBtn then
        voipBtn.enable = voipBtn:getIsVisible() and not isSelf
        local muted = VoiceManager and VoiceManager:playerGetMute(selectedUsername(sb))
        voipBtn:setTitle(muted
            and getText("UI_Scoreboard_VOIPUnmute")
            or  getText("UI_Scoreboard_VOIPMute"))
    end

    DFScoreboard.layout(sb)
end

-- Direct openers for medical/stats/inventory (vanilla has no chat command).

function DFScoreboard.openMedicalCheck(sb)
    local target = selectedPlayer(sb)
    if not target then
        if DFFeedback then DFFeedback.bad("Medical check target is not loaded.") end
        return
    end
    DFMedicalCheck.performAdmin(getPlayer(), target)
    notify("Medical Check", selectedUsername(sb))
end

function DFScoreboard.openStats(sb)
    local target = selectedPlayer(sb)
    if not target then
        if DFFeedback then DFFeedback.bad("Stats target is not loaded.") end
        return
    end
    if ISPlayerStatsUI.instance then ISPlayerStatsUI.instance:close() end
    local modal = ISPlayerStatsUI:new(50, 50,
        800 + (getCore():getOptionFontSizeReal() * 50), 800, target, getPlayer())
    modal:initialise()
    modal:addToUIManager()
    modal:setVisible(true)
    notify("Check Stats", selectedUsername(sb))
end

function DFScoreboard.openInventory(sb)
    local name = selectedUsername(sb)
    if not name then return end
    local target = getPlayerFromUsername(name)
    local playerID = target and target:getOnlineID() or -1
    if ISPlayerStatsManageInvUI.instance then ISPlayerStatsManageInvUI.Close() end
    local modal = ISPlayerStatsManageInvUI:new(50, 50, 900, 650, playerID, name)
    modal:initialise()
    modal:addToUIManager()
    notify("Inventory Inspect", name)
end

-- One-time patch of ISScoreboard. Save references to vanilla methods so
-- our wrappers can defer to them, then redefine.

if not DFScoreboard.patched then
    DFScoreboard.patched = true

    DFScoreboard.vanillaCreate    = ISScoreboard.create
    DFScoreboard.vanillaPrerender = ISScoreboard.prerender
    DFScoreboard.vanillaDrawMap   = ISScoreboard.drawMap
    DFScoreboard.vanillaFillList  = ISScoreboard.fillList
    DFScoreboard.vanillaOnContext = ISScoreboard.onContext

    function ISScoreboard:create()
        DFScoreboard.vanillaCreate(self)
        hideVanilla(self)
        DFScoreboard.createButtons(self)
        DFScoreboard.update(self)
    end

    function ISScoreboard:prerender()
        DFScoreboard.update(self)
        return DFScoreboard.vanillaPrerender(self)
    end

    function ISScoreboard:fillList(usernames, displayNames, steamIDs)
        self.maxNameWid = 0
        -- DFKit.refillList: a bare clear() leaves the scroll height behind and
        -- addItem stacks onto it. This list refills on every join and leave, so
        -- on a busy server the phantom height climbs all session. See that
        -- function's header.
        DFKit.refillList(self.listbox, function(box)
            for i = 0, usernames:size() - 1 do
                local username = usernames:get(i)
                local displayName = displayNames:get(i)
                local data = { username = username, displayName = displayName }
                if getSteamModeActive() then
                    data.steamID = steamIDs:get(i)
                    data.profileName = getSteamProfileNameFromSteamID(data.steamID)
                    data.avatar      = getSteamAvatarFromSteamID(data.steamID)
                end
                local item = box:addItem(displayName, data)
                if ISScoreboard.isAdmin and username ~= displayName then
                    item.tooltip = username
                end
                local tw = getTextManager():MeasureStringX(UIFont.Large, displayName)
                if tw > self.maxNameWid then self.maxNameWid = tw end
            end
        end)
        table.sort(self.listbox.items, function(a, b)
            return not string.sort(a.text, b.text)
        end)
    end

    function ISScoreboard:drawMap(y, item, alt)
        if self.selected == item.index and item.item and item.item.username then
            self.parent.selectedPlayer = item.text
        end
        local result = DFScoreboard.vanillaDrawMap(self, y, item, alt)
        if self.selected == item.index and item.item and item.item.username then
            self.parent.selectedPlayer            = item.item.username
            self.parent.selectedPlayerDisplayName = item.item.displayName or item.text
            DFScoreboard.update(self.parent)
        end
        return result
    end

    function ISScoreboard:onContext(button)
        local name = selectedUsername(self)
        if not name then return end
        local quoted = quote(name)
        local internal = button and button.internal or ""

        if     internal == "DF_KICK"          then
            SendCommandToServer("/kickuser "      .. quoted); notify("Kick", name)
        elseif internal == "DF_BAN"           then
            SendCommandToServer("/banuser "       .. quoted); notify("Ban", name)
        elseif internal == "DF_BANIP"         then
            SendCommandToServer("/banuser "       .. quoted .. " -ip"); notify("Ban IP", name)
        elseif internal == "DF_INVISIBLE"     then
            SendCommandToServer("/invisibleplayer " .. quoted); notify("Invisible", name)
        elseif internal == "DF_GODMODE"       then
            SendCommandToServer("/godmodplayer " .. quoted); notify("God Mode", name)
        elseif internal == "DF_TELEPORT"      then
            SendCommandToServer("/teleport "      .. quoted); notify("Teleport to", name)
        elseif internal == "DF_TELEPORTTOYOU" then
            SendCommandToServer("/teleportplayer "
                .. quoted .. " \"" .. getPlayer():getUsername() .. "\"")
            notify("Teleport to you", name)
        elseif internal == "DF_MUTE" then
            if ISChat.instance then ISChat.instance:mute(name) end
            notify("Mute", name); DFScoreboard.update(self)
        elseif internal == "DF_VOIPMUTE" then
            if VoiceManager then VoiceManager:playerSetMute(name) end
            notify("VOIP mute", name); DFScoreboard.update(self)
        elseif internal == "DF_MEDICAL"   then DFScoreboard.openMedicalCheck(self)
        elseif internal == "DF_STATS"     then DFScoreboard.openStats(self)
        elseif internal == "DF_INVENTORY" then DFScoreboard.openInventory(self)
        else
            return DFScoreboard.vanillaOnContext(self, button)
        end
    end
end
