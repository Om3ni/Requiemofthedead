-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQNecroActions - registers Dirge "Convert to Type" actions on the Necro
-- tab when both Dragonfly and Reaper are installed. Soft-depends on both;
-- without Dragonfly, Dirge's existing right-click admin menu still works
-- as the only conversion surface.
--
-- Each action handler sends Dirge's existing adminConvert command. The
-- server-side svMarkZombie path runs unchanged, so type-specific behavior
-- (Screamer summoning, Juggernaut aura, etc.) initializes the same way it
-- does from the in-world right-click menu.

if isServer() then return end

-- Both are Dirge's own client files and both load before this one under the
-- alphabetical walk, but sect. 4 exists because that is a fact about filenames
-- rather than a contract. RQCommon.MODULE is the wire token; RQCore carries the
-- id-and-position lookup convertOrigin uses below.
require "RQCommon"
require "RQCore"

-- DFRegistry check happens inside the OnGameStart callback below, not here.
-- Top-of-file early return would prevent the OnGameStart hook from ever
-- being registered if Dirge loads before DragonflyAdmin.

-- TYPES is built inside OnGameStart so Capability (defined by Dragonfly Admin)
-- isn't dereferenced at file-load time. Without that guard, any client without
-- Dragonfly installed errors out with "attempted index of nil" the moment this
-- file loads, breaking everything else in the mod.
local TYPE_IDS = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger", "Boss" }

-- Where the server starts looking. Not a nicety: svFindZombieByOnlineID sweeps a
-- 31x31 box centred on whatever arrives (RQSvShared.lua:418), so the origin
-- decides whether a convert lands at all - and, when the id is 0, WHICH zombie
-- it lands on.
--
-- The row is snapshot data and the zombie has been walking since. So: confirm
-- the id is still near where the row said it was, and if it is, send where it
-- IS. RQCore.findZombieByID is the right tool precisely because it is
-- id-and-position - a match means the row is both current and locally loaded,
-- which is the same "we can see it" test the panel's locality filter applies.
--
-- Falling back to the row's own coordinates is correct when the confirm misses
-- (a zombie in another player's cell is real, just not ours to look at). What is
-- NOT correct, and was what this did, is `rowData.x or 0`: a row that somehow
-- arrived without coordinates became a 961-square sweep of the world ORIGIN,
-- silently, under a "Convert request sent" toast. A row with no position cannot
-- name a zombie, so it is refused where the operator can see the refusal.
local function convertOrigin(rowData)
    -- Called directly, not behind an existence check: RQCore is required at the
    -- top of this file and a missing one is a load-order fault we want loud.
    local live = RQCore.findZombieByID(rowData.id,
        rowData.x or 0, rowData.y or 0, rowData.z or 0)
    if live then
        return math.floor(live:getX()), math.floor(live:getY()), math.floor(live:getZ())
    end
    if not rowData.x or not rowData.y or not rowData.z then return nil end
    return math.floor(rowData.x), math.floor(rowData.y), math.floor(rowData.z)
end

local function convertHandler(zType)
    return function(rowData)
        if not rowData or not rowData.id then return end
        local x, y, z = convertOrigin(rowData)
        if not x then
            if DFFeedback then
                DFFeedback.bad("That row has no position - refresh the list and try again.")
            end
            return
        end
        sendClientCommand(getPlayer(), RQCommon.MODULE, "adminConvert", {
            onlineID = rowData.id,
            x        = x,
            y        = y,
            z        = z,
            zType    = zType,
        })
        if DFFeedback then
            DFFeedback.good(string.format("Convert request sent: id=%d -> %s",
                rowData.id, zType))
        end
        -- Local audit echo so the action shows up in the Console tab even
        -- before Dirge replies. Server-side svMarkZombie doesn't emit a
        -- LogBroadcast on its own; if it ever does we'll see a duplicate
        -- here, which is acceptable.
        if DFLog then
            DFLog.push{
                source = "Mod:RFTDDirge",
                level  = "audit",
                text   = string.format("Convert id=%d -> %s by %s",
                    rowData.id, zType, getPlayer():getUsername()),
            }
        end
    end
end

Events.OnGameStart.Add(function()
    if not DFRegistry or not Capability then return end
    for _, id in ipairs(TYPE_IDS) do
        DFRegistry.registerRowAction{
            tabId      = "necro",
            label      = "Convert → " .. id,
            capability = Capability.CanZombify,
            handler    = convertHandler(id),
        }
    end
    print("[Dirge] RQNecroActions: " .. #TYPE_IDS .. " Convert actions registered")
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
