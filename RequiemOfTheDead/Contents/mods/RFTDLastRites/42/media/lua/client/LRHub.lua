-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRHub.lua  (client)
--
-- Last Rites settings hub: an extensible tabbed window opened from the
-- vanilla Client (UserPanel) button. This file owns ONLY the shell - it has
-- no knowledge of any specific feature.
--
-- Features add themselves with one call at load time:
--     LRHub.registerSection{ id = "danger", title = "Danger", fill = function(view) ... end }
-- `fill(view)` receives the tab body (an ISPanel) and populates it with
-- controls. The window rebuilds its tabs from the registry every time it
-- opens, so a section registered by any later-loading file still appears.

require "RDShared"   -- explicit: file-scope RD* use must not ride on load order (see MMSvShared header)

RDShared.registerMod("RFTDLastRites", "1.2.1")   -- keep in sync with mod.info

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTabPanel"
require "ISUI/ISPanel"

LRHub = LRHub or {}
LRHub.sections = LRHub.sections or {}

-- Register (or replace, by id) a settings tab. Re-registering the same id
-- replaces the old entry so a reloaded feature file never double-adds.
function LRHub.registerSection(def)
    if not def or not def.id or not def.fill then return end
    for i = 1, #LRHub.sections do
        if LRHub.sections[i].id == def.id then
            LRHub.sections[i] = def
            return
        end
    end
    LRHub.sections[#LRHub.sections + 1] = def
end

-- ── Window ────────────────────────────────────────────────
local WIN_W = 480
local WIN_H = 380
local PAD   = 8

local LRHubWindow = ISCollapsableWindow:derive("LRHubWindow")

local function makeTabBody(w, h)
    local view = ISPanel:new(0, 0, w, h)
    view.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    view.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
    view:initialise()
    return view
end

function LRHubWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local top = self:titleBarHeight() + PAD
    local w   = self.width  - PAD * 2
    local h   = self.height - top - PAD

    local tabs = ISTabPanel:new(PAD, top, w, h)
    tabs:initialise()
    self:addChild(tabs)
    self.tabs = tabs

    local bodyH = h - tabs.tabHeight

    -- No features registered yet: show a single placeholder tab.
    if #LRHub.sections == 0 then
        local view = makeTabBody(w, bodyH)
        view.render = function(v)
            v:drawTextCentre(getText("IGUI_LR_NoOptions"),
                v.width / 2, v.height / 2 - 8, 0.7, 0.7, 0.7, 1, UIFont.Small)
        end
        tabs:addView(getText("IGUI_LR_Panel"), view)
        return
    end

    -- One tab per registered section. A failing fill() is isolated so one
    -- broken feature can't take down the whole hub.
    for i = 1, #LRHub.sections do
        local section = LRHub.sections[i]
        local view = makeTabBody(w, bodyH)
        local ok, err = pcall(section.fill, view)
        if not ok then
            print("[LRHub] section '" .. tostring(section.id) .. "' fill() error: " .. tostring(err))
        end
        tabs:addView(section.title or section.id, view)
    end
end

function LRHubWindow:close()
    ISCollapsableWindow.close(self)
    LRHubWindow.instance = nil
end

-- ── Public open/close ─────────────────────────────────────
function LRHub.toggle(player)
    if LRHubWindow.instance then
        LRHubWindow.instance:close()
        return
    end
    local sw  = getCore():getScreenWidth()
    local sh  = getCore():getScreenHeight()
    local win = LRHubWindow:new((sw - WIN_W) / 2, (sh - WIN_H) / 2, WIN_W, WIN_H)
    win.player = player
    win:setResizable(false)
    win:setTitle(getText("IGUI_LR_PanelTitle"))
    win:initialise()
    win:addToUIManager()
    LRHubWindow.instance = win
end

-- Exposed for inspection / future direct access.
LRHub.window = LRHubWindow

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
