-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQSvGlutton.lua - Glutton zombie server state and tick logic
-- Extracted from RQServer.lua; depends on RQSvShared and RQSvEating
-- =============================================

if not isServer() then return end

-- ========================
-- State table
-- gID -> { eatCount, baseHealth, phase, targetCorpse, targetSq, seekDue, castDue }
-- ========================

RQSvGlutton = RQSvGlutton or {}
RQSvGlutton.state = {}

-- how long the owning client has to path the glutton to a corpse before we give up
-- this is generous because big maps and slow zombies
local SEEK_TIMEOUT = 45000

-- Main tick - called once per server tick for any active Glutton zombie
function RQSvGlutton.tick(zombie)
    local cfg   = RQSvShared.getSvConfig()
    local gid   = zombie:getOnlineID()
    if not gid or gid == -1 then
        RQDirgeLog.write("Glutton", "[WARN] tick skipped - invalid onlineID=" .. tostring(gid))
        return
    end
    local state = RQSvGlutton.state[gid]
    if not state then
        local baseHealth = zombie:getModData()["RQGluttonBaseHealth"] or zombie:getHealth()
        state = {
            eatCount      = 0,
            totalMultGain = 0.0,  -- co-eating: fractional accumulator (sum of 0.5/N shares)
            baseHealth    = baseHealth,
            phase         = "idle",
            targetCorpse  = nil,
            targetSq      = nil,
            seekDue       = nil,
            castDue       = nil,
        }
        RQSvGlutton.state[gid] = state
    end

    local now = getTimestampMs()

    repeat
        if state.phase == "idle" then
            -- Co-eating: cap check uses the fractional accumulator, not eatCount,
            -- since shares can be 0.5/N (smaller than 0.5 with co-eaters present).
            local currentMult = 1.0 + (state.totalMultGain or 0)
            if currentMult >= cfg.gluttonMaxMult then break end
            local corpse, corpseSq = RQSvEating.svGluttonFindCorpse(zombie, cfg.gluttonRadius, gid)
            if not corpse then break end
            state.phase        = "seeking"
            state.targetCorpse = corpse
            state.targetSq     = corpseSq
            state.seekDue      = now + SEEK_TIMEOUT
            RQSvEating.svSetEatingIntent(zombie, "Glutton", corpseSq, "seeking")
            local dx = math.floor(zombie:getX())
            local dy = math.floor(zombie:getY())
            local dz = math.floor(zombie:getZ())
            RQDirgeLog.write("Glutton","[RQEat:Sv][Glutton] gid=" .. gid
                .. " idle->seeking corpse=(" .. corpseSq:getX() .. "," .. corpseSq:getY() .. "," .. corpseSq:getZ() .. ")"
                .. " eatCount=" .. state.eatCount)
            RQSvShared.broadcast("gluttonAnimate", {
                onlineID = gid, eating = true, phase = "seeking",
                x = dx, y = dy, z = dz,
                corpseX = corpseSq:getX(), corpseY = corpseSq:getY(), corpseZ = corpseSq:getZ(),
            })

        elseif state.phase == "seeking" then
            -- server does nothing to the zombie here - owning client drives movement via pathToSound
            -- we only cancel if the corpse disappears or the client never arrived
            local corpseGone = not RQSvEating.svCorpseStillThere(state.targetCorpse, state.targetSq)
            local timedOut   = state.seekDue and now >= state.seekDue
            if corpseGone or timedOut then
                RQDirgeLog.write("Glutton","[RQEat:Sv][Glutton] gid=" .. gid
                    .. " seeking cancelled: corpseGone=" .. tostring(corpseGone)
                    .. " timedOut=" .. tostring(timedOut))
                RQSvEating.svCancelEaterState(zombie, state, gid)
            end

        elseif state.phase == "eating" then
            pcall(zombie.clearAggroList, zombie)
            pcall(zombie.setTarget, zombie, nil)
            local corpseGone = not RQSvEating.svCorpseStillThere(state.targetCorpse, state.targetSq)
            local timedOut   = state.castDue and now >= state.castDue
            if corpseGone or timedOut then
                RQDirgeLog.write("Glutton","[RQEat:Sv][Glutton] gid=" .. gid
                    .. " eating done: corpseGone=" .. tostring(corpseGone)
                    .. " timedOut=" .. tostring(timedOut))
                state.castDue = nil
                RQSvShared.broadcast("castDone", { ringId = "glutton_" .. gid })
                RQSvEating.svClearEatingIntent(zombie)
                RQSvEating.svRestoreAI(zombie)
                -- Co-eating finalize: applies this Glutton's share (0.5/N), removes
                -- the corpse if first finalizer, drops self from cast.eaters.
                RQSvEating.svFinalizeEater(zombie, state, gid, "Glutton", cfg)
                state.phase        = "idle"
                state.targetCorpse = nil
                state.targetSq     = nil
                state.seekDue      = nil
                local zx = math.floor(zombie:getX())
                local zy = math.floor(zombie:getY())
                local zz = math.floor(zombie:getZ())
                RQSvShared.broadcast("gluttonAnimate", { onlineID = gid, eating = false, phase = "idle", x = zx, y = zy, z = zz })
            end
        end
    until true
end

-- Wire up the state table into RQSvEating so arrival processing can find it
RQSvEating.setGluttonState(RQSvGlutton.state)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
