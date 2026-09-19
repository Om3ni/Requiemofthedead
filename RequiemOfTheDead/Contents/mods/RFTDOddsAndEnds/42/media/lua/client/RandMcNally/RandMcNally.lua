-- SPDX-License-Identifier: GPL-3.0-or-later
-- RandMcNally.lua - puts vanilla's "Map All Known" sandbox option back to work
-- on multiplayer clients.
--
-- The option still exists and singleplayer still honours it. Multiplayer lost
-- it in 42.20.3, when the server->client transfer of a player's explored-map
-- data moved onto the large-file request channel:
--
--   * 42.20.2 delivered it as PlayerVisitedPacket, whose processClient copied
--     the server's buffer in and then re-ran setKnownInCells over the whole
--     metagrid if MapAllKnown was on.
--   * 42.20.3+ delivers it as RequestID.PlayerVisited
--     (RequestDataPacket.java:304-306 -> WorldMapVisited.receiveRequestData,
--     WorldMapVisited.java:548-571). That copies the server's buffer straight
--     over `visited` and never re-applies MapAllKnown.
--
-- The server's per-user copy (WorldMapVisitedServer) never carries the known
-- bits, so the buffer arriving is "only what you walked", and it wins either
-- way the race goes: if it lands first, the instance is created by
-- getInstance(false), which skips the MapAllKnown pass; if the per-tick
-- WorldMapVisited.update() (IngameState.java:775) creates the instance first,
-- the pass runs (WorldMapVisited.java:806-814) and the download then erases it.
--
-- Nothing tells Lua when the download lands - it is requested mid-load from
-- WorldMapClient.worldMapLoaded (IsoWorld.java:2069) and finishes whenever it
-- finishes. So this watches for the symptom instead: once a second (wall
-- clock, because OnTick sags under load), ask whether the two corner cells of
-- the metagrid are known. Corners are ocean or map edge, never walked, so an
-- unknown corner means something took the known bits away - the download, or
-- the player pressing "Forget map", which under MapAllKnown should not stick
-- either. Re-marking every cell flips real bits, which marks the whole map
-- texture dirty (WorldMapVisited.java:597-617), so the picture refreshes too;
-- receiveRequestData alone never dirties it.
--
-- Deliberately client-only. Seeding the server's per-user file instead would
-- need a wire command (no server Lua event fires for a returning player, and
-- the server snapshots the buffer at request time, RequestDataPacket
-- doProcessRequest, so a seed can never reach the session that asked), and it
-- would write the known bits into every player's server file for good - turning
-- MapAllKnown off afterwards would no longer hide anything. Here, turning the
-- option off takes effect at the next login.
--
-- The switch is the vanilla option itself; see OEShared for why this module
-- has no kill switch of its own.

if isServer() then return end

require "OEShared"

RandMcNally = RandMcNally or {}
local RM = RandMcNally

RM.POLL_MS = 1000          -- sentinel cadence
RM.LOG_CAP = 10            -- re-apply lines printed per session; later ones only count

local startMs = nil        -- nil until OnGameStart decided to watch
local nextPollMs = 0
RM.reapplied = 0

local function allKnownOn()
    return SandboxVars and SandboxVars.Map and SandboxVars.Map.MapAllKnown == true
end

-- A point inside a cell's middle: isKnown(x, y) tests the 3x3 squares around
-- it with any-hit semantics (WorldMapVisited.java:773-776), so a cell-centre
-- probe cannot straddle into a neighbouring cell.
local function cellCentre(cell)
    return cell * 256 + 128
end

-- One pass: re-mark the whole metagrid known if either corner has lost it.
-- Returns true when it re-applied.
function RM.check(nowMs)
    if not allKnownOn() then return false end
    local visited = WorldMapVisited.getInstance()
    local grid = getWorld():getMetaGrid()
    local x1, y1 = grid:getMinX(), grid:getMinY()
    local x2, y2 = grid:getMaxX(), grid:getMaxY()
    if visited:isKnown(cellCentre(x1), cellCentre(y1))
        and visited:isKnown(cellCentre(x2), cellCentre(y2)) then
        return false
    end
    visited:setKnownInCells(x1, y1, x2, y2)
    RM.reapplied = RM.reapplied + 1
    if RM.reapplied <= RM.LOG_CAP then
        print(string.format("[OE] RandMcNally: map re-marked known (#%d, %.1fs after game start)%s",
            RM.reapplied, (nowMs - startMs) / 1000,
            RM.reapplied == RM.LOG_CAP and "; further re-applies counted, not printed" or ""))
    end
    return true
end

local function onTick()
    local now = getTimestampMs()
    if now < nextPollMs then return end
    nextPollMs = now + RM.POLL_MS
    RM.check(now)
end

-- Singleplayer and the dedicated server are left to the engine: singleplayer
-- takes the load path that still applies the option, and only a client
-- receives the download that erases it. A hosted game's host is a client.
function RM.start()
    if startMs or not isClient() then return end
    if not allKnownOn() then
        print("[OE] RandMcNally: Map All Known is off; not watching")
        return
    end
    startMs = getTimestampMs()
    nextPollMs = startMs
    Events.OnTick.Add(onTick)
    print("[OE] RandMcNally: Map All Known is on; re-applying it after the server's map data arrives")
end

Events.OnGameStart.Add(RM.start)

return RandMcNally

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
