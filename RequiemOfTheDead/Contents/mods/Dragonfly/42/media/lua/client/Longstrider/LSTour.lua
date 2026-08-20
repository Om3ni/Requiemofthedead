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
    -- fallback. Both are System.currentTimeMillis in 42.20.2 (LuaManager:7470/:3512)
    -- and cannot throw; the type() checks cover a build where the GLOBAL is absent,
    -- which indexing never throws on. We deliberately return nil (NOT 0) on total
    -- failure: a 0 here makes "nowMs() < nextAtMs" always true, which would wedge
    -- the tour at cell 1 with protection stuck on. _onTick treats nil as a dead
    -- clock and aborts cleanly.
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    if type(getTimeInMillis) == "function" then return getTimeInMillis() end
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

-- How many cells a region WOULD produce, without building any of them.
--
-- computeCells materialises every cell as two four-number tables, which is the
-- right thing when a tour is about to walk them and the wrong thing for a
-- readout. The readout is the hot one: LSTab recomputes on every handle release
-- and on every Cell-size keystroke, and since regions are no longer clamped at
-- drag time (LSGridOverlay - the cap is a *run* limit, not a drawing limit) an
-- admin can legitimately have a region on screen that would be millions of
-- cells. Counting must therefore be O(1) and allocate nothing.
--
-- The arithmetic is lifted verbatim from computeCells' own loop bounds rather
-- than re-derived, so the count and the walk cannot disagree about what a
-- region contains.
function LSTour.cellCountOf(region, cellSize)
    if not region then return 0 end
    local cs = math.max(1, math.floor(cellSize or 50))
    local cols = math.max(1, math.ceil((region[3] - region[1]) / cs))
    local rows = math.max(1, math.ceil((region[4] - region[2]) / cs))
    return cols * rows
end

-- Total cell count for a list of jobs ({ name, region }), used for cap/ETA.
function LSTour.countCells(jobs, cellSize)
    local n = 0
    for _, j in ipairs(jobs or {}) do
        n = n + LSTour.cellCountOf(j.region, cellSize)
    end
    return n
end

local function teleportTo(x, y, z)
    -- RDTeleport is the family's single gated coordinate teleport (Core). The
    -- capability check moved inside it; the preflight in LSTab still refuses
    -- the whole tour up front so a run cannot start and then stall on step one.
    RDTeleport.toCoords(x, y, z)
end

-- Direct calls, no guards: the cheat accessors are EnumSet flag ops on a
-- field-initialised PlayerCheats behind null-checked capability reads
-- (IsoGameCharacter:10943-11068, IsoPlayer:1055-1064, Role.hasCapability:176)
-- - they cannot throw on a non-nil player, and both callers check that.
--
-- EXPORTED (2026-08-20), not local: LSRoute walks a pasted waypoint list under
-- the same god/invisible/ghost envelope, and a second copy of the snapshot
-- shape is how the two would eventually restore different flag sets. The
-- module boundary is honest - this file owns "teleport the admin around,
-- protected", and the route is another consumer of exactly that.
function LSTour.applyProtection(player)
    local snap = {}
    snap.god   = player:isGodMod()
    snap.invis = player:isInvisible()
    snap.ghost = player:isGhostMode()
    player:setGodMod(true)
    player:setInvisible(true)
    player:setGhostMode(true)
    return snap
end

function LSTour.restoreProtection(player, snap)
    if not player or not snap then return end
    player:setGodMod(snap.god == true)
    player:setInvisible(snap.invis == true)
    player:setGhostMode(snap.ghost == true)
end

local applyProtection   = LSTour.applyProtection
local restoreProtection = LSTour.restoreProtection

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

    -- TEARDOWN FIRST, and unconditionally.
    --
    -- This used to run LAST, behind two guards whose only job was to ensure a
    -- failure above could not skip it - the failure being an admin left in
    -- god/invisible with a live tick handler, which is a genuinely bad outcome.
    -- But that is an ORDERING problem wearing a guard as a disguise: Lua has no
    -- `finally`, so pcall was standing in for one. Doing the teardown first
    -- makes the property structural instead of caught. By the time anything
    -- below can fail, the handler is already gone and the state is already
    -- idle, so there is nothing left for a guard to protect.
    local start, player, protect = s.start, s.player, s.protect
    local idx, total = s.idx, s.total
    Events.OnTick.Remove(LSTour._onTick)
    s.running = false
    s.phase   = "idle"   -- resting state, ready for a clean next start()
    s.cells, s.centers, s.jobName = nil, nil, nil

    -- Restoration and reporting, bare and loud. ORDER MATTERS in one place:
    -- the teleport-back fires BEFORE protection drops, so the admin rides home
    -- god/invisible instead of standing mortal in the cell this tour just
    -- filled with zombies. (Review finding, 2026-08-18: the first rewrite
    -- restored flags first and reopened exactly that window - the pre-refactor
    -- code teleported first for a reason nobody had written down.)
    -- RDTeleport.toCoords (RDTeleport.lua:31-49) coerces its coordinates,
    -- nil-checks the player, nil-chains the capability test, and RETURNS
    -- false+reason rather than throwing. restoreProtection nil-checks its
    -- inputs and its setters cannot throw (see applyProtection). DFCore.audit
    -- (DFCore.lua:73-77) nil-chains getUsername, tostring's every field and
    -- prints - its only guarded work is server-side, and this is client code.
    if start then teleportTo(start.x, start.y, start.z) end
    restoreProtection(player, protect)
    DFCore.audit("Longstrider tour " .. tostring(reason), player,
        string.format("(%d/%d cells)", idx, total))
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
    -- One admin has one body and one protection snapshot. A route holds the
    -- god/invisible envelope too, and starting a tour on top would snapshot
    -- the ROUTE's protected flags as "what to restore" - ending with the admin
    -- permanently god. Read at call time: LSRoute loads before this file on
    -- the alphabetical walk, but a nil LSRoute (route feature absent) must
    -- mean "no route", not a crash.
    if LSRoute and LSRoute.state and LSRoute.state.active then
        return false, "A route is running - end it first."
    end
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

    -- No guard: on the client DFCore.audit is a nil-chained getUsername, a
    -- string.format and a print (DFCore.lua:73-77). Its one guarded call is
    -- inside the isServer() branch, which cannot be reached from here.
    DFCore.audit("Longstrider tour started", player,
        string.format("(%d cells, %d region(s))", s.total, #jobs))

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
