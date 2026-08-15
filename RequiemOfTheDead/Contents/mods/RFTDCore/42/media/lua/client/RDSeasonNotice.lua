-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDSeasonNotice.lua - on-screen warning that the season name needs changing.
--
-- Sent by RDSeasonServer to the first admin who joins when the configured
-- season already holds records and the world is young: almost certainly a wipe
-- where the sandbox option was not updated, which quietly mixes two worlds'
-- chronicles in one folder.
--
-- WHY A POPUP AND NOT JUST THE LOG: nobody reads a dedicated server console
-- until something has already gone wrong. The window to act is between the
-- server coming up and the first players arriving, and the only person in that
-- window is the admin who just connected. So tell them where they are looking.
--
-- Advisory only. Nothing here changes what the server does - the season is
-- still exactly the name that was typed into the sandbox. Dismissing this
-- costs nothing but the records staying mixed.
--
-- Deliberately no dependency on Dragonfly's DFConfirm: Core must not require a
-- satellite to be installed. Vanilla ISModalDialog, wrapped in pcall, with the
-- console line as the fallback if the UI construction ever fails.

if isServer() then return end

require "RDShared"
require "ISUI/ISModalDialog"

-- The engine can still be settling the HUD when a player first becomes ready;
-- a modal built into that window can be discarded. One second of ticks is
-- enough and costs nothing - this fires at most once per session.
local DELAY_TICKS = 60

local pending = nil
local ticks   = 0

local function show(season)
    local text =
        "Requiem of the Dead: Core\n\n" ..
        "Season \"" .. tostring(season) .. "\" already has records, but this world is new.\n\n" ..
        "If you wiped the world, the new records are being written into the\n" ..
        "previous season's folder and the two will be mixed together.\n\n" ..
        "To fix: Sandbox Options > Requiem of the Dead: Core > Season Name.\n" ..
        "Set a new name and restart the server before players join.\n\n" ..
        "Nothing has been changed automatically."

    -- vanilla ISUI Lua construction (ISModalDialog), unverifiable here; the
    -- console fallback below carries the warning when the modal cannot
    local ok = pcall(function()
        local w, h = 460, 260
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        local modal = ISModalDialog:new((sw - w) / 2, (sh - h) / 2, w, h, text, false, nil, nil)
        modal:initialise()
        modal:setAlwaysOnTop(true)
        modal:addToUIManager()
    end)

    if not ok then
        -- The warning matters more than the presentation.
        print("[RFTDCore] " .. text:gsub("\n", " "))
    end
end

Events.OnTick.Add(function()
    if not pending then return end
    ticks = ticks + 1
    if ticks < DELAY_TICKS then return end
    local season = pending
    pending = nil
    ticks = 0
    show(season)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= RDShared.MODULE or command ~= "seasonNotice" then return end
    pending = (args and args.season) or "?"
    ticks = 0
    print("[RFTDCore] season notice received: '" .. tostring(pending) .. "' already has records")
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
