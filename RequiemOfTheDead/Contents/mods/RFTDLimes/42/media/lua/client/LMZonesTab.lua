-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMZonesTab - the Dragonfly "Zones" tab: two views behind one strip.
--
--   Zone Selector   the map, the zone tree, and the policies that are true for
--                   a zone absent any other mod (LMEditView).
--   Details         per-mod overrides for the selected zone, driven entirely by
--                   the field registry, so a mod that registers gets a control
--                   with no edit here (LMDetailsView).
--
-- IMPORT IS NOT A VIEW. It is a once-per-migration operation and it had equal
-- billing with the editor; it is a button on the Zone Selector's toolbar now,
-- and it opens LMImportWindow - the same paste panel with a scrollable, copyable
-- log under it instead of eight fixed labels.
--
-- Both views share ONE draft and ONE selected zone, owned by LMEditView and read
-- through LMEditView.draft() / .selected(). Two drafts would mean Details
-- editing a zone the map is not showing, and two Saves that each lose the
-- other's work.
--
-- This file owns almost nothing: the strip, the switching, the visibility rules
-- and the onShow dispatch are DFViews (Core). What is left is the registration,
-- the statement of which views exist, and one prerender chain - installed HERE
-- rather than in each view, because both views draw a DFForm and a hidden one's
-- chrome would otherwise paint over the visible one (a drawn row has no
-- visibility flag to switch off).
--
-- Soft-dep on Dragonfly throughout. No DFRegistry, no tab, and Limes still
-- resolves zones, syncs, persists and bridges exactly as before.

if isServer() then return end

require "LMCore"

LMZonesTab = LMZonesTab or {}

local views = nil
local rect  = { panel = nil, x = 0, y = 0, w = 0, h = 0 }

local STRIP_H = 26

local function layout(panel, x, y, w, h)
    rect.panel = panel or rect.panel
    rect.x, rect.y, rect.w, rect.h = x, y, w, h
    if not views then return end
    local m = DFKit.metrics
    -- The strip is claimed FIRST, above anything either view owns, so it stays
    -- put while the body underneath changes completely.
    views:layoutStrip(rect.x + m.pad, rect.y + m.pad)
    views:layoutActive(rect.panel, rect.x, rect.y + STRIP_H, rect.w, rect.h - STRIP_H)
end

-- DFViews' relayout hook takes no arguments, so it works from what layout last
-- recorded. Passing nil for the panel instead would fail inside DFViews' pcall,
-- which reads as "the panel does not reflow after a switch" and logs nothing.
local function relayout()
    layout(rect.panel, rect.x, rect.y, rect.w, rect.h)
end

local function build(spec, panel, x, y, w, h)
    views = DFViews.new({
        views = {
            { id = "zones", label = "Zone Selector", w = 108, view = LMEditView,
              tip = "The map, the zone tree, and each zone's own policies. Draw a zone"
                 .. " inside another and it becomes that zone's child." },
            { id = "details", label = "Details", w = 72, view = LMDetailsView,
              tip = "Per-mod overrides for the selected zone. Every mod that registers"
                 .. " fields with Limes appears here." },
        },
        relayout = relayout,
    })
    views:attachStrip(panel)
    views:attachViews(panel)

    -- The single chrome chain, routed to the active view. Both views draw a
    -- DFForm, which is drawn chrome rather than widgets.
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        if views then views:draw(self_) end
    end

    -- Seed the rect BEFORE the first switch: set() calls relayout, and relayout
    -- can only work from what layout last recorded.
    layout(panel, x, y, w, h)
    views:set("zones")      -- also performs the first visibility pass
end

Events.OnGameStart.Add(function()
    if not (DFRegistry and DFViews) then
        print("[Limes] Dragonfly not present (or too old for DFViews) - Zones tab not registered")
        return
    end
    -- pcall: registerTab belongs to Dragonfly. Its argument shape is a foreign
    -- contract that can move between versions, and the failure is reported
    -- below rather than left to surface as a Limes boot error.
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id     = "limes",
            label  = "Zones",
            order  = 6,
            build  = build,
            resize = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
        }
    end)
    if ok then print("[Limes] Zones tab registered into Dragonfly (Zone Selector | Details)")
    else print("[Limes] Zones tab registration failed: " .. tostring(err)) end
end)

return LMZonesTab

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
