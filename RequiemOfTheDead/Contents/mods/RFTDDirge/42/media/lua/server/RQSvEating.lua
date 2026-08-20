-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvEating.lua
-- Shared eating engine for Glutton and Scavenger. Handles corpse reservation,
-- finding bodies, devour cast startup, and the pending-arrival drain.
-- Both zombie types pipe through here so the logic stays in one place.

if not isServer() then return end

local RQSvShared = RQSvShared

local broadcast       = RQSvShared.broadcast
local makeCastArgs    = RQSvShared.makeCastArgs
local getSvConfig     = RQSvShared.getSvConfig
local COLORS          = RQSvShared.COLORS
local SCAV_CORPSE_RADIUS = RQSvShared.SCAV_CORPSE_RADIUS

RQSvEating = RQSvEating or {}

-- Per-eat share of the multiplier accumulator (state.totalMultGain). Each
-- solo eat adds this; co-eaters split it (shareEach = SOLO_EAT_SHARE / N).
-- With baseHP ~2 (vanilla zombie post-convert), each solo eat adds ~0.5 HP.
-- The old value was 0.5 (added ~1 HP per eat), but with the engine's hard
-- HP ceiling around 30 (PZ network short overflow), a coarser per-eat
-- contribution made the curve too steep: 8-16 eats hit cap and the rest
-- of the multiplier knob did nothing. 0.125 gives a slow creep so the
-- scav growing into a real threat is something the player notices over
-- time rather than a quick power spike.
local SOLO_EAT_SHARE = 0.125

-- injection points - RQSvGlutton and RQSvScavenger call these after they init
local _gluttonState   = nil
local _scavengerState = nil

function RQSvEating.setGluttonState(tbl)
    _gluttonState = tbl
end

function RQSvEating.setScavengerState(tbl)
    _scavengerState = tbl
end

-- Co-eating model: corpses are not exclusively reserved. Multiple specials
-- can share a corpse via a single shared devour cast (svCorpseCast).
RQSvEating.svCorpseCast = {}  -- corpse -> { castDue, eaters, completed, shareEach, targetSq, zType }

-- Sweep cast records whose corpse has been skeletonized without anyone finalizing
-- (defensive - happens if every eater dies mid-cast). Replaces the old reservation
-- sweep since reservations are gone.
function RQSvEating.svCleanReservations()
    local toRemove, count = {}, 0
    for corpse, _ in pairs(RQSvEating.svCorpseCast) do
        if corpse:isSkeleton() then
            count = count + 1
            toRemove[count] = corpse
        end
    end
    for i = 1, count do RQSvEating.svCorpseCast[toRemove[i]] = nil end
end

-- Remove a single eater from any cast they're part of. Used by death/rage cleanup
-- so a quitting eater doesn't leave a stale entry in cast.eaters (which would skew
-- the share calculation for survivors). If the cast goes empty, drop it entirely
-- without removing the corpse - body stays available for future seekers.
function RQSvEating.svRemoveEaterFromCast(corpse, onlineID)
    if not corpse or not onlineID then return end
    local cast = RQSvEating.svCorpseCast[corpse]
    if not cast then return end
    for i, oid in ipairs(cast.eaters) do
        if oid == onlineID then
            table.remove(cast.eaters, i)
            break
        end
    end
    if #cast.eaters == 0 then
        RQSvEating.svCorpseCast[corpse] = nil
    end
end

-- scan a square radius around the zombie for the nearest eligible corpse
function RQSvEating.svGluttonFindCorpse(zombie, radius, ownerID)
    local cell = getCell()
    if not cell then return nil, nil end
    local zx = math.floor(zombie:getX())
    local zy = math.floor(zombie:getY())
    local zz = math.floor(zombie:getZ())
    local rSq = radius * radius
    local bestCorpse, bestSq, bestDistSq = nil, nil, rSq + 1
    local cfg = getSvConfig()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local dSq = dx * dx + dy * dy
            if dSq <= rSq then
                local sq = cell:getGridSquare(zx + dx, zy + dy, zz)
                if sq then
                    local bodies = sq:getDeadBodys()
                    if bodies and bodies:size() > 0 then
                        for i = 0, bodies:size() - 1 do
                            local body = bodies:get(i)
                            if body and not body:isSkeleton() and not body:isFakeDead()
                               and dSq < bestDistSq then
                                if cfg.debugMode then
                                    print(string.format("[RQEat:Sv] findCorpse body@[%d,%d] distSq=%d", zx+dx, zy+dy, dSq))
                                end
                                bestCorpse = body; bestSq = sq; bestDistSq = dSq
                            end
                        end
                    end
                end
            end
        end
    end
    return bestCorpse, bestSq
end

-- verify the corpse is still sitting on that square (world state can change fast)
function RQSvEating.svCorpseStillThere(corpse, sq)
    if not corpse or not sq then return false end
    local bodies = sq:getDeadBodys()
    if not bodies then return false end
    for i = 0, bodies:size() - 1 do
        if bodies:get(i) == corpse then return true end
    end
    return false
end

-- A cast may finalize because another actor already removed its corpse. That
-- is an ordinary stale-state result, not an exception: only call the direct
-- vanilla removal path for a body still owned by this live square.
-- IsoGridSquare.java:2610-2628; IsoMovingObject.java:688-698.
local function removeLiveBody(body, targetSq)
    if not body or body:getSquare() ~= targetSq or not body:getCell() then return false end
    if not RQSvEating.svCorpseStillThere(body, targetSq) then return false end
    targetSq:removeCorpse(body, false)
    return true
end

-- pull the body out of the world
function RQSvEating.svRemoveCorpse(targetCorpse, targetSq)
    if not targetCorpse or not targetSq then return false end
    RQDirgeLog.write("System","[RQEat:Sv] svRemoveCorpse at (" .. targetSq:getX() .. "," .. targetSq:getY() .. "," .. targetSq:getZ() .. ")")

    if instanceof(targetCorpse, "IsoDeadBody") then
        return removeLiveBody(targetCorpse, targetSq)
    elseif instanceof(targetCorpse, "IsoZombie") then
        local bodies = targetSq:getDeadBodys()
        if bodies then
            for i = 0, bodies:size() - 1 do
                local body = bodies:get(i)
                if instanceof(body, "IsoDeadBody") and removeLiveBody(body, targetSq) then
                    return true
                end
            end
        end
    end
    return false
end

-- kick the zombie back into normal AI mode after eating is done or cancelled
function RQSvEating.svRestoreAI(zombie)
    if not zombie then return end
    zombie:setUseless(false)
    zombie:setVariable("bPathfind", true)
    zombie:setVariable("bMoving",   false)
    zombie:setEatBodyTarget(nil, false, 1.0)
end

-- stamp the zombie's modData so clients know it's eating and where
function RQSvEating.svSetEatingIntent(zombie, eaterType, corpseSq, phase)
    if not zombie or not corpseSq then return end
    local md = zombie:getModData()
    md["RQEating"]        = true
    md["RQEatingType"]    = eaterType
    md["RQEatingPhase"]   = phase or "seeking"
    md["RQEatingCorpseX"] = corpseSq:getX()
    md["RQEatingCorpseY"] = corpseSq:getY()
    md["RQEatingCorpseZ"] = corpseSq:getZ()
    md["RQIsEating"]      = (phase == "eating") or nil
    RQDirgeLog.write("System","[RQEat:Sv] setEatingIntent oid=" .. tostring(zombie:getOnlineID())
        .. " type=" .. tostring(eaterType)
        .. " phase=" .. tostring(phase)
        .. " RQIsEating=" .. tostring(md["RQIsEating"]))
    zombie:transmitModData()
end

-- clear eating intent from modData, only transmits if there was actually something set
function RQSvEating.svClearEatingIntent(zombie)
    if not zombie then return end
    local md = zombie:getModData()
    if not md["RQEating"] and not md["RQEatingCorpseX"] then return end
    RQDirgeLog.write("System","[RQEat:Sv] clearEatingIntent oid=" .. tostring(zombie:getOnlineID()))
    md["RQEating"]        = nil
    md["RQEatingType"]    = nil
    md["RQEatingPhase"]   = nil
    md["RQEatingCorpseX"] = nil
    md["RQEatingCorpseY"] = nil
    md["RQEatingCorpseZ"] = nil
    md["RQIsEating"]      = nil
    zombie:transmitModData()
end

-- transition a zombie into the active devour cast, fire ring + animate broadcasts.
-- Also seeds the shared svCorpseCast entry so late-arriving eaters can join via
-- svJoinDevourCast and finish synced to the same castDue.
function RQSvEating.svStartDevourCast(zombie, state, onlineID, zType, cfg)
    if not zombie or not state or not state.targetSq then return end
    local now = getTimestampMs()
    state.phase   = "eating"
    state.seekDue = nil
    state.castDue = now + cfg.devourTime
    RQDirgeLog.write("System","[RQEat:Sv] svStartDevourCast oid=" .. tostring(onlineID)
        .. " type=" .. tostring(zType)
        .. " corpse=(" .. state.targetSq:getX() .. "," .. state.targetSq:getY() .. "," .. state.targetSq:getZ() .. ")"
        .. " castDue=now+" .. cfg.devourTime .. "ms")
    RQSvEating.svSetEatingIntent(zombie, zType, state.targetSq, "eating")
    -- Seed the shared cast record so co-eaters can join.
    RQSvEating.svCorpseCast[state.targetCorpse] = {
        castDue   = state.castDue,
        eaters    = { onlineID },
        completed = false,
        shareEach = nil,
        targetSq  = state.targetSq,
        zType     = zType,
    }
    local dx = math.floor(zombie:getX())
    local dy = math.floor(zombie:getY())
    local dz = math.floor(zombie:getZ())
    local ringId = (zType == "Scavenger") and ("scav_" .. onlineID) or ("glutton_" .. onlineID)
    local radius = (zType == "Scavenger") and SCAV_CORPSE_RADIUS or cfg.gluttonRadius
    local label  = (zType == "Scavenger") and "Scavenging..." or "Devouring..."
    broadcast("castStart", makeCastArgs(ringId, dx, dy, dz, cfg.devourTime, COLORS[zType], label, radius, zombie:getOnlineID()))
    broadcast("gluttonAnimate", {
        onlineID = onlineID, eating = true, phase = "eating",
        x = dx, y = dy, z = dz,
        corpseX = state.targetSq:getX(), corpseY = state.targetSq:getY(), corpseZ = state.targetSq:getZ(),
    })
end

-- Join an existing shared devour cast (a co-eater arrived after another zombie
-- already started eating this corpse). Snaps the joiner to the cast's castDue so
-- visual rings expire together. Each joiner gets its own ring/animate broadcast,
-- but with duration = remaining time so they sync visually.
function RQSvEating.svJoinDevourCast(zombie, state, onlineID, zType, cfg)
    if not zombie or not state or not state.targetSq or not state.targetCorpse then return end
    local cast = RQSvEating.svCorpseCast[state.targetCorpse]
    if not cast or cast.completed then return end
    local now = getTimestampMs()
    state.phase   = "eating"
    state.seekDue = nil
    state.castDue = cast.castDue
    cast.eaters[#cast.eaters + 1] = onlineID
    local remaining = cast.castDue - now
    if remaining < 0 then remaining = 0 end
    RQDirgeLog.write("System","[RQEat:Sv] svJoinDevourCast oid=" .. tostring(onlineID)
        .. " type=" .. tostring(zType)
        .. " corpse=(" .. state.targetSq:getX() .. "," .. state.targetSq:getY() .. "," .. state.targetSq:getZ() .. ")"
        .. " remaining=" .. remaining .. "ms"
        .. " eaters_now=" .. #cast.eaters)
    RQSvEating.svSetEatingIntent(zombie, zType, state.targetSq, "eating")
    local dx = math.floor(zombie:getX())
    local dy = math.floor(zombie:getY())
    local dz = math.floor(zombie:getZ())
    local ringId = (zType == "Scavenger") and ("scav_" .. onlineID) or ("glutton_" .. onlineID)
    local radius = (zType == "Scavenger") and SCAV_CORPSE_RADIUS or cfg.gluttonRadius
    local label  = (zType == "Scavenger") and "Scavenging..." or "Devouring..."
    broadcast("castStart", makeCastArgs(ringId, dx, dy, dz, remaining, COLORS[zType], label, radius, zombie:getOnlineID()))
    broadcast("gluttonAnimate", {
        onlineID = onlineID, eating = true, phase = "eating",
        x = dx, y = dy, z = dz,
        corpseX = state.targetSq:getX(), corpseY = state.targetSq:getY(), corpseZ = state.targetSq:getZ(),
    })
end

-- Finalize this eater's share when their eating phase ends. Replaces the old
-- per-zombie HP-scaling block in RQSvGlutton/RQSvScavenger. The first eater to
-- call this for a given cast locks the share calculation (shareEach = SOLO_EAT_SHARE/N) and
-- removes the corpse; subsequent eaters reuse the locked share. Removes this eater
-- from cast.eaters and GC's the cast when the list is empty.
-- Returns (shareApplied, newMult, n) for caller-side logging.
function RQSvEating.svFinalizeEater(zombie, state, onlineID, zType, cfg)
    if not zombie or not state then return SOLO_EAT_SHARE, 1.0, 1 end
    local corpse = state.targetCorpse
    local cast   = corpse and RQSvEating.svCorpseCast[corpse] or nil

    -- First finalizer locks the share and removes the corpse.
    if cast and not cast.completed then
        cast.completed = true
        local n = #cast.eaters
        if n < 1 then n = 1 end
        cast.shareEach = SOLO_EAT_SHARE / n
        RQSvEating.svRemoveCorpse(corpse, cast.targetSq or state.targetSq)
        RQDirgeLog.write("System","[RQEat:Sv] castComplete corpse=("
            .. (cast.targetSq and cast.targetSq:getX() or "?") .. ","
            .. (cast.targetSq and cast.targetSq:getY() or "?") .. ","
            .. (cast.targetSq and cast.targetSq:getZ() or "?") .. ")"
            .. " N=" .. n .. " shareEach=" .. string.format("%.3f", cast.shareEach))
    end

    -- Apply this eater's share. Fall back to SOLO_EAT_SHARE if no cast - shouldn't
    -- happen in practice but keeps HP scaling sane if the cast was GC'd early.
    local share = (cast and cast.shareEach) or SOLO_EAT_SHARE
    local n     = (cast and #cast.eaters) or 1
    state.totalMultGain = (state.totalMultGain or 0) + share

    local baseHP = state.baseHealth or state.initialHealth or 1.0
    local maxMult = cfg.gluttonMaxMult or 5.0
    local newMult = math.min(1.0 + state.totalMultGain, maxMult)

    -- HP changes route through RQSvShared.svSetZombieHP. PZ uses client-
    -- authoritative zombie ownership, so the owning client's setHealth is the
    -- one that sticks; pure server-side setHealth gets clobbered ~2s later by
    -- the owner's next sync packet. The helper broadcasts to all clients so
    -- the owner can apply it; non-owners' brief local writes get overwritten
    -- by the next vanilla zombie sync from the owner via the server.
    if zombie and zombie:getHealth() > 0 then
        local current = zombie:getHealth()
        local target
        if zType == "Scavenger" and state.hostile and state.peakHP then
            -- Rage-eating: heals toward the frozen peakHP, not the gluttonMaxMult
            -- cap. Share is proportional to the eat slot (baseHP * share gives
            -- a comparable nudge to non-rage gains), clamped to peakHP so the
            -- scav can't exceed its own rage ceiling.
            target = math.min(current + (baseHP * share), state.peakHP)
            -- Reset the decay clock so the heal isn't immediately undone. The
            -- decay tick computes target from an absolute time curve, not a
            -- delta - if elapsed has advanced past the eat boost, the next
            -- tick snaps HP back to wherever the curve says it should be.
            -- Resetting rageStartTime restarts the curve from peakHP, giving
            -- the heal room to breathe and effectively letting feeding sustain
            -- the rage. Lore: the scav is feeding, its rage is being fueled.
            state.rageStartTime = getTimestampMs()
        else
            -- Standard eat: cap at baseHP * mult, but never lose HP. Matters for
            -- raging scavengers that took the standard path before this branch -
            -- they could be at 5x base, above gluttonMaxMult, and we don't want
            -- a snack to nerf them back down to the cap.
            target = baseHP * newMult
            if current > target then target = current end
        end
        RQSvShared.svSetZombieHP(zombie, target)
    end
    state.eatCount = (state.eatCount or 0) + 1
    RQDirgeLog.write(zType, "[RQEat:Sv] finalize id=" .. tostring(onlineID)
        .. " share=" .. string.format("%.3f", share)
        .. " totalGain=" .. string.format("%.3f", state.totalMultGain)
        .. " mult=" .. string.format("%.2f", newMult)
        .. " eatCount=" .. state.eatCount
        .. " N=" .. n)

    -- Drop self from cast roster; GC the cast when last eater leaves.
    if cast then
        for i, oid in ipairs(cast.eaters) do
            if oid == onlineID then
                table.remove(cast.eaters, i)
                break
            end
        end
        if #cast.eaters == 0 then
            RQSvEating.svCorpseCast[corpse] = nil
        end
    end

    return share, newMult, n
end

-- abort whatever eating phase the zombie is in, restore AI, notify clients
function RQSvEating.svCancelEaterState(zombie, state, onlineID)
    if not state then return end
    RQDirgeLog.write("System","[RQEat:Sv] svCancelEaterState oid=" .. tostring(onlineID) .. " phase=" .. tostring(state.phase))
    RQSvEating.svClearEatingIntent(zombie)
    state.phase = "idle"; state.targetCorpse = nil; state.targetSq = nil
    state.seekDue = nil; state.castDue = nil
    RQSvEating.svRestoreAI(zombie)
    if zombie and onlineID then
        broadcast("gluttonAnimate", {
            onlineID = onlineID, eating = false, phase = "idle",
            x = math.floor(zombie:getX()), y = math.floor(zombie:getY()), z = math.floor(zombie:getZ()),
        })
    end
end

-- queue of { onlineID, corpseX, corpseY, corpseZ } arrival reports from clients
RQSvEating.svPendingEaterArrivals = {}

-- process a single arrival entry; validate state then kick off the devour cast
-- server-side position check was removed - zombie movement is client-authoritative so we trust the report
local function svProcessEaterArrival(entry)
    if not entry or not entry.onlineID then return end
    local cfg = RQSvShared.getSvConfig()
    local zombie, zType = RQSvShared.svFindActiveZombieByOnlineID(entry.onlineID)
    if not zombie or (zType ~= "Glutton" and zType ~= "Scavenger") then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: zombie not found or wrong type (got=" .. tostring(zType) .. ")")
        return
    end
    local state = (zType == "Glutton") and _gluttonState[entry.onlineID] or _scavengerState[entry.onlineID]
    if not state then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: no state table entry (type=" .. zType .. ")")
        return
    end
    if state.phase ~= "seeking" then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: phase=" .. tostring(state.phase) .. " (expected seeking)")
        return
    end
    if not state.targetSq then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: no targetSq")
        return
    end
    if entry.corpseX and entry.corpseX ~= state.targetSq:getX() then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: corpseX mismatch client=" .. tostring(entry.corpseX)
            .. " server=" .. tostring(state.targetSq:getX()))
        return
    end
    if entry.corpseY and entry.corpseY ~= state.targetSq:getY() then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: corpseY mismatch client=" .. tostring(entry.corpseY)
            .. " server=" .. tostring(state.targetSq:getY()))
        return
    end
    local corpsePresent = RQSvEating.svCorpseStillThere(state.targetCorpse, state.targetSq)
    if not corpsePresent then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " REJECT: corpse gone at arrival (sq="
            .. state.targetSq:getX() .. "," .. state.targetSq:getY() .. "," .. state.targetSq:getZ() .. ")")
        RQSvEating.svCancelEaterState(zombie, state, entry.onlineID)
        return
    end
    -- Co-eating: if a cast already exists for this corpse and is still in flight,
    -- join it instead of starting a new one. First arrival starts; everyone else
    -- joins until castDue passes.
    local now  = getTimestampMs()
    local cast = RQSvEating.svCorpseCast[state.targetCorpse]
    if cast and not cast.completed and now < cast.castDue then
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " ACCEPTED type=" .. zType
            .. " corpse=(" .. state.targetSq:getX() .. "," .. state.targetSq:getY() .. "," .. state.targetSq:getZ() .. ")"
            .. " -> svJoinDevourCast (cast in flight, eaters=" .. #cast.eaters .. ")")
        RQSvEating.svJoinDevourCast(zombie, state, entry.onlineID, zType, cfg)
    else
        RQDirgeLog.write("System","[RQEat:Sv] eaterArrived id=" .. tostring(entry.onlineID)
            .. " ACCEPTED type=" .. zType
            .. " corpse=(" .. state.targetSq:getX() .. "," .. state.targetSq:getY() .. "," .. state.targetSq:getZ() .. ")"
            .. " -> svStartDevourCast")
        RQSvEating.svStartDevourCast(zombie, state, entry.onlineID, zType, cfg)
    end
end

-- drain the pending arrivals queue each tick
function RQSvEating.processPendingArrivals()
    if #RQSvEating.svPendingEaterArrivals == 0 then return end
    local pending = RQSvEating.svPendingEaterArrivals
    RQSvEating.svPendingEaterArrivals = {}
    for _, entry in ipairs(pending) do svProcessEaterArrival(entry) end
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
