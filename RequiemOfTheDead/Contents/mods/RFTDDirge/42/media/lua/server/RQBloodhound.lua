-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQBloodhound.lua - a ranged attacker becomes the struck special's quarry.
--
-- THE PROBLEM. A player who shoots a Juggernaut from thirty tiles away and then
-- walks backwards is not in a fight; they are performing maintenance. Bulwark
-- makes each shot worth less, but soaking alone cannot answer kiting - it just
-- makes the same safe exchange take longer. What closes it is the target coming
-- for you specifically.
--
-- WHY DIRECT TARGETING AND NOT A WORLD SOUND. addSound is a spatial broadcast:
-- WorldSoundManager.addSound puts the sound on the global and chunk lists and
-- every eligible zombie inside the hearing radius may answer it
-- (WorldSoundManager.java:73-156). It cannot address ONE zombie, and using it
-- here would drag the neighbourhood towards a shooter as a side effect of a
-- mechanic that is supposed to be personal. setTarget names the exact quarry and
-- asks for a network-zombie update when it changes (IsoZombie.java:4451-4458).
--
-- WHY AN EXPLICIT STATE MACHINE AND NOT JUST AGGRO. Aggro decays over roughly
-- ten seconds (IsoZombie.java:4961-4981), so one synthetic entry buys a few
-- seconds of interest and then evaporates. Worse, the server only adds aggro for
-- zombies it owns - IsoZombie.Hit's addAggro call is gated on
-- `GameServer.server && !isRemoteZombie()` (:1110-1112) - so for a
-- client-owned zombie there is no aggro contribution to lean on at all. Pursuit
-- is therefore tracked here, with a bounded life and a guaranteed restore.
--
-- SCOPE. Boss, Juggernaut, and enraged Scavenger only. Screamers, EMP zombies,
-- Gluttons and passive Scavengers all have casting or eating state machines that
-- forced movement would fight; adding them is a behaviour decision, not a
-- freebie from sharing the hit intake.
-- =============================================

if not isServer() then return end

require "RQCommon"
require "RQDirgeLog"
require "RQSvShared"
require "RQSvScavenger"

RQBloodhound = RQBloodhound or {}

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local CLOSE_DISTANCE   = 5        -- tiles; pursuit ends when the gap is closed
local PURSUIT_TIMEOUT  = 30000    -- ms; a safety boundary, not a stealth reprieve
local REPATH_INTERVAL  = 1000     -- ms; floor between path requests

-- REPATH_MOVE_SQ and MAX_PATH_FAILS were removed 2026-08-24, for two different
-- reasons worth keeping straight.
--
-- REPATH_MOVE_SQ gated repaths on the quarry having moved three tiles. ANDed
-- with the interval, that meant a stationary shooter never got a second path
-- request - see the note in aim(). Deleted rather than rewired: with the clock
-- doing the work, a movement term could only make the gate stricter again.
--
-- MAX_PATH_FAILS counted something nothing could count. `pathFails` was seeded
-- to 0, reset to 0 on refresh, tested here - and never incremented anywhere,
-- because pathToCharacter is void and its one failure mode (the allowRepathDelay
-- lockout) is silent. So the "path-failed" exit could never fire. A zombie that
-- genuinely cannot reach its quarry already exits on PURSUIT_TIMEOUT, which is
-- what was actually retiring those pursuits all along. Detecting a real path
-- failure needs a signal we do not have yet; TODO.md carries it.

RQBloodhound.CLOSE_DISTANCE  = CLOSE_DISTANCE
RQBloodhound.PURSUIT_TIMEOUT = PURSUIT_TIMEOUT
-- Exported so the fixture can drive the repath cadence off the real number
-- instead of a copy. A fixture holding its own 1000 would keep passing if this
-- constant were retuned, which is exactly how the old movement-gated repath
-- stayed green while the chase was broken in the field.
RQBloodhound.REPATH_INTERVAL = REPATH_INTERVAL

local PURSUES = { Boss = true, Juggernaut = true, Scavenger = true }

-- Weak-keyed: a pursuit must never be the reason a dead zombie stays reachable.
-- The engine pools and recycles zombie objects, so holding one strongly here
-- would be a leak with a very long fuse.
local pursuits = setmetatable({}, { __mode = "k" })
RQBloodhound.pursuits = pursuits

RQBloodhound.stats = {
    acquired    = 0,
    replaced    = 0,
    refreshed   = 0,
    sprinted    = 0,
    restored    = 0,
    repaths     = 0,
    exits       = {},   -- reason -> count
    refused     = {},   -- reason -> count
}

local function refuse(reason)
    local r = RQBloodhound.stats.refused
    r[reason] = (r[reason] or 0) + 1
    return nil
end

-- ---------------------------------------------------------------------------
-- Quarry validity
-- ---------------------------------------------------------------------------
-- A quarry stops being one when it dies, disconnects, goes invisible or into
-- ghost mode, or loses a square. The invisibility clause matters: an admin
-- watching a fight must not be chased by it, and RQSvShared already draws that
-- line for every other zombie behaviour in the mod.
local function quarryValid(player)
    if not player then return false end
    if player:isDead() then return false end
    if player:isInvisible() or player:isGhostMode() then return false end
    return player:getSquare() ~= nil
end

local function distSqBetween(zombie, player)
    local dx = player:getX() - zombie:getX()
    local dy = player:getY() - zombie:getY()
    return dx * dx + dy * dy
end

-- ---------------------------------------------------------------------------
-- Exit
-- ---------------------------------------------------------------------------
-- EVERY exit path funnels through here, which is the point: there is exactly one
-- place that can leave a zombie sprinting, and it is this function failing to be
-- called. Restoration is attempted even when the zombie is invalid, because the
-- common case for "invalid" is virtualization rather than death and the object
-- may well be handed back to us later.
--
-- The Boss is the deliberate exception. It is a permanent sprinter, applied at
-- conversion and again on reload; restoring it to its captured profile would be
-- correct bookkeeping and wrong behaviour.
function RQBloodhound.endPursuit(zombie, reason)
    local st = pursuits[zombie]
    if not st then return false end
    pursuits[zombie] = nil

    local stats = RQBloodhound.stats
    stats.exits[reason] = (stats.exits[reason] or 0) + 1

    if st.sprintApplied and st.zType ~= "Boss" then
        if RQSvShared.restoreMovementProfile(zombie, st.profile) then
            stats.restored = stats.restored + 1
        end
    end

    if RQSvShared.getSvConfig().debugMode then
        RQDirgeLog.write("Bloodhound", "[INFO] pursuit ended type=" .. tostring(st.zType)
            .. " reason=" .. reason
            .. " sprint=" .. tostring(st.sprintApplied)
            .. " repaths=" .. st.repaths)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Acquisition
-- ---------------------------------------------------------------------------
-- Called by RQSvHit for every hit, and refuses everything that is not a ranged
-- player attack on one of the three types. A soaked hit still arrives here: the
-- shot missing its damage does not make it less of a provocation.
function RQBloodhound.onAttacked(ctx)
    if not ctx.isRanged then return refuse("not-ranged") end
    if not PURSUES[ctx.zType] then return refuse("type-not-pursuing") end
    if ctx.zType == "Scavenger" and not RQSvScavenger.isEnraged(ctx.zombie) then
        return refuse("scavenger-passive")
    end
    if not quarryValid(ctx.attacker) then return refuse("invalid-quarry") end

    local zombie = ctx.zombie
    local st = pursuits[zombie]
    local stats = RQBloodhound.stats

    if st then
        -- REFRESH. The movement snapshot is NOT retaken - it was captured before
        -- the first sprint was applied, and re-capturing now would record the
        -- sprint as this zombie's native profile and strand it there forever.
        st.refreshedAt = ctx.now
        if st.quarry ~= ctx.attacker then
            -- Most recent shooter wins. Predictable to read from the outside,
            -- and it stops one historical high-damage attacker from owning a
            -- special while somebody else shoots it with impunity.
            st.quarry = ctx.attacker
            stats.replaced = stats.replaced + 1
            RQBloodhound.aim(zombie, st, ctx.now, true)
        else
            stats.refreshed = stats.refreshed + 1
        end
        return true
    end

    st = {
        quarry       = ctx.attacker,
        zType        = ctx.zType,
        startedAt    = ctx.now,
        refreshedAt  = ctx.now,
        lastRepathAt = 0,
        -- repaths counts REQUESTS, not journeys. The engine may silently
        -- discard any of them (allowRepathDelay - see aim()), and a void
        -- method cannot tell us which, so this is a measure of how hard we
        -- asked rather than of how often the zombie actually re-pathed. It is
        -- read that way in the pursuit-ended line and nowhere else.
        repaths      = 0,
        profile      = RQSvShared.captureMovementProfile(zombie),
        sprintApplied = false,
    }
    pursuits[zombie] = st
    stats.acquired = stats.acquired + 1

    -- The Boss already runs. Applying the sprint profile again would be
    -- harmless but it would also set sprintApplied, and the exit path uses that
    -- flag; leaving it false keeps "we changed this zombie's movement" honest.
    if ctx.zType ~= "Boss" then
        RQSvShared.applySprintProfile(zombie)
        st.sprintApplied = true
        stats.sprinted = stats.sprinted + 1
    end

    RQBloodhound.aim(zombie, st, ctx.now, true)

    if RQSvShared.getSvConfig().debugMode then
        RQDirgeLog.write("Bloodhound", "[INFO] acquired type=" .. ctx.zType
            .. " sprint=" .. tostring(st.sprintApplied)
            .. " dist=" .. string.format("%.1f", math.sqrt(distSqBetween(zombie, ctx.attacker))))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Aim
-- ---------------------------------------------------------------------------
-- setTarget on an unchanged target is a cheap no-op in Java, but pathToCharacter
-- is not free, so repaths are bounded. The engine declines a redundant repath
-- itself while the zombie is already in a pathing state
-- (IsoZombie.pathToCharacter, :943-948) - this bound sits on top of that rather
-- than pretending to be the only thing standing between us and a path storm.
--
-- addAggro is called once per acquisition, not per tick. It is a nudge that puts
-- the shooter at the head of the threat list, not the mechanism keeping the
-- pursuit alive; that is what this module's own state is for.
function RQBloodhound.aim(zombie, st, now, force)
    local quarry = st.quarry
    zombie:setTarget(quarry)
    if force then
        zombie:addAggro(quarry, 1.0)
    end

    -- REPATH ON THE CLOCK ALONE. This used to also require the quarry to have
    -- moved three tiles, which meant a shooter who STOOD STILL AND SNIPED - the
    -- exact scenario this module exists for - never earned a single repath
    -- after the forced one at acquire. The 2026-08-24 session measured it:
    -- repaths=1 across a 30-second pursuit, where the interval calls for
    -- roughly thirty. One Boss timed out 14 tiles from a stationary player.
    --
    -- The old gate also contradicted its own constants, which is how it should
    -- have been caught by reading: REPATH_INTERVAL is documented as a "floor
    -- between path requests" and the movement distance as earning an "early"
    -- repath. Both describe a clock with an accelerator, not a clock ANDed with
    -- a condition that is false whenever the target is standing still.
    --
    -- Retrying on the clock also recovers from a drop we cannot otherwise see.
    -- IsoZombie.pathToCharacter:943-948 silently returns without doing anything
    -- when allowRepathDelay > 0 and the zombie is already in PathFindState,
    -- WalkTowardState or WalkTowardNetworkState - and the engine sets that to
    -- 480 (:1942, :2316), decremented by GameTime.getMultiplier() per tick
    -- (:2814), so roughly eight seconds at 60Hz. The call is void and cannot
    -- report the drop, so the only correct response is to keep asking; the
    -- first request after the lockout expires is the one that lands.
    if force or (now - st.lastRepathAt) >= REPATH_INTERVAL then
        zombie:pathToCharacter(quarry)
        st.lastRepathAt = now
        st.repaths = st.repaths + 1
        RQBloodhound.stats.repaths = RQBloodhound.stats.repaths + 1
    end
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------
-- Driven from the orchestrator's behaviour pass, and it walks ONLY zombies with
-- an active pursuit - never the whole special registry. Returns the number still
-- pursuing so the caller can see the set is bounded.
function RQBloodhound.update(now)
    local live = 0
    local ending = nil
    for zombie, st in pairs(pursuits) do
        local reason = nil

        if zombie:isDead() then
            reason = "zombie-dead"
        elseif not quarryValid(st.quarry) then
            reason = "quarry-invalid"
        elseif (now - st.refreshedAt) >= PURSUIT_TIMEOUT then
            -- A safety boundary, NOT a stealth forgiveness rule. Its job is to
            -- stop a special sprinting at a wall forever because the shooter is
            -- across a broken path or sealed in a room.
            reason = "timeout"
        elseif distSqBetween(zombie, st.quarry) <= (CLOSE_DISTANCE * CLOSE_DISTANCE) then
            -- Closing the gap ends the SPEED, not the interest. The target is
            -- left set and ordinary zombie AI takes it from here; a fresh ranged
            -- hit can start another pursuit.
            reason = "closed"
        end

        if reason then
            ending = ending or {}
            ending[#ending + 1] = { zombie, reason }
        else
            live = live + 1
            RQBloodhound.aim(zombie, st, now, false)
        end
    end

    -- Mutating `pursuits` during its own pairs() walk is the one thing that
    -- would make this loop unsafe, so exits are collected and applied after.
    if ending then
        for i = 1, #ending do
            RQBloodhound.endPursuit(ending[i][1], ending[i][2])
        end
    end
    return live
end

-- Reset hook for game start, mirroring the other server modules. Restores
-- everything first: a reset that dropped the table would leave any live
-- sprinter stuck at speed.
function RQBloodhound.reset()
    local all = {}
    for zombie in pairs(pursuits) do all[#all + 1] = zombie end
    for i = 1, #all do RQBloodhound.endPursuit(all[i], "reset") end
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
