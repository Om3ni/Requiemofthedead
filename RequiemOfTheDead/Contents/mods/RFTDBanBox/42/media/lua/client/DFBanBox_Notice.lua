-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFBanBox_Notice.lua - shows the player the BanBox removal notice (client-side).
--
-- The server (DFBanBox login scrub) formats the full message and sends it here;
-- this side is a dumb display so the server's removalMessage (overridden by BBLibrary)
-- is the single source of the wording. HaloText gives the player immediate visibility.

if isServer() then return end

local function onServerCommand(module, command, args)
    if module ~= "DFBanBox" or command ~= "removed" then return end
    local msg = args and args.message
    if not msg or msg == "" then return end
    local p = getPlayer()
    if not p then return end
    if HaloTextHelper and HaloTextHelper.addBadText then
        HaloTextHelper.addBadText(p, msg)
    end
end

Events.OnServerCommand.Add(onServerCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
