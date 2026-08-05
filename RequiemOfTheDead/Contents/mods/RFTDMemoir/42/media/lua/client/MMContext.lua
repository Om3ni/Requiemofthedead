-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMContext.lua - right-click options on the journal: Write / Read / Dump.
-- All three just send a request to the server (the authority). Write is gated on a
-- writing tool present (pen/pencil) so the book is "reusable as long as pen/pencil".

if isServer() then return end

require "ISUI/ISInventoryPaneContextMenu"
require "MMSvShared"
require "MMClient"

local MM_ITEM = "Memoir" -- Base.Memoir

local MMContext = {}

function MMContext.onWrite(item, player) MMClient.requestWrite(player, item) end
function MMContext.onRead(item, player)  MMClient.requestRead(player, item) end
function MMContext.onDump(item, player)  MMClient.requestDump(player, item) end

function MMContext.fill(playerID, context, items)
    local player = getSpecificPlayer(playerID)
    if not player then return end
    local actual = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actual) do
        if item:getType() == MM_ITEM then
            local inv = player:getInventory()
            local hasTool = inv:getFirstTagRecurse(ItemTag.WRITE)
            -- Same predicate the server's findItem uses: a memoir in a crate / car /
            -- corpse is NOT actionable (the server only searches the player's own
            -- inventory), so offering live options there produced silent no-ops.
            local carried = inv:getItemWithIDRecursiv(item:getID()) ~= nil

            -- Push these to the TOP of the right-click list. addOptionOnTop prepends,
            -- so we add in reverse visual order (Dump, Read, Write) to end up with
            -- Write -> Read -> [Dump] at the top.

            -- debug-only dump (observability while proving the logic). Gated on the
            -- MemoirDebug sandbox flag AND admin access, so regular players never see
            -- it even when an admin enables debug server-wide.
            if MMShared.debugOn() and isAdmin() then
                context:addOptionOnTop("[MM Debug] Dump Memoir", item, MMContext.onDump, player)
            end

            local readOpt = context:addOptionOnTop("Read Memoir", item, MMContext.onRead, player)
            if not carried then
                readOpt.notAvailable = true
                local tt = ISInventoryPaneContextMenu.addToolTip()
                tt.description = "The memoir must be in your inventory."
                readOpt.toolTip = tt
            end

            local writeOpt = context:addOptionOnTop("Write Memoir", item, MMContext.onWrite, player)
            if not carried then
                writeOpt.notAvailable = true
                local tt = ISInventoryPaneContextMenu.addToolTip()
                tt.description = "The memoir must be in your inventory."
                writeOpt.toolTip = tt
            elseif not hasTool then
                writeOpt.notAvailable = true
                local tt = ISInventoryPaneContextMenu.addToolTip()
                tt.description = "Requires a pen or pencil."
                writeOpt.toolTip = tt
            end
            break
        end
    end
end

Events.OnFillInventoryObjectContextMenu.Add(MMContext.fill)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
