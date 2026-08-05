-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSTour - the populate runner: teleport the admin cell-by-cell, dwell, repeat.
--
-- UI-independent Events.OnTick singleton, so a running sweep survives tab
-- switches and closing the Dragonfly panel. Takes a QUEUE of jobs (one per
-- tour region) so "Run Selected" passes one job and "Run All" passes many; the
-- cells of every job are flattened into a single serpentine sweep.
--
-- Teleport is the vanilla /teleportto (server authoritative). The admin is
-- god+invisible+ghost for the duration so the freshly-spawned horde can't touch
-- them, and is returned to the start position when the sweep finishes/aborts.

if isServer() then return end

LSTour = LSTour or {}

local DEFAULT_DWELL_MS = 2500

LSTour.state = LSTour.state or {
    running  = false,
    phase    = "idle",
    cells    = nil,      -- flat list of { x1,y1,x2,y2 } world rects (all jobs)
    centers  = nil,      -- flat list of { cx, cy }
    jobName  = nil,      -- flat list of job names, parallel to cells
    idx      = 0,
    total    = 0,
    dwellMs  = DEFAULT_DWELL_MS,
    nextAtMs = 0,
    start    = nil,      -- { x, y, z } pre-tour position
    protect  = nil,
    player   = nil,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function nowMs()
    -- getTimestampMs (ms since launch) is the primary clock; getTimeInMillis is a
    -- fallback. We deliberately return nil (NOT 0) on total failure: a 0 here makes
    -- "nowMs() < nextAtMs" always true, which would wedge the tour at cell 1 with
    -- protection stuck on. _onTick treats nil as a dead clock and aborts cleanly.
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" then return v end
    ok, v = pcall(getTimeInMillis)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Serpentine (boustrophedon) cell list for one region.
function LSTour.computeCells(region, cellSize)
    local cells, centers = {}, {}
    if not region then return cells, centers end
    local x1, y1, x2, y2 = region[1], region[2], region[3], region[4]
    local cs = math.max(1, math.floor(cellSize or 50))
    local cols = math.max(1, math.ceil((x2 - x1) / cs))
    local rows = math.max(1, math.ceil((y2 - y1) / cs))
    for r = 0, rows - 1 do
        local cy1 = y1 + r * cs
        local cy2 = math.min(y1 + (r + 1) * cs, y2)
        local a, b, step
        if r % 2 == 0 then a, b, step = 0, cols - 1, 1 else a, b, step = cols - 1, 0, -1 end
        for c = a, b, step do
            local cx1 = x1 + c * cs
            local cx2 = math.min(x1 + (c + 1) * cs, x2)
            cells[#cells + 1]   = { math.floor(cx1), math.floor(cy1), math.floor(cx2), math.floor(cy2) }
            centers[#centers + 1] = { math.floor((cx1 + cx2) / 2), math.floor((cy1 + cy2) / 2) }
        end
    end
    return cells, centers
end

-- Total cell count for a list of jobs ({ name, region }), used for cap/ETA.
function LSTour.countCells(jobs, cellSize)
    local n = 0
    for _, j in ipairs(jobs or {}) do
        local cells = LSTour.computeCells(j.region, cellSize)
        n = n + #cells
    end
    return n
end

local function teleportTo(x, y, z)
    -- RDTeleport is the family's single gated coordinate teleport (Core). The
    -- capability check moved inside it; the preflight in LSTab still refuses
    -- the whole tour up front so a run cannot start and then stall on step one.
    RDTeleport.toCoords(x, y, z)
end

local function applyProtection(player)
    local snap = {}
    pcall(function() snap.god   = player:isGodMod()    end)
    pcall(function() snap.invis = player:isInvisible() end)
    pcall(function() snap.ghost = player:isGhostMode() end)
    pcall(function() player:setGodMod(true)    end)
    pcall(function() player:setInvisible(true) end)
    pcall(function() player:setGhostMode(true) end)
    return snap
end

local function restoreProtection(player, snap)
    if not player or not snap then return end
    pcall(function() player:setGodMod(snap.god == true)      end)
    pcall(function() player:setInvisible(snap.invis == true) end)
    pcall(function() player:setGhostMode(snap.ghost == true) end)
end

-- ---------------------------------------------------------------------------
-- Tick driver
-- ---------------------------------------------------------------------------

local function gotoStop(idx)
    local s = LSTour.state
    s.idx = idx
    local c = s.centers[idx]
    local z = (s.start and s.start.z) or 0
    teleportTo(c[1], c[2], z)
    s.phase    = "dwelling"
    s.nextAtMs = (nowMs() or 0) + s.dwellMs
end

local function finish(reason)
    local s = LSTour.state
    -- Best-effort cleanup, each step guarded so a failure (disconnected player,
    -- SendCommandToServer unavailable) can NEVER skip the teardown below -
    -- otherwise the tour stays "running" with the tick handler live and the
    -- admin stuck in god/invisible. restoreProtection is already internally
    -- guarded; the teleport-back is the one that could throw, so wrap it.
    pcall(function() if s.start then teleportTo(s.start.x, s.start.y, s.start.z) end end)
    pcall(restoreProtection, s.player, s.protect)
    pcall(function()
        DFCore.audit("Longstrider tour " .. tostring(reason), s.player,
            string.format("(%d/%d cells)", s.idx, s.total))
    end)
    Events.OnTick.Remove(LSTour._onTick)
    s.running = false
    s.phase   = "idle"   -- resting state, ready for a clean next start()
    s.cells, s.centers, s.jobName = nil, nil, nil
end

LSTour._onTick = function()
    local s = LSTour.state
    if not s.running then return end
    local now = nowMs()
    if not now then finish("aborted (no usable clock)"); return end
    if now < s.nextAtMs then return end
    if s.phase == "dwelling" then
        if s.idx >= s.total then finish("completed")
        else gotoStop(s.idx + 1) end
    end
end

-- ---------------------------------------------------------------------------
-- Control
-- ---------------------------------------------------------------------------

-- jobs = list of { name, region }; opts = { dwellMs }
function LSTour.start(jobs, cellSize, opts)
    if LSTour.state.running then return false, "A tour is already running." end
    local player = getPlayer()
    if not player then return false, "No player." end

    local cells, centers, jobName = {}, {}, {}
    for _, j in ipairs(jobs or {}) do
        local jc, jcen = LSTour.computeCells(j.region, cellSize)
        for i = 1, #jc do
            cells[#cells + 1]   = jc[i]
            centers[#centers + 1] = jcen[i]
            jobName[#jobName + 1] = j.name or "?"
        end
    end
    if #cells == 0 then return false, "No cells to populate." end

    local s = LSTour.state
    s.cells, s.centers, s.jobName = cells, centers, jobName
    s.total   = #cells
    s.idx     = 0
    s.dwellMs = math.max(250, math.floor((opts and opts.dwellMs) or DEFAULT_DWELL_MS))
    s.player  = player
    s.start   = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
    s.protect = applyProtection(player)
    s.running = true

    pcall(function()
        DFCore.audit("Longstrider tour started", player,
            string.format("(%d cells, %d region(s))", s.total, #jobs))
    end)

    Events.OnTick.Remove(LSTour._onTick)
    Events.OnTick.Add(LSTour._onTick)
    gotoStop(1)
    return true
end

function LSTour.abort()
    if not LSTour.state.running then return end
    finish("aborted")
end

function LSTour.status()
    local s = LSTour.state
    local remaining = s.running and math.max(0, s.total - s.idx) or 0
    return {
        running = s.running,
        idx     = s.idx,
        total   = s.total,
        cells   = s.cells,
        etaMs   = remaining * s.dwellMs,
        jobName = s.running and s.jobName and s.jobName[s.idx] or nil,
    }
end

-- Dragonfly Longstrider v0.3.0
return LSTour

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
