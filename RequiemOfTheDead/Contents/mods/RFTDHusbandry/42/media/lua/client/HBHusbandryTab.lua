-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBHusbandryTab - one Husbandry tab hosting Animals and Hutches.
--
-- WHY ONE TAB. They were two top-level entries in a bar that had reached nine,
-- and they are one domain: the animals, and the things the animals live in.
-- Anyone diagnosing a sick flock needs both within a click of each other, and a
-- top-level name has to explain itself to someone scanning a row of unrelated
-- words whereas a sibling only has to differ from Animals. Same reasoning that
-- put Fleet and Janitor behind the Vehicles tab.
--
-- THIS FILE OWNS ALMOST NOTHING. The strip, the switching, the visibility rules
-- and the onShow dispatch are DFViews (Core) - see that file's header for why
-- that is shared rather than copied, and in particular for the reason switching
-- must be visibility and not drawing over the top. Each view owns everything
-- inside its own rect. What is left here is the tab registration, the two-line
-- statement of which views exist, and one prerender chain.
--
-- ONE PRERENDER CHAIN, INSTALLED HERE. Both views used to install their own,
-- which was fine while they were separate panels. Sharing one panel they would
-- both run and the hidden view's column header would draw over the visible one,
-- because a drawRect has no visibility flag to switch off. So the host installs
-- a single chain and routes it to whichever view is active.

if isServer() then return end

require "DFKit"
require "DFViews"

HBHusbandryTab = HBHusbandryTab or {}
local T = HBHusbandryTab

local function layout(panel, x, y, w, h)
    if not T.views then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    -- The strip is claimed FIRST, above anything either view owns, so it stays
    -- put while the body underneath changes completely.
    local strip = R:header(m.btnH + m.gap)
    T.views:layoutStrip(strip.x, strip.y)

    local body = R:rest()
    T.views:layoutActive(panel, body.x, body.y, body.w, body.h)
end

local function build(spec, panel, x, y, w, h)
    -- Animals leads: it is what an admin opens this tab to look at, and Hutches
    -- is where you go deliberately once an animal looks wrong.
    T.views = DFViews.new{
        views = {
            { id = "animals", label = "Animals", w = 82, view = HBAnimalsView,
              tip = "Every animal loaded near you - condition, hunger, thirst and where it is standing." },
            { id = "hutches", label = "Hutches", w = 82, view = HBHutchesView,
              tip = "Coops and hutches near you: dirt, nest-box dirt and how much bedding is left. Hay eats dirt and decays, so this is the view that tells you what needs topping up." },
        },
        relayout = function()
            if T.host then layout(T.host, T.hostX, T.hostY, T.hostW, T.hostH) end
        end,
    }

    -- Strip buttons belong to the TAB and are never hidden by a switch, so they
    -- go into neither view's widget list.
    T.views:attachStrip(panel)
    T.views:attachViews(panel)

    -- The single chrome chain. Routed to the active view; a view with no draw
    -- simply contributes nothing.
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        if T.views then T.views:draw(self_) end
    end

    T.host = panel
    T.hostX, T.hostY, T.hostW, T.hostH = x, y, w, h

    -- set() rather than assuming the constructor's default: this is what
    -- performs the FIRST visibility pass, so the inactive view starts hidden
    -- rather than drawn on top of the active one until somebody clicks.
    T.views:set("animals")
    layout(panel, x, y, w, h)
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    -- DFRegistry is Core-owned and this registered spec is already complete;
    -- its current body validates the id then performs a table assignment.
    DFRegistry.registerTab{
        id     = "husbandry",
        label  = "Husbandry",
        -- Deck nav order, set as one decision 2026-08-18 (live review):
        -- Admin 10, Players 20, Necro 30, Vehicles 40, Husbandry 50,
        -- Longstrider 60, Zones 70, Console 1000 (always last).
        -- Spaced by ten so a new tab can land between two without
        -- renumbering five files across five mods again.
        order = 50,
        build  = build,
        resize = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
    }
    print("[Husbandry] HBHusbandryTab registered into Dragonfly (Animals | Hutches)")
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
