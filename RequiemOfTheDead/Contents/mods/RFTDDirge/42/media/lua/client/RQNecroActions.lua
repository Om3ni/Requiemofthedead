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

-- Where the server starts looking - which matters much less than it used to.
-- Since 2026-08-25 svFindZombieByOnlineID resolves a REAL id through the
-- shared RQZombieCache and ignores the coordinates entirely; the box sweep
-- survives only for the id-0 lane, where the point IS the selector and
-- decides WHICH zombie a convert lands on. Panel rows always carry a real id,
-- so for this caller the origin is now a courtesy, not a requirement.
--
-- The row is snapshot data and the zombie has been walking since. So: if we can
-- see that id locally, send where it IS rather than where the row said it was.
--
-- WHAT CHANGED 2026-08-25. This used to read as an id-AND-position confirm,
-- and the comment here justified it on exactly that basis: a hit meant the row
-- was still current. It no longer does. RQCore.findZombieByID is keyed on the
-- id alone, so a hit now means only "locally loaded" - which is the same "we
-- can see it" test the panel's locality filter applies, and is the part that
-- actually mattered. The change is a strict improvement for this caller: a
-- special that had walked out of the old +/-15 box used to miss the confirm
-- and fall back to STALE row coordinates, which is the worst of the three
-- outcomes. It cannot now.
--
-- Falling back to the row's own coordinates is still correct when the confirm
-- misses (a zombie in another player's cell is real, just not ours to look
-- at), and the refusal below still earns its place even though a real id no
-- longer needs coordinates at all: a row with no position AND no usable id
-- would put the id-0 lane's sweep at the world ORIGIN, silently, under a
-- "Convert request sent" toast. A row that names nothing is refused where the
-- operator can see the refusal.
local function convertOrigin(rowData)
    -- Called directly, not behind an existence check: RQCore is required at the
    -- top of this file and a missing one is a load-order fault we want loud.
    local live = RQCore.findZombieByID(rowData.id)
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
