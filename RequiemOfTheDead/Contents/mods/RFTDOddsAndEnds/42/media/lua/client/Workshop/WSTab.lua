-- SPDX-License-Identifier: GPL-3.0-or-later
-- WSTab - the Workshop: the player panel's crafting home (client).
--
-- MOVED TO ODDS & ENDS 2026-08-08 (owner: "the only thing Reclamation should
-- own is ITS panel"). The Workshop was born in Reclamation as a door from
-- vehicle parts into crafting, then grew Gear and Journal the same afternoon
-- - and the moment it learned to serve belts and magazines it stopped being
-- vehicle domain. It now follows the family's own rule: general surfaces
-- live in a general home, domain mods keep a guarded door. Reclamation's My
-- Vehicles calls WSTab.openFor(itemTypes, label) and degrades silently when
-- this module is absent or killed, exactly as every consumer degrades
-- without Dragonfly.
--
-- Three rooms under one roof:
--   CRAFT   - vanilla's own B42 handcraft panel (ISHandCraftPanel) embedded
--             whole: ingredients, skills, craft-surface hunt and the craft
--             action are all engine-side, so recipes from any mod are picked
--             up the day they load. A filter can narrow it to one target.
--   GEAR    - carried/equipped/hotbar items the Workshop can help with:
--             condition, fixability, replacement recipes (WSGear).
--   JOURNAL - the whole recipe catalogue, searchable, white = known / grey =
--             unknown with its learning paths (WSJournal).
--
-- ROUTING IS THE CONTRACT: every door into the Workshop lands on the room
-- that can actually serve it. A target with recipes the player KNOWS lands
-- on Craft, filtered to them; one whose recipes are all unlearned lands on
-- the Journal pinned to those recipes - grey rows, each showing how to learn
-- it; no recipes at all lands on Craft with an honest zero. Doors run under
-- pcall - a routing bug costs one console line, never a stack trace.
--
-- THE FILTER IS EXACT, NOT NAME-MATCHING: recipes qualify by their OUTPUTS
-- landing in the target's accepted-item set (WSIndex.byOutput). Mod-agnostic
-- by construction: the recipes this was built around live in third-party
-- mods (RQD Tweaker's refurbish set), the covenant on that suite is lessons
-- only, never code, and nothing here reads their files - only what is
-- LOADED.
--
-- THE STICKY-FILTER OVERRIDE, the one piece of surgery on the vanilla panel:
-- ISHandCraftPanel re-derives its recipe list whenever the player's container
-- set changes (refreshRecipeList - walk away, open a bag, list resets), which
-- would silently stomp the injected filter. The INSTANCE gets a
-- refreshRecipeList that re-applies the filter list in that same moment and
-- falls through to vanilla behaviour when no filter is set. Instance
-- override, never a class patch - the B-key handcraft window must keep
-- vanilla behaviour untouched.
--
-- No target set shows the vanilla hand-craft catalogue - the same
-- "InHandCraft;AnySurfaceCraft" tag query the B-key window uses.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "OEShared"
require "DFKit"
require "Workshop/WSIndex"
require "Workshop/WSGear"
require "Workshop/WSJournal"

WSTab = WSTab or {}
local T = WSTab

local TAB_ID   = "ws_workshop"
local SUB_H    = 28
local HEADER_H = 30
local PAD      = 8

-- Same tag set the vanilla B-key handcraft window queries; the catalogue
-- fallback must be the list players already know, not a third variant.
local CATALOGUE_QUERY = "InHandCraft;AnySurfaceCraft"

local function fS() return DFKit.font.small or UIFont.Small end

-- ---------------------------------------------------------------------------
-- Target resolution: an accepted-item set -> recipes, split by known-ness.
-- ---------------------------------------------------------------------------
local function splitRecipes(fullTypes)
    local player = getPlayer()
    local known, unknown, seen = {}, {}, {}
    for _, fn in ipairs(fullTypes or {}) do
        for _, rec in ipairs(WSIndex.forOutput(fn)) do
            if not seen[rec.name] then
                seen[rec.name] = true
                if player and WSIndex.known(player, rec) then
                    known[#known + 1] = rec
                else
                    unknown[#unknown + 1] = rec
                end
            end
        end
    end
    return known, unknown
end

local function toArrayList(recs)
    local list = ArrayList.new()
    for _, rec in ipairs(recs) do list:add(rec.r) end
    return list
end

-- ---------------------------------------------------------------------------
-- The doors. Each remembers its state on T, because the target and the
-- active room OUTLIVE the tab - the deck rebuilds content on every visit.
-- ---------------------------------------------------------------------------

-- Narrow the Craft room to an explicit recipe set and land on it.
-- extraLearnable rides into the header as the Journal hint.
function T.openCraft(recs, label, extraLearnable)
    T.filterList = toArrayList(recs)
    T.target = {
        label     = tostring(label or "?"),
        count     = #recs,
        learnable = extraLearnable or 0,
    }
    if T.craft then
        pcall(function() T.craft:refreshRecipeList(true) end)
    end
    T.showSub("craft")
end

-- Pin the Journal to a recipe set (the unlearned half of a click).
function T.openJournal(recs, label)
    local names = {}
    for _, rec in ipairs(recs) do names[#names + 1] = rec.name end
    WSJournal.setPin(names, label)
    T.showSub("journal")
end

-- The routing rule every door shares: known -> Craft (with the learnable
-- count as a header hint), none known but some learnable -> Journal,
-- nothing at all -> false (caller decides).
local function route(fullTypes, label)
    local known, unknown = splitRecipes(fullTypes)
    if #known > 0 then
        T.openCraft(known, label, #unknown)
        return true
    end
    if #unknown > 0 then
        T.openJournal(unknown, label)
        return true
    end
    return false
end

-- THE PUBLIC DOOR - what domain mods call (Reclamation's My Vehicles hands
-- over a part's accepted item types and a "Brake - Mustang" label). Routes,
-- then navigates the player panel here itself, so callers never need to know
-- this tab's id. Fails quiet by contract.
function T.openFor(fullTypes, label)
    if not (fullTypes and #fullTypes > 0) then return end
    local ok, routed = pcall(route, fullTypes, label)
    if not ok then
        print("[OE] Workshop route failed (" .. tostring(label) .. "): " .. tostring(routed))
        return
    end
    if not routed then
        -- No loaded recipe makes this at all: land on Craft with an honest
        -- zero rather than wherever the tab last was.
        T.openCraft({}, label, 0)
    end
    if DFPlayerRegistry and DFPlayerRegistry.requestShow then
        DFPlayerRegistry.requestShow(TAB_ID)
    end
end

-- Internal door: a Gear row (WSGear row table). No navigation - the player
-- is already on this tab.
function T.routeItem(row)
    if not row then return end
    local ok, err = pcall(route, { row.full }, row.disp)
    if not ok then
        print("[OE] Workshop route failed (" .. tostring(row.disp) .. "): " .. tostring(err))
    end
end

function T.clearTarget()
    T.target = nil
    T.filterList = nil
    if T.craft then
        pcall(function() T.craft:refreshRecipeList(true) end)
    end
end

-- ---------------------------------------------------------------------------
-- Craft header strip: what the list is narrowed to, and the way back out.
-- ---------------------------------------------------------------------------
local Header = ISPanel:derive("WSWorkshopHeader")

function Header:prerender()
    ISPanel.prerender(self)
    local C = DFKit.col
    self:drawRect(0, self.height - 1, self.width, 1, 0.45, C.line.r, C.line.g, C.line.b)
    local ty = math.floor((self.height - getTextManager():getFontHeight(fS())) / 2)
    if T.target then
        local txt = string.format("%s: %s  (%d %s)",
            getText("IGUI_OE_WS_For"), T.target.label,
            T.target.count, getText("IGUI_OE_WS_Recipes"))
        if T.target.learnable and T.target.learnable > 0 then
            txt = txt .. string.format("  +%d learnable - see Journal", T.target.learnable)
        end
        self:drawText(txt, PAD, ty, C.accent.r, C.accent.g, C.accent.b, 1, fS())
    else
        self:drawText(getText("IGUI_OE_WS_All"), PAD, ty,
            C.textDim.r, C.textDim.g, C.textDim.b, 1, fS())
    end
end

-- ---------------------------------------------------------------------------
-- Sub-tab strip
-- ---------------------------------------------------------------------------
local SUBS = {
    { key = "craft",   label = "Craft" },
    { key = "gear",    label = "Gear" },
    { key = "journal", label = "Journal" },
}

function T.showSub(key)
    T.sub = key
    if not T.host then return end
    if T.craftRoot then T.craftRoot:setVisible(key == "craft") end
    if WSGear.root then WSGear.root:setVisible(key == "gear") end
    if WSJournal.root then WSJournal.root:setVisible(key == "journal") end
    if key == "gear" then WSGear.populate() end
    if key == "journal" then WSJournal.populate() end
    -- active room reads accent, the rest read quiet
    local C = DFKit.col
    for _, sub in ipairs(SUBS) do
        local btn = T.subBtns and T.subBtns[sub.key]
        if btn then
            if sub.key == key then
                btn.borderColor = { r = C.accent.r, g = C.accent.g, b = C.accent.b, a = 0.9 }
            else
                btn.borderColor = { r = C.line.r, g = C.line.g, b = C.line.b, a = 0.7 }
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Build / resize
-- ---------------------------------------------------------------------------
local function layout(w, h)
    local bx = PAD
    for _, sub in ipairs(SUBS) do
        local btn = T.subBtns[sub.key]
        btn:setX(bx); btn:setY(2)
        bx = bx + btn:getWidth() + 6
    end

    local ch = h - SUB_H
    T.craftRoot:setY(SUB_H)
    T.craftRoot:setWidth(w); T.craftRoot:setHeight(ch)
    T.header:setWidth(w); T.header:setHeight(HEADER_H)
    local bw = 90
    T.btnAll:setX(w - bw - PAD); T.btnAll:setY(3); T.btnAll:setWidth(bw)
    if T.craft then
        T.craft:setY(HEADER_H)
        pcall(function() T.craft:calculateLayout(w, ch - HEADER_H) end)
    end

    if WSGear.root then
        WSGear.root:setY(SUB_H)
        WSGear.layout(w, ch)
    end
    if WSJournal.root then
        WSJournal.root:setY(SUB_H)
        WSJournal.layout(w, ch)
    end
end

function T.build(spec, panel, x, y, w, h)
    T.host = panel
    T.subBtns = {}
    for _, sub in ipairs(SUBS) do
        T.subBtns[sub.key] = DFKit.button(panel, 0, 2, 84, sub.label, T,
            function() T.showSub(sub.key) end, nil, { h = SUB_H - 6 })
    end

    -- CRAFT room: header strip + the vanilla panel, exactly as its own window
    -- builds it (nil skin falls back to XuiManager.GetDefaultSkin; craftBench
    -- nil = handcraft mode, the panel hunts its own craft surface). Guarded
    -- whole: if the crafting UI stack is absent or changes shape, the room
    -- degrades to a header that says so rather than erroring the deck.
    T.craftRoot = ISPanel:new(0, SUB_H, w, h - SUB_H)
    T.craftRoot.background = false
    T.craftRoot:initialise()
    T.craftRoot:instantiate()
    panel:addChild(T.craftRoot)

    T.header = Header:new(0, 0, w, HEADER_H)
    T.header.background = false
    T.header:initialise()
    T.craftRoot:addChild(T.header)

    T.btnAll = ISButton:new(0, 3, 90, HEADER_H - 6, getText("IGUI_OE_WS_ShowAll"), T, T.clearTarget)
    T.btnAll:initialise()
    T.header:addChild(T.btnAll)

    T.craft = nil
    local ok, err = pcall(function()
        local p = ISXuiSkin.build(nil, nil, ISHandCraftPanel, 0, HEADER_H, w, h - SUB_H - HEADER_H,
            getPlayer(), nil, nil)
        p.recipeQuery = CATALOGUE_QUERY

        -- The sticky filter (see file header). Vanilla's method is captured
        -- at build time and delegated to, so the B-key window - which shares
        -- the class but not the instance - never sees any of this.
        local baseRefresh = p.refreshRecipeList
        p.refreshRecipeList = function(pnl, force)
            if not T.filterList then return baseRefresh(pnl, force) end
            if pnl:updateContainers(force) then
                pnl.logic:setRecipes(T.filterList)
            end
        end

        p:initialise()
        p:instantiate()
        T.craftRoot:addChild(p)
        T.craft = p
    end)
    if not T.craft then
        print("[OE] Workshop: handcraft panel unavailable: " .. tostring(err))
    end

    -- GEAR + JOURNAL rooms
    WSGear.create(panel, w, h - SUB_H)
    WSGear.root:setY(SUB_H)
    WSJournal.create(panel, w, h - SUB_H)
    WSJournal.root:setY(SUB_H)

    layout(w, h)
    T.showSub(T.sub or "craft")

    if T.craft then
        pcall(function() T.craft:refreshRecipeList(true) end)
        ISHandCraftPanel.drawDirty = true
    end
end

function T.resize(spec, panel, w, h)
    if panel ~= T.host or not T.header then return end
    layout(w, h)
end

-- ---------------------------------------------------------------------------
-- Registration. OnGameStart, not OnGameBoot: the kill switch needs
-- SandboxVars, which are not up when boot fires on a joining MP client. A
-- killed Workshop registers nothing - the tab simply is not there, and every
-- door (guarded on WSTab.openFor existing, then failing quiet) goes silent.
-- ---------------------------------------------------------------------------
Events.OnGameStart.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerTab) then return end
    if not OEShared.enabled("WorkshopEnable") then return end
    Dragonfly.registerPlayerTab{
        id     = TAB_ID,
        label  = getText("IGUI_OE_Workshop"),
        order  = 30,
        build  = T.build,
        resize = T.resize,
        -- The embedded vanilla crafting panel is the whole B-key window's
        -- body; it lays itself out and wants real estate, especially height.
        prefW  = 1100,
        prefH  = 760,
    }
end)

return WSTab

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
