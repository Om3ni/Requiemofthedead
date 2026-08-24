-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFAdminTab - the server's own settings, in the deck.
--
-- Was a reserved empty slot until 2026-08-22; it now hosts Sandbox and Server.
-- The slot was claimed early on purpose - tab order is sorted, so a tab
-- arriving late shuffles whatever sits at 30+ sideways, and the roster is
-- something admins learn by muscle memory. Claiming it then means nothing
-- moved today.
--
-- ---------------------------------------------------------------------------
-- THE SUB-TAB STRIP arrived with the second view, 2026-08-23, and cost exactly
-- what was predicted when the first one shipped without it: a DFViews.new{}
-- here and nothing at all in either view. Both were written to the DFViews
-- contract (attach / layout / draw / onShow) from the start.
--
-- Variables joined on 2026-08-23, third and last of the built ones: it is where an
-- admin goes on purpose rather than to look at something, so it sits after the
-- two that are read as often as they are written.
--
-- Tooling and Safezones are NOT in the strip and will not be until they exist.
-- DFViews has no disabled state, so a button for an unbuilt view switches to
-- nothing and reads as broken rather than as coming later.
--
-- Sandbox leads because it is what an admin opens this tab to look at; Server
-- is where you go deliberately, and it is the one that can require a restart.
--
-- ---------------------------------------------------------------------------
-- CAPABILITY. Gated on the engine's OWN permissions for the screens this
-- mirrors, rather than isTopAdmin - which stays true for a moderator who should
-- not have them and is not a statement about either thing.
--
-- SOLVED 2026-08-23, the first of the two ways named when this was deferred:
-- the spec may now carry a LIST, and the deck shows the tab to anyone holding
-- any one of them (RDAccess.roleHasAny, DFDeck.lua:339). The two halves are
-- genuinely differently gated - Sandbox wants Capability.SandboxOptions
-- (Capability.java:84) and Server wants ChangeAndReloadServerOptions (:103),
-- which is what ChangeOptionCommand and ReloadOptionsCommand both require -
-- and a role can hold either without the other.
--
-- What this does NOT yet do is grey the individual strip button for the half a
-- given role cannot use. That is the second half of the same problem and it
-- needs DFViews to learn a disabled state, which is a Core widget change with
-- no second consumer yet. Filed rather than bolted on: today the server's four
-- admins all hold both, so it is a correctness gap and not a live one.

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
require "DFViews"
require "Admin/DFSandboxView"
require "Admin/DFServerView"
require "Admin/DFVarsView"

DFAdminTab = DFAdminTab or {}
local T = DFAdminTab

local function build(spec, panel, x, y, w, h)
    T.views = DFViews.new{
        views = {
            { id = "sandbox", label = "Sandbox", w = 84, view = DFSandboxView,
              tip = "Every RFTD mod's sandbox options, one page per mod, with "
                 .. "the game's own description under each setting." },
            { id = "server", label = "Server", w = 76, view = DFServerView,
              tip = "The server's own INI options. Changes go out as "
                 .. "/changeoption; some need a restart, and the engine never "
                 .. "sends these back to a connected client." },
            { id = "vars", label = "Variables", w = 84, view = DFVarsView,
              tip = "Player attributes, in two columns: FLAGS a character "
                 .. "either holds or does not, and COUNTERS that hold a "
                 .. "number. Click one to edit it and manage who has it. "
                 .. "Backend state for events, kits and quests - players never "
                 .. "see it." },
        },
        -- DFViews owns the strip-then-body shape (layoutHost); calling it
        -- directly at each site rather than through a local wrapper, because
        -- the wrapper was identical in two mods and counted as a copy.
        relayout = function()
            if T.host then
                T.views:layoutHost(T.host, T.hostX, T.hostY, T.hostW, T.hostH)
            end
        end,
    }

    -- Strip buttons belong to the TAB and are never hidden by a switch, so they
    -- go into neither view's widget list.
    T.views:attachStrip(panel)
    T.views:attachViews(panel)

    -- ONE chrome chain, on the host, routed to whichever view is active. Two
    -- views each installing their own would both paint - a drawRect has no
    -- visibility flag to switch off - and the hidden one would draw over the
    -- visible. Same reasoning and same shape as HBHusbandryTab.
    local origPrerender = panel.prerender
    panel.prerender = function(self_)
        if origPrerender then origPrerender(self_) end
        if T.views then T.views:draw(self_) end
    end

    T.host = panel
    T.hostX, T.hostY, T.hostW, T.hostH = x, y, w, h

    -- set() rather than trusting the constructor default: this is what performs
    -- the FIRST visibility pass, so Server starts hidden rather than drawn on
    -- top of Sandbox until somebody clicks.
    T.views:set("sandbox")
    T.views:layoutHost(panel, x, y, w, h)
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
        -- A LIST: either half is enough to be shown the tab. See the
        -- capability note in the header.
        -- Three now, one per sub-tab. Vars' verbs are gated on
        -- CanModifyPlayerStatsInThePlayerStatsUI server-side (DFVars_Server),
        -- so a role holding only that must be able to reach the tab that hosts
        -- them - otherwise the capability grants an ability with no way to use
        -- it. The strip still cannot grey the two halves such a role cannot
        -- use; that is the DFViews gap already in TODO.md.
        capability = Capability
            and { Capability.SandboxOptions,
                  Capability.ChangeAndReloadServerOptions,
                  Capability.CanModifyPlayerStatsInThePlayerStatsUI }
            or nil,
        build      = build,
        resize     = function(_, panel, w, h)
            if T.views then T.views:layoutHost(panel, 0, 0, w, h) end
        end,
    }
    print("[Dragonfly] DFAdminTab registered (Sandbox | Server | Variables)")
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
