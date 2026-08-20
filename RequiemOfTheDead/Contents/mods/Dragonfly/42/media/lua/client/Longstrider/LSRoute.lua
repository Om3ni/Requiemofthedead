-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSRoute - a pasted CSV of waypoints, walked on a MANUAL trigger.
--
-- The populate tour (LSTour) sweeps a region on a dwell timer because its job
-- is coverage: every cell, hands-off. This is the other job: the admin has a
-- specific list of places - a patrol line, a chain of POIs, an incident list -
-- and wants to LOOK at each one for as long as it takes, which no timer can
-- know. So the route advances only when the admin says Next, and there is no
-- tick driver at all: between steps this module is inert state.
--
-- Input is one `x,y[,z]` per line. Parsing follows the LSTours file pattern:
-- validate PER LINE, skip-and-name bad rows, never abort on the first - a
-- pasted spreadsheet column with a header row should cost the header, not the
-- paste. The parse is pure Lua with no engine surface, so it runs under
-- tools/run-tests.bat with zero stubs.
--
-- The teleport/protection lifecycle is LSTour's, shared deliberately:
-- applyProtection/restoreProtection are its exports, RDTeleport.toCoords is
-- the family's one gated coordinate teleport, and finish() carries the same
-- two pinned properties the tour's review established - TEARDOWN FIRST (state
-- goes idle before any restoration work can fail) and TELEPORT HOME WHILE
-- PROTECTED (the admin rides home god/invisible rather than standing mortal
-- wherever the route ended). One admin has one body: a route refuses to start
-- while a tour runs, and vice versa, because two independent protection
-- snapshots would restore each other's flags.

if isServer() then return end

require "Longstrider/LSTour"   -- the shared protection lifecycle lives there

LSRoute = LSRoute or {}

LSRoute.state = LSRoute.state or {
    active  = false,
    wps     = nil,     -- ordered list of { x, y, z }
    idx     = 0,
    total   = 0,
    start   = nil,     -- { x, y, z } pre-route position
    protect = nil,
    player  = nil,
}

-- ---------------------------------------------------------------------------
-- Parse
-- ---------------------------------------------------------------------------

-- One line -> waypoint or (nil, reason). Split out so the reason strings live
-- next to the rules they describe.
local function parseLine(line)
    -- Append-a-comma split. The naive `gmatch(line, "([^,]*)")` is WRONG in
    -- 5.1: a *-quantified class matches the empty string after every real
    -- segment, so "3,4" yields FOUR fields ("3","","4","") - verified against
    -- the real interpreter before this shipped. Anchoring each field to its
    -- terminating comma makes the count exact, and a trailing comma reads as
    -- an explicit empty field that fails below with its own named reason
    -- rather than being silently shrugged off.
    local fields = {}
    for f in string.gmatch(line .. ",", "([^,]*),") do
        fields[#fields + 1] = f
    end
    if #fields < 2 then return nil, "expected x,y or x,y,z" end
    if #fields > 3 then return nil, "too many fields (" .. #fields .. ")" end
    local x = tonumber((string.gsub(fields[1], "%s", "")))
    local y = tonumber((string.gsub(fields[2], "%s", "")))
    if not x then return nil, "x is not a number: '" .. fields[1] .. "'" end
    if not y then return nil, "y is not a number: '" .. fields[2] .. "'" end
    local z = 0
    if fields[3] then
        z = tonumber((string.gsub(fields[3], "%s", "")))
        if not z then return nil, "z is not a number: '" .. fields[3] .. "'" end
    end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

-- CSV text -> (waypoints, skipped). skipped rows are { line, text, reason },
-- with `line` numbered as the admin sees the paste (1-based, blanks counted),
-- so "row 1: x is not a number" points straight at a header row.
function LSRoute.parse(text)
    local wps, skipped = {}, {}
    local n = 0
    for line in string.gmatch(tostring(text or "") .. "\n", "(.-)\r?\n") do
        n = n + 1
        local trimmed = string.match(line, "^%s*(.-)%s*$")
        if trimmed ~= "" then
            local wp, reason = parseLine(trimmed)
            if wp then
                wps[#wps + 1] = wp
            else
                skipped[#skipped + 1] = { line = n, text = trimmed, reason = reason }
            end
        end
    end
    return wps, skipped
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

local function finish(reason)
    local s = LSRoute.state

    -- TEARDOWN FIRST, unconditionally - the same structural property the
    -- tour's finish() was reordered to have (see LSTour.finish and the
    -- 2026-08-18 review note). There is no tick handler to remove here, so the
    -- teardown is just the state: by the time anything below can fail, the
    -- route is already idle and a stuck-protected admin cannot also be a
    -- stuck-running route.
    local start, player, protect = s.start, s.player, s.protect
    local idx, total = s.idx, s.total
    s.active = false
    s.wps, s.idx, s.total = nil, 0, 0
    s.start, s.protect, s.player = nil, nil, nil

    -- ORDER MATTERS, same one place as the tour: teleport home BEFORE
    -- protection drops, so the admin rides home god/invisible instead of
    -- standing mortal at the last waypoint. Both calls are the tour's own
    -- verified non-throwing surfaces (RDTeleport.lua:31-49 returns
    -- false+reason; restoreProtection nil-checks and its setters are EnumSet
    -- flag ops).
    if start then RDTeleport.toCoords(start.x, start.y, start.z) end
    LSTour.restoreProtection(player, protect)
    DFCore.audit("Longstrider route " .. tostring(reason), player,
        string.format("(%d/%d waypoints)", idx, total))
end

-- Begin walking. Returns true, or false + reason the tab shows the admin.
function LSRoute.start(wps)
    if LSRoute.state.active then return false, "A route is already running." end
    if LSTour.state and LSTour.state.running then
        return false, "A populate tour is running - abort it first."
    end
    if not wps or #wps == 0 then return false, "No waypoints." end
    local player = getPlayer()
    if not player then return false, "No player." end

    local s = LSRoute.state
    s.wps     = wps
    s.total   = #wps
    s.idx     = 1
    s.player  = player
    s.start   = { x = math.floor(player:getX()), y = math.floor(player:getY()),
                  z = math.floor(player:getZ()) }
    s.protect = LSTour.applyProtection(player)
    s.active  = true

    DFCore.audit("Longstrider route started", player,
        string.format("(%d waypoints)", s.total))

    local wp = wps[1]
    RDTeleport.toCoords(wp.x, wp.y, wp.z)
    return true
end

-- The manual trigger. Advancing past the last waypoint is how a route ENDS
-- WELL - Next reads "done" on the button at that point, so finishing is the
-- same gesture as advancing, not a separate thing to remember.
function LSRoute.next()
    local s = LSRoute.state
    if not s.active then return end
    if s.idx >= s.total then
        finish("completed")
        return
    end
    s.idx = s.idx + 1
    local wp = s.wps[s.idx]
    RDTeleport.toCoords(wp.x, wp.y, wp.z)
end

function LSRoute.abort()
    if not LSRoute.state.active then return end
    finish("aborted")
end

function LSRoute.status()
    local s = LSRoute.state
    return { active = s.active, idx = s.idx, total = s.total }
end

-- Dragonfly Longstrider v0.3.0
return LSRoute

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
