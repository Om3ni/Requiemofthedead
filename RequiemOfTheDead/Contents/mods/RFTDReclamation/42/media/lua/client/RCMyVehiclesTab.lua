-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCMyVehiclesTab - My Vehicles on the player panel: the merged inspector
-- (client).
--
-- THE MERGE (owner, 2026-08-13). Two surfaces existed for one question asked
-- at two privilege levels: RCMyVehicles (the player's fleet window - list,
-- catalogue portrait, location, release) and RCVehicleTab (the admin
-- inspector - the parts diagram tinted by real condition, the per-part
-- breakdown, and the powers). Players deserved the inspector's EYES - "what
-- does my car look like right now, without standing in front of it" - and
-- none of its HANDS. So this tab is both halves' viewer glued together:
--
--   FROM RCMyVehicles   the claims list (registry slice, own cars only),
--                       the 3D catalogue portrait ("which car is this" -
--                       it renders showroom-fresh from the script name, so
--                       it works even for an UNLOADED car), location, live
--                       distance, Manage Access, Release.
--   FROM RCVehicleTab   the mechanic-overlay diagram and the grouped parts
--                       breakdown (both via RCPartsView, the shared
--                       implementation - drawBreakdown moved there so the
--                       two panels cannot drift), telling the truth about
--                       condition when the car is loaded ANYWHERE on the
--                       server - not just in this client's bubble.
--   FROM NEITHER        teleport, delete, spawn, and the right-click cheat
--                       surfaces (RCVehicleCheats) are absent by
--                       construction, not greyed: nothing here sends a
--                       mutating command except releaseclaim and the access
--                       manager, both of which were always player verbs.
--
-- AUTHORITY. The list is the server's registry slice ("myvehicles"), parts
-- come back through "myvehicleparts" - a claimId-keyed request the server
-- resolves through RCRegistry.owns, so ownership is the gate and the vid
-- never comes from this client (see hMyVehicleParts). An unloaded car has no
-- object to read anywhere, so its diagram pane says so and the portrait
-- carries the "what does it look like" question alone.
--
-- LAYOUT. List left; middle column is portrait over info over the parts
-- breakdown, with the player verbs at the bottom; the diagram takes a tall
-- right column - portrait art in a portrait pane (see the dead-end note in
-- RCPartsView about rotating it). Below MIN_FOR_DIAG width the diagram
-- column folds away rather than shrinking into an unreadable sliver; the
-- breakdown still tells the whole truth in numbers.
--
-- Fonts read through DFKit at draw time, so the text-size preference applies
-- on the next rebuild (the player deck rebuilds its active tab on a tier
-- change) without this file keeping a listener of its own.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "DFKit"
require "DFScroll"
require "RCMyVehicles"   -- prettyName - one spelling of a car's name, not two
require "RCPartsView"

RCMyVehiclesTab = RCMyVehiclesTab or {}
local T = RCMyVehiclesTab

local M = RCShared.MODULE

local PAD          = 8
local BTN_H        = 24
local LIST_W       = 185
local PREVIEW_H    = 180
local DIAG_W       = 210
local MIN_FOR_DIAG = 640   -- below this the diagram column folds away

-- Scroll state for the breakdown grid; module-level because the grid redraws
-- from scratch every frame and the offset must outlive both the frame and a
-- deck resize rebuild.
T.partsScroll = T.partsScroll or DFScroll.new()

local function fS() return DFKit.font.small or UIFont.Small end
local function fT() return DFKit.font.title or UIFont.Medium end

local function pretty(name) return RCMyVehicles.prettyName(name) end

-- ---------------------------------------------------------------------------
-- The inspector pane: everything right of the list is one drawn child. Its
-- prerender paints info, diagram and breakdown; its mouse handlers exist only
-- to lend the wheel and the bar to the breakdown's scroll.
-- ---------------------------------------------------------------------------
local Inspector = ISPanel:derive("RCMyVehiclesInspector")

function Inspector:prerender()
    ISPanel.prerender(self)
    T.drawInspector(self)
end

function Inspector:onMouseWheel(del)
    local p = T.partsRect
    if p then
        local mx, my = self:getMouseX(), self:getMouseY()
        if mx >= p.x and mx < p.x + p.w and my >= p.y and my < p.y + p.h then
            return T.partsScroll:wheel(del)
        end
    end
    return false
end

function Inspector:onMouseDown(x, y)
    if T.partsScroll:press(x, y) then
        self.scrollGrab = true
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function Inspector:onMouseMove(dx, dy)
    if self.scrollGrab and T.partsScroll:drag(self:getMouseY()) then return end
    return ISPanel.onMouseMove(self, dx, dy)
end

function Inspector:onMouseMoveOutside(dx, dy)
    if self.scrollGrab and T.partsScroll:drag(self:getMouseY()) then return end
    return ISPanel.onMouseMoveOutside(self, dx, dy)
end

function Inspector:onMouseUp(x, y)
    self:setCapture(false)
    if self.scrollGrab then
        self.scrollGrab = false
        -- Releasing a scrollbar drag is not a click on whatever row is now
        -- under the cursor - the rows moved while the thumb was moving.
        if T.partsScroll:release() then return end
    end
    -- A click on a part row opens the Workshop, narrowed to that part. Rows
    -- whose slot accepts no item (structural parts) do nothing rather than
    -- opening an empty crafting list.
    local hits = T.partHits
    if hits then
        for i = 1, #hits do
            local r = hits[i]
            if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
                T.openWorkshop(r.rec)
                return
            end
        end
    end
    return ISPanel.onMouseUp(self, x, y)
end

function Inspector:onMouseUpOutside(x, y)
    self:setCapture(false)
    self.scrollGrab = false
    T.partsScroll:release()
    return ISPanel.onMouseUpOutside(self, x, y)
end

-- ---------------------------------------------------------------------------
-- Layout. One function, called by build and by the deck's live resize hook,
-- so a drag reflows in place without throwing the selection away.
-- ---------------------------------------------------------------------------
local function layout(panel, w, h)
    local by    = h - BTN_H - PAD
    local listH = by - PAD * 2

    T.listBox:setX(PAD); T.listBox:setY(PAD)
    T.listBox:setWidth(LIST_W); T.listBox:setHeight(listH)
    T.btnRefresh:setX(PAD); T.btnRefresh:setY(by); T.btnRefresh:setWidth(LIST_W)

    local midX  = PAD * 2 + LIST_W
    local insW  = w - midX - PAD
    local diagW = (w >= MIN_FOR_DIAG) and DIAG_W or 0
    local midW  = insW - (diagW > 0 and (diagW + PAD) or 0)

    T.inspector:setX(midX); T.inspector:setY(PAD)
    T.inspector:setWidth(insW); T.inspector:setHeight(listH)

    -- The portrait gives ground before anything else does: at the deck's
    -- minimum height a fixed 180px picture would push the info block into the
    -- buttons, and the picture is the one element that degrades gracefully.
    local prevH = math.min(PREVIEW_H, math.max(100, math.floor(listH * 0.4)))

    -- The portrait is a sibling widget, not drawn chrome; it occupies the top
    -- of the middle column and the inspector simply does not paint there.
    if T.preview then
        T.preview:setX(midX); T.preview:setY(PAD)
        T.preview:setWidth(midW); T.preview:setHeight(prevH)
    end

    -- Inspector-local rects. Info height is measured from the fonts it will
    -- be drawn with: a title line plus six body lines (location, distance,
    -- status, engine, claim, the workshop hint) plus breathing room.
    local fhS = getTextManager():getFontHeight(fS())
    local fhT = getTextManager():getFontHeight(fT())
    local infoH = fhT + 4 + 6 * (fhS + 3) + 8

    T.infoRect  = { x = 0, y = prevH + 8, w = midW, h = infoH }
    T.partsRect = { x = 0, y = prevH + 8 + infoH, w = midW,
                    h = listH - prevH - 8 - infoH }
    T.diagRect  = (diagW > 0)
        and { x = insW - diagW, y = 0, w = diagW, h = listH }
        or nil

    local halfW = math.floor((midW - PAD) / 2)
    T.btnManage:setX(midX); T.btnManage:setY(by); T.btnManage:setWidth(halfW)
    T.btnRelease:setX(midX + halfW + PAD); T.btnRelease:setY(by); T.btnRelease:setWidth(halfW)
end

-- ---------------------------------------------------------------------------
-- Data: request, receive, select
-- ---------------------------------------------------------------------------
function T.request()
    -- Refresh means refresh: the parts cache is per-session and nothing else
    -- ever invalidates it for a car this player is not editing, so without
    -- this a remote car's diagram would show the condition it had the first
    -- time it was ever looked at. Clearing all of it is fine - it refills on
    -- demand, one request per car actually looked at.
    if RCPartsView.invalidate then RCPartsView.invalidate() end
    pcall(function() sendClientCommand(getPlayer(), M, "myvehicles", {}) end)
end

function T.setList(list)
    if not T.listBox then return end
    T.rows = {}
    DFKit.refillList(T.listBox, function(box)
        if type(list) ~= "table" then return end
        table.sort(list, function(a, b) return pretty(a.name) < pretty(b.name) end)
        for _, rec in ipairs(list) do
            -- The adapter: RCPartsView speaks fleet-row (script/mine), the
            -- slice speaks registry (name/claimId). Bridge here, once.
            rec.script = rec.name
            rec.mine   = true
            T.rows[#T.rows + 1] = rec
            box:addItem(pretty(rec.name), rec)
        end
    end)
    if #T.rows == 0 then
        T.listBox.selected = 0
    elseif T.listBox.selected == nil or T.listBox.selected < 1 or T.listBox.selected > #T.rows then
        T.listBox.selected = 1
    end
    T.shownSel = -1   -- force a selection refresh next prerender
end

local function updateSelection()
    local sel  = T.listBox and T.listBox.selected
    local item = sel and T.listBox.items[sel]
    T.selRec = item and item.item or nil

    if T.preview then
        local script = T.selRec and T.selRec.name or ""
        pcall(function() T.preview.javaObject:fromLua2("setVehicleScript", "rcPreview", script or "") end)
    end
    T.partsScroll:reset()
    if T.btnRelease then T.btnRelease:setEnable(T.selRec ~= nil) end
    if T.btnManage then T.btnManage:setEnable(T.selRec ~= nil and T.selRec.loaded == true) end
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------
function T.drawInspector(el)
    if T.listBox and T.listBox.selected ~= T.shownSel then
        T.shownSel = T.listBox.selected
        updateSelection()
    end

    local C = DFKit.col
    local i = T.infoRect
    if not i then return end

    if not T.rows or #T.rows == 0 then
        -- Below the portrait widget, which is a sibling drawn over this pane -
        -- text under it would simply not be seen.
        el:drawText(getText("IGUI_RC_MV_None"), i.x, i.y, C.textDim.r, C.textDim.g, C.textDim.b, 1, fS())
        return
    end

    local rec = T.selRec
    if not rec then return end

    local fhS = getTextManager():getFontHeight(fS())
    local y   = i.y

    el:drawText(pretty(rec.name), i.x, y, C.text.r, C.text.g, C.text.b, 1, fT())
    y = y + getTextManager():getFontHeight(fT()) + 4

    local function line(txt, r, g, b)
        el:drawText(txt, i.x, y, r, g, b, 1, fS())
        y = y + fhS + 3
    end

    line(string.format("%s: %d, %d, %d", getText("IGUI_RC_MV_Location"),
        rec.x or 0, rec.y or 0, rec.z or 0), C.text.r, C.text.g, C.text.b)

    local p = getPlayer()
    if p and rec.x then
        local dx = p:getX() - rec.x
        local dy = p:getY() - rec.y
        local dist = math.floor(math.sqrt(dx * dx + dy * dy))
        line(string.format("%s: %d %s", getText("IGUI_RC_MV_Distance"), dist,
            getText("IGUI_RC_MV_Tiles")), C.text.r, C.text.g, C.text.b)
    end

    if rec.loaded then
        line(getText("IGUI_RC_MV_InRange"), C.ok.r, C.ok.g, C.ok.b)
    else
        line(getText("IGUI_RC_OutOfRange"), C.warn.r, C.warn.g, C.warn.b)
    end

    -- Engine, the one-glance summary - only a loaded car reports one, and a
    -- line that reads "Engine: ?" would imply the server failed rather than
    -- the car being away.
    if rec.engine then
        local col = C.ok
        if rec.engine < 30 then col = C.danger elseif rec.engine < 65 then col = C.warn end
        line("Engine: " .. tostring(rec.engine) .. "%", col.r, col.g, col.b)
    end

    line(getText("IGUI_RC_MV_ClaimId") .. ": " .. tostring(rec.claimId),
        C.textDim.r, C.textDim.g, C.textDim.b)

    -- Only when there are part rows to click: a hint pointing at rows that
    -- are not there is worse than none.
    if rec.loaded then
        line(getText("IGUI_RC_WS_Hint"), C.textDim.r, C.textDim.g, C.textDim.b)
    end

    -- The truth-telling half: diagram right, breakdown under the info. Both
    -- show their own "unloaded" empties on loaded=false. noHit on the
    -- diagram: this surface has no right-click, and writing the shared
    -- hit-test slot would misdirect the admin panel's (see RCPartsView.draw).
    if T.diagRect then
        RCPartsView.draw(el, T.diagRect, rec, true)
    end
    -- The hit rows feed the part-click below: a row whose slot accepts items
    -- is a door into the Workshop tab, pre-filtered to that part on this car.
    T.partHits = RCPartsView.drawBreakdown(el, T.partsRect, rec, T.partsScroll)
end

-- ---------------------------------------------------------------------------
-- The Workshop door. Hands the clicked part to RCWorkshopTab and asks the
-- registry - never the shell directly - to land the panel there. Silently a
-- no-op for a part whose slot accepts no item, and when the Workshop tab is
-- not installed.
-- ---------------------------------------------------------------------------
function T.openWorkshop(partRec)
    if not (partRec and partRec.items and #partRec.items > 0) then return end
    if not (RCWorkshopTab and RCWorkshopTab.setTarget) then return end
    local veh = T.selRec and pretty(T.selRec.name) or "?"
    RCWorkshopTab.setTarget(veh, partRec)
    if DFPlayerRegistry and DFPlayerRegistry.requestShow then
        DFPlayerRegistry.requestShow("rc_workshop")
    end
end

-- ---------------------------------------------------------------------------
-- Player verbs - the only commands this tab can emit
-- ---------------------------------------------------------------------------
function T.onManage()
    local rec = T.selRec
    if not rec or not rec.loaded then return end
    if RCClaimGUI and RCClaimGUI.openForClaim then
        RCClaimGUI.openForClaim(rec.claimId,
            { allowed = rec.allowed, public = rec.public, loaded = rec.loaded },
            getPlayer())
    end
end

function T.onRelease()
    local rec = T.selRec
    if not rec then return end
    local w, h = 340, 130
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h,
        getText("IGUI_RC_MV_ConfirmRelease"), true, T, T.onReleaseConfirm, nil, rec.claimId)
    modal:initialise()
    modal:addToUIManager()
end

-- Colon on purpose: ISModalDialog invokes onclick(target, button, param1),
-- and the dot form would receive the target AS `button`.
function T:onReleaseConfirm(button, claimId)
    if button.internal ~= "YES" then return end
    if not claimId then return end
    pcall(function() sendClientCommand(getPlayer(), M, "releaseclaim", { claimId = claimId }) end)
    -- the server pushes a fresh slice back after processing; nothing else to do
end

-- ---------------------------------------------------------------------------
-- Build / resize - the player deck's tab contract
-- ---------------------------------------------------------------------------
function T.build(spec, panel, x, y, w, h)
    -- A previous build's scene may outlive its parent's removal (belt and
    -- braces, same as RCMyVehicles:close).
    if T.preview then
        pcall(function() T.preview:removeFromUIManager() end)
        T.preview = nil
    end

    T.host = panel
    T.rows = {}
    T.selRec = nil
    T.shownSel = -1

    T.listBox = ISScrollingListBox:new(0, 0, 10, 10)
    T.listBox:initialise()
    T.listBox.itemheight = getTextManager():getFontHeight(fS()) + 8
    T.listBox.font = fS()
    T.listBox.drawBorder = true
    panel:addChild(T.listBox)

    T.inspector = Inspector:new(0, 0, 10, 10)
    T.inspector.background = false
    T.inspector:initialise()
    T.inspector:instantiate()
    panel:addChild(T.inspector)

    -- 3D portrait, guarded exactly as RCMyVehicles guards it: if the scene
    -- element is unavailable the tab still works, minus the picture.
    local ok = pcall(function()
        T.preview = ISUI3DScene:new(0, 0, 10, PREVIEW_H)
        T.preview:initialise()
        T.preview:instantiate()
        T.preview:setView("Right")
        -- Frame low to fit the biggest vehicles; mouse-wheel zooms in.
        T.preview.javaObject:fromLua1("setZoom", 2)
        T.preview.javaObject:fromLua1("setDrawGrid", false)
        T.preview.javaObject:fromLua1("createVehicle", "rcPreview")
        panel:addChild(T.preview)
    end)
    if not ok then T.preview = nil end

    T.btnRefresh = ISButton:new(0, 0, 10, BTN_H, getText("IGUI_RC_MV_Refresh"), T, T.request)
    T.btnRefresh:initialise(); panel:addChild(T.btnRefresh)

    T.btnManage = ISButton:new(0, 0, 10, BTN_H, getText("IGUI_RC_Manage"), T, T.onManage)
    T.btnManage:initialise(); panel:addChild(T.btnManage)
    T.btnManage:setEnable(false)

    T.btnRelease = ISButton:new(0, 0, 10, BTN_H, getText("IGUI_RC_MV_Release"), T, T.onRelease)
    T.btnRelease:initialise(); panel:addChild(T.btnRelease)
    T.btnRelease:setEnable(false)

    layout(panel, w, h)
    T.request()
end

function T.resize(spec, panel, w, h)
    if panel ~= T.host or not T.listBox then return end
    layout(panel, w, h)
end

-- ---------------------------------------------------------------------------
-- The slice lands here. The window (RCMyVehicles) keeps its own listener;
-- each guards on its own surface, so both doors stay current when both are
-- somehow open.
-- ---------------------------------------------------------------------------
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M or command ~= "MyVehicles" then return end
    if not (T.host and T.listBox) then return end
    T.setList(args and args.list or {})
end)

-- ---------------------------------------------------------------------------
-- Registration: the reserved slot, now occupied (the placeholder lived in
-- RCMyVehicles.lua until this file existed).
-- ---------------------------------------------------------------------------
Events.OnGameBoot.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerTab) then return end
    Dragonfly.registerPlayerTab{
        id     = "rc_myvehicles",
        label  = getText("IGUI_RC_MyVehiclesTitle"),
        order  = 20,
        build  = T.build,
        resize = T.resize,
    }
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
