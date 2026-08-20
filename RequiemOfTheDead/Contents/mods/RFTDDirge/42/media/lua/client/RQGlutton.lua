-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQGlutton - client stub
-- All behavior (eating, HP growth) runs server-side (svGluttonTick).
-- Pathing to corpse is client-side via OnZombieUpdate (movement runs on owning client).
-- State is seeded by gluttonAnimate broadcast; ownership transfers are handled by
-- isRemoteZombie() so only the controlling client drives each zombie.

RQGlutton = RQGlutton or {}

-- onlineID -> { zombie, corpseX, corpseY, corpseZ, lastPath, arrivedSent }
local clActiveEaters = {}
local clWasEating    = {}  -- oid -> bool, tracks last known animation state per client

local PATH_INTERVAL_MS = 1500
local EAT_DIST         = 1.2

local function findCorpseAt(x, y, z)
    local cell = getCell()
    local sq   = cell and cell:getGridSquare(x, y, z)
    if not sq then return nil end
    local bodies = sq:getDeadBodys()
    if bodies then
        for i = 0, bodies:size() - 1 do
            local body = bodies:get(i)
            if body and not body:isSkeleton() and not body:isFakeDead() then
                return body
            end
        end
    end
    return nil
end

function RQGlutton.startEating(zombie, onlineID, corpseX, corpseY, corpseZ)
    corpseX = tonumber(corpseX)
    corpseY = tonumber(corpseY)
    corpseZ = tonumber(corpseZ)
    if not zombie or not onlineID or not corpseX or not corpseY or not corpseZ then return end

    RQDirgeLog.write("Glutton","[RQEat:Cl] startEating oid=" .. onlineID .. " corpse=(" .. corpseX .. "," .. corpseY .. "," .. corpseZ .. ")")
    clActiveEaters[onlineID] = {
        zombie      = zombie,
        corpseX     = corpseX,
        corpseY     = corpseY,
        corpseZ     = corpseZ,
        lastPath    = nil,
        arrivedSent = false,
        pathFaultLogged = false,
    }
end

-- Called when server confirms devour has started. Marks arrivedSent=true to prevent
-- re-sending eaterArrived, then sets the body target (correct time - body still exists).
function RQGlutton.confirmEating(onlineID, zombie, corpseX, corpseY, corpseZ)
    local entry = clActiveEaters[onlineID]
    local hadEntry = entry ~= nil
    if entry then entry.arrivedSent = true end

    local cx = math.floor(tonumber(corpseX) or 0)
    local cy = math.floor(tonumber(corpseY) or 0)
    local cz = math.floor(tonumber(corpseZ) or 0)
    local corpse = findCorpseAt(cx, cy, cz)
    RQDirgeLog.write("Glutton","[RQEat:Cl] confirmEating oid=" .. tostring(onlineID)
        .. " hadEntry=" .. tostring(hadEntry)
        .. " corpseFound=" .. tostring(corpse ~= nil)
        .. " at=(" .. cx .. "," .. cy .. "," .. cz .. ")")
    if not zombie then
        RQDirgeLog.write("Glutton","[RQEat:Cl] confirmEating oid=" .. tostring(onlineID) .. " SKIP: zombie nil")
        return
    end
    if corpse and zombie.setEatBodyTarget then
        if zombie.setForceEatingAnimation then
            zombie:setForceEatingAnimation(true)
        end
        RQDirgeLog.write("Glutton","[RQEat:Cl] confirmEating oid=" .. tostring(onlineID) .. " -> setForceEatingAnimation+setEatBodyTarget")
        zombie:setEatBodyTarget(corpse, true, ZombRandFloat(0.6, 1.6))
    else
        RQDirgeLog.write("Glutton","[RQEat:Cl] confirmEating oid=" .. tostring(onlineID)
            .. " WARN: no body target set (corpse=" .. tostring(corpse ~= nil)
            .. " api=" .. tostring(zombie.setEatBodyTarget ~= nil) .. ")")
    end
end

function RQGlutton.stopEating(onlineID, zombie)
    RQDirgeLog.write("Glutton","[RQEat:Cl] stopEating oid=" .. tostring(onlineID))
    clActiveEaters[onlineID] = nil
    if zombie then
        if zombie.setForceEatingAnimation then
            zombie:setForceEatingAnimation(false)
        end
        if zombie.setEatBodyTarget then
            zombie:setEatBodyTarget(nil, false, 1.0)
        end
        zombie:setUseless(false)
        zombie:setVariable("bPathfind", true)
        zombie:setVariable("bMoving",   false)
    end
end

local function onZombieUpdate(zombie)
    local oid = zombie and zombie:getOnlineID()
    if not oid or oid == 0 then return end

    -- animation sync: driven by modData so every client sees it, not just the owner
    local md      = zombie:getModData()
    local eating  = md and md["RQIsEating"] == true
    local wasEat  = clWasEating[oid] == true
    if eating ~= wasEat then
        clWasEating[oid] = eating or nil
        RQDirgeLog.write("Glutton","[RQEat:Cl] animSync oid=" .. oid .. " setForceEatingAnimation=" .. tostring(eating)
            .. " (was=" .. tostring(wasEat) .. ")")
        if zombie.setForceEatingAnimation then
            zombie:setForceEatingAnimation(eating)
        else
            RQDirgeLog.write("Glutton","[RQEat:Cl] animSync oid=" .. oid .. " WARN: setForceEatingAnimation not available")
        end
    end

    -- navigation: owning client only
    if isClient() and zombie:isRemoteZombie() then return end
    local entry = clActiveEaters[oid]
    if not entry then return end

    if zombie:isDead() then
        RQDirgeLog.write("Glutton","[RQEat:Cl] navCleanup oid=" .. oid .. " zombie dead, clearing entry")
        clActiveEaters[oid] = nil
        return
    end

    -- keep it from re-aggroing players mid-walk, but dont call setUseless yet
    -- setUseless(true) prevents pathToSound from moving the zombie in B42
    zombie:clearAggroList()
    zombie:setTarget(nil)

    local zx   = zombie:getX()
    local zy   = zombie:getY()
    local dx   = zx - entry.corpseX
    local dy   = zy - entry.corpseY
    local dist = math.sqrt(dx*dx + dy*dy)

    if dist <= EAT_DIST then
        -- arrived: now its safe to lock movement
        zombie:setUseless(true)
        zombie:setVariable("bPathfind", false)
        zombie:setVariable("bMoving",   false)
        -- do NOT call setEatBodyTarget here - the engine consumes the body immediately,
        -- which causes the server to see corpseGone=true and cancel the devour timer before
        -- the eating animation ever plays. setEatBodyTarget is called later in confirmEating()
        -- after the server broadcasts phase=eating.
        if not entry.arrivedSent and isClient() then
            entry.arrivedSent = true
            RQDirgeLog.write("Glutton","[RQEat:Cl] arrived oid=" .. oid
                .. " dist=" .. string.format("%.3f", dist)
                .. " corpse=(" .. entry.corpseX .. "," .. entry.corpseY .. "," .. entry.corpseZ .. ")"
                .. " -> sendClientCommand eaterArrived")
            sendClientCommand(RQCommon.MODULE, "eaterArrived", {
                onlineID = oid,
                corpseX  = entry.corpseX,
                corpseY  = entry.corpseY,
                corpseZ  = entry.corpseZ,
            })
        end
    else
        local now = getTimeInMillis()
        if not entry.lastPath or now - entry.lastPath > PATH_INTERVAL_MS then
            entry.lastPath = now
            RQDirgeLog.write("Glutton","[RQEat:Cl] seeking oid=" .. oid
                .. " dist=" .. string.format("%.2f", dist)
                .. " -> pathToSound (" .. entry.corpseX .. "," .. entry.corpseY .. "," .. entry.corpseZ .. ")")
            -- No guard, and the fault branch that lived here was DEAD RECOVERY:
            -- it had never fired and never could. The failure the old comment
            -- named is real - the body reaches currentCell and PolygonalMap2
            -- with no complete precondition (IsoGameCharacter.java:5912-5930,
            -- 5964-5966; PathFindBehavior2.java:252-257) - but pathToSound is
            -- an exposed method, so that fault is swallowed by MethodCaller,
            -- stack-traced to the console, and the call simply returns
            -- (MethodCaller.java:33-56). `ok` was always true; the pcall and
            -- its logging arm were unreachable. The hint stays retryable
            -- exactly as before: a faulted attempt no-ops and the next
            -- interval is fresh valid work, with the engine's own trace as
            -- the diagnostic.
            zombie:pathToSound(entry.corpseX, entry.corpseY, entry.corpseZ)
            if zombie:getZ() ~= entry.corpseZ then
                zombie:setVariable("bPathfind", true)
            end
        end
    end
end

Events.OnZombieUpdate.Add(onZombieUpdate)

function RQGlutton.onDead(zombie)
    local oid = zombie and zombie:getOnlineID()
    if oid and oid ~= 0 then
        RQDirgeLog.write("Glutton","[RQEat:Cl] onDead oid=" .. oid)
        RQRing.clear("glutton_" .. oid)
        RQGlutton.stopEating(oid, zombie)
    end
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
