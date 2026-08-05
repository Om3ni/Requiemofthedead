-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCNotify - server -> client halo feedback channel.
--
-- The server sends { key, error } under a "Notify" command; we resolve the
-- translation key and float it over the local player. Green for success, red
-- for a denial. This is the only feedback path for claim/deny/expiry results.

if isServer() and not isClient() then return end

RCNotify = RCNotify or {}

local function onServerCommand(module, command, args)
    if module ~= RCShared.MODULE then return end
    if command ~= "Notify" then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local key = (args and args.key) or "IGUI_RC_Generic"
    RCShared.halo(player, getText(key), args and args.error)
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
