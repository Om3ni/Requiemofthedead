-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCWorkshopTab - the Workshop: vehicle-part crafting on the player panel
-- (client).
--
-- WHAT THIS IS (owner, 2026-08-13). Clicking a part on the My Vehicles tab
-- lands here with the recipe list already narrowed to THAT part on THAT
-- vehicle - "craft brakes for my Mustang" without digging through the whole
-- crafting catalogue. The pane below the header is VANILLA'S OWN B42
-- handcraft panel (ISHandCraftPanel), embedded whole: ingredient checking,
-- skill requirements, the craft-surface hunt those welding recipes demand,
-- and the craft action itself are all the engine's - this file reimplements
-- none of it, so recipes added or changed by any mod are picked up the day
-- they load.
--
-- THE FILTER IS EXACT, NOT NAME-MATCHING. A part row arrives carrying the
-- item types its slot accepts (rec.items - read off the live VehiclePart,
-- server-side for a remote car; see RCFleet.parts for why the script-level
-- part cannot answer this). A recipe qualifies when any of its outputs
-- (OutputScript.getPossibleResultItems) lands in that set. So a car that
-- takes ModernBrake shows modern-brake recipes and not the other six, and a
-- recipe source we have never heard of qualifies the moment its output fits
-- the slot.
--
-- MOD-AGNOSTIC BY CONSTRUCTION, and deliberately so: the recipes this was
-- built around live in third-party mods (RQD Tweaker's refurbish set), and
-- the standing covenant on that suite is lessons only, never code. Nothing
-- here reads their files - the filter walks whatever craftRecipes are LOADED,
-- from any mod or vanilla.
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
-- No target set (the tab opened from the strip, not from a part) shows the
-- vanilla hand-craft catalogue - the same "InHandCraft;AnySurfaceCraft" tag
-- query the B-key window uses - with the header saying how to narrow it.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "DFKit"

RCWorkshopTab = RCWorkshopTab or {}
local T = RCWorkshopTab

local HEADER_H = 30
local PAD      = 8

-- Same tag set the vanilla B-key handcraft window queries; the catalogue
-- fallback must be the list players already know, not a third variant.
local CATALOGUE_QUERY = "InHandCraft;AnySurfaceCraft"

local function fS() return DFKit.font.small or UIFont.Small end

-- ---------------------------------------------------------------------------
-- The filter
-- ---------------------------------------------------------------------------

-- All loaded recipes with an output in `set` (full type names), as the java
-- ArrayList HandcraftLogic.setRecipes expects. Walked once per target change,
-- never per frame; a few hundred recipes cost nothing at human cadence.
local function buildFilterList(set)
    local list = ArrayList.new()
    pcall(function()
        local all = ScriptManager.instance:getAllCraftRecipes()
        for i = 0, all:size() - 1 do
            local r = all:get(i)
            local hit = false
            pcall(function()
                local outs = r:getOutputs()
                for j = 0, outs:size() - 1 do
                    local res = outs:get(j):getPossibleResultItems()
                    if res then
                        for k = 0, res:size() - 1 do
                            local it = res:get(k)
                            local fn = it and it:getFullName()
                            if fn and set[fn] then hit = true; return end
                        end
                    end
                end
            end)
            if hit then list:add(r) end
        end
    end)
    return list
end

-- The door My Vehicles knocks on: narrow the workshop to one part of one
-- vehicle. Takes effect immediately when the panel is alive, and is simply
-- remembered for the next build when it is not - the target OUTLIVES the tab,
-- because the deck rebuilds content on every visit.
function T.setTarget(vehName, partRec)
    if not (partRec and partRec.items and #partRec.items > 0) then return end
    local set = {}
    for i = 1, #partRec.items do set[partRec.items[i]] = true end
    T.filterList = buildFilterList(set)
    T.target = {
        veh   = tostring(vehName or "?"),
        part  = tostring(partRec.id or "?"):gsub("(%l)(%u)", "%1 %2"),
        count = T.filterList:size(),
    }
    if T.craft then
        pcall(function() T.craft:refreshRecipeList(true) end)
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
-- Header strip: what the list is currently narrowed to, and the way back out.
-- ---------------------------------------------------------------------------
local Header = ISPanel:derive("RCWorkshopHeader")

function Header:prerender()
    ISPanel.prerender(self)
    local C = DFKit.col
    self:drawRect(0, self.height - 1, self.width, 1, 0.45, C.line.r, C.line.g, C.line.b)
    local ty = math.floor((self.height - getTextManager():getFontHeight(fS())) / 2)
    if T.target then
        local txt = string.format("%s: %s - %s  (%d %s)",
            getText("IGUI_RC_WS_For"), T.target.part, T.target.veh,
            T.target.count, getText("IGUI_RC_WS_Recipes"))
        self:drawText(txt, PAD, ty, C.accent.r, C.accent.g, C.accent.b, 1, fS())
    else
        self:drawText(getText("IGUI_RC_WS_All"), PAD, ty,
            C.textDim.r, C.textDim.g, C.textDim.b, 1, fS())
    end
end

-- ---------------------------------------------------------------------------
-- Build / resize
-- ---------------------------------------------------------------------------
local function layout(w, h)
    T.header:setWidth(w); T.header:setHeight(HEADER_H)
    local bw = 90
    T.btnAll:setX(w - bw - PAD); T.btnAll:setY(3); T.btnAll:setWidth(bw)
    if T.craft then
        T.craft:setY(HEADER_H)
        pcall(function() T.craft:calculateLayout(w, h - HEADER_H) end)
    end
end

function T.build(spec, panel, x, y, w, h)
    T.host = panel

    T.header = Header:new(0, 0, w, HEADER_H)
    T.header.background = false
    T.header:initialise()
    T.header:instantiate()
    panel:addChild(T.header)

    T.btnAll = ISButton:new(0, 3, 90, HEADER_H - 6, getText("IGUI_RC_WS_ShowAll"), T, T.clearTarget)
    T.btnAll:initialise()
    T.header:addChild(T.btnAll)

    -- The vanilla panel, exactly as its own window builds it (nil skin falls
    -- back to XuiManager.GetDefaultSkin; craftBench nil = handcraft mode, and
    -- the panel hunts its own craft surface). Guarded whole: if the crafting
    -- UI stack is absent or changes shape, the tab degrades to a header that
    -- says so rather than erroring the deck's build.
    T.craft = nil
    local ok, err = pcall(function()
        local p = ISXuiSkin.build(nil, nil, ISHandCraftPanel, 0, HEADER_H, w, h - HEADER_H,
            getPlayer(), nil, nil)
        p.recipeQuery = CATALOGUE_QUERY

        -- The sticky filter (see header). Vanilla's method is captured at
        -- build time and delegated to, so the B-key window - which shares the
        -- class but not the instance - never sees any of this.
        local baseRefresh = p.refreshRecipeList
        p.refreshRecipeList = function(pnl, force)
            if not T.filterList then return baseRefresh(pnl, force) end
            if pnl:updateContainers(force) then
                pnl.logic:setRecipes(T.filterList)
            end
        end

        p:initialise()
        p:instantiate()
        panel:addChild(p)
        T.craft = p
    end)
    if not T.craft then
        print("[RC] Workshop: handcraft panel unavailable: " .. tostring(err))
    end

    layout(w, h)

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
-- Registration: third tab, after My Vehicles.
-- ---------------------------------------------------------------------------
Events.OnGameBoot.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerTab) then return end
    Dragonfly.registerPlayerTab{
        id     = "rc_workshop",
        label  = getText("IGUI_RC_Workshop"),
        order  = 30,
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
