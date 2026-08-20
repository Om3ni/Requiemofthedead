-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMRoster.lua - Memoir's authoritative online-player lookup.
--
-- One mechanism is shared by recovery, delayed audit checks, and trait repair.
-- getOnlinePlayers always returns an ArrayList for server, client, or neither;
-- IsoPlayer.getUsername() returns the stored username on the server
-- (LuaManager.java:3823-3831; IsoPlayer.java:5990-5992, 6001-6035).
-- ArrayList size/get are paired in one main-thread walk, so "not found" means
-- offline rather than "some exception was swallowed while looking".

MMRoster = MMRoster or {}

function MMRoster.findOnline(username)
    if type(username) ~= "string" or username == "" then return nil end
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and player:getUsername() == username then return player end
    end
    return nil
end

return MMRoster

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
