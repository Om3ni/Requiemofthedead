-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFAdminTab - the server's own settings, in the deck.
--
-- Was a reserved empty slot until 2026-08-22; it now hosts the Sandbox view.
-- The slot was claimed early on purpose - tab order is sorted, so a tab
-- arriving late shuffles whatever sits at 30+ sideways, and the roster is
-- something admins learn by muscle memory. Claiming it then means nothing
-- moved today.
--
-- ---------------------------------------------------------------------------
-- WHY THERE IS NO SUB-TAB STRIP YET, since the plan called for one.
--
-- The strip is Sandbox / Server / Tooling / Safezones, and only Sandbox exists.
-- A strip of one button is noise, and three buttons leading to empty views are
-- worse - DFViews has no disabled state, so they would switch to nothing and
-- read as broken rather than as unbuilt. So the host calls the view directly.
--
-- DFSandboxView implements the full DFViews contract regardless (attach /
-- layout / draw / onShow), so introducing the strip when the Server view lands
-- is a DFViews.new{} here and nothing at all there. That is the reason to write
-- the contract now and not the strip: the cost of being early is carried by the
-- side that does not change.
--
-- ---------------------------------------------------------------------------
-- CAPABILITY. Gated on Capability.SandboxOptions (Capability.java:84) - the
-- engine's own permission for the screen this mirrors, rather than isTopAdmin,
-- which would stay true for a moderator who should not have it and is not a
-- statement about sandbox editing at all.
--
-- KNOWN, AND DELIBERATELY NOT SOLVED YET: the spec carries ONE capability
-- (DFDeck.lua:334 evaluates `RDAccess.roleHas(p, cap)`), but the Server view
-- needs ChangeAndReloadServerOptions (:103) and someone could hold one without
-- the other. When that view lands there are two honest ways out - teach the
-- registry to accept a list, or gate the TAB on holding any of them and grey
-- the individual strip buttons - and both are decisions about a Core contract,
-- so neither is worth pre-building against one view.

-- ---------------------------------------------------------------------------
-- WHY THE HOST LIVES INSIDE Admin/ WITH ITS VIEWS. Longstrider's precedent:
-- LSTab is the registered tab and sits in client/Longstrider/ alongside LSMap,
-- LSRoute and the rest, not one level up. A tab that owns a folder owns it from
-- inside, so "everything Admin" is one directory rather than one directory plus
-- a file that has to be remembered.
--
-- The move is free. Requires resolve against the lua TIER root, not the calling
-- file, so `require "Admin/DFSandboxView"` reads identically from either place -
-- which is also why a bare `require "DFSandboxView"` would fail from either.
-- The alphabetical client walk changes order, and that is fine here: this file
-- states its dependencies with require and defers registration to OnGameStart,
-- so nothing it does happens at a position in the walk.

if isServer() then return end

require "DFKit"
require "Admin/DFSandboxView"

DFAdminTab = DFAdminTab or {}
local T = DFAdminTab

local function layout(panel, x, y, w, h)
    DFSandboxView.layout(panel, x, y, w, h)
end

local function build(spec, panel, x, y, w, h)
    DFSandboxView.attach(panel)

    -- One chrome chain on the host, not in the view. The view draws its legend
    -- through this; when a second view arrives the host routes the chain to
    -- whichever is active, which is exactly what HBHusbandryTab does and why -
    -- a drawRect has no visibility flag, so two views each installing their own
    -- chain would both paint and the hidden one would draw over the visible.
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        DFSandboxView.draw(self_)
    end

    T.host = panel
    layout(panel, x, y, w, h)
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    -- No guard. Core is a HARD dependency, and registerTab is a validated
    -- assignment: a nil or id-less spec is refused with a print, anything else
    -- is a table write (DFRegistry.lua:23-30). "Must not kill this OnGameStart
    -- listener" was never a reason either - the engine already contains each
    -- listener in its own try/catch (Event.java:53-63).
    DFRegistry.registerTab{
        id       = "admin",
        label    = "Admin",
        -- Deck nav order, one decision 2026-08-18: Admin 10, Players 20,
        -- Necro 30, Vehicles 40, Husbandry 50, Longstrider 60, Zones 70,
        -- Console 1000 (always last). Spaced by ten so a new tab can land
        -- between two without renumbering five files across five mods.
        order      = 10,
        capability = Capability and Capability.SandboxOptions or nil,
        build      = build,
        resize     = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
    }
    print("[Dragonfly] DFAdminTab registered (Sandbox)")
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
