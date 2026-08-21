-- SPDX-License-Identifier: GPL-3.0-or-later
-- TRDamage - Triage: per-player damage attribution (server).
--
-- Born from the 2026-08-20 phantom-wounds hunt: players reported health
-- depleting with an empty wounds panel, and fractures on a world running
-- BoneFracture=false. Both reports are mechanically credible, because the
-- health panel renders the wound FLAGS while damage runs on the wound CLOCKS
-- (every DamageUpdate branch tests get*Time() > 0, BodyPart.java:138-179),
-- and several third-party mods write the clock side directly. This file makes
-- every health drop name its lane - or get flagged as unattributed, which is
-- itself the signal: it convicts a direct mod call.
--
-- Three recorders, all bounded through RDLog's forensic ring:
--
--  * OnPlayerGetDamage. Every VANILLA drain announces itself on this event
--    with a lane string - POISON/HUNGRY/SICK/THIRST/BLEEDING/HEAVYLOAD at
--    BodyDamage.java:1977-1992, INFECTION at :2017-2037, FALLDOWN at
--    IsoGameCharacter.java:2117, FIRE at :5555/:6047, WEAPONHIT at :5706,
--    CARHITDAMAGE at IsoPlayer.java:1954, CARCRASHDAMAGE at
--    BaseVehicle.java:8485, LOWWEIGHT at Nutrition.java:305. Direct mod calls
--    to ReduceGeneralHealth/AddDamage fire nothing. Events are aggregated per
--    player per game-minute so a slow drain costs one row, not sixty.
--
--  * A per-minute health sampler. A drop with no recorded lane in the same
--    minute logs TR.UNATTRIBUTED_DROP with moodle levels and the wound-clock
--    census - enough context to tell "severe hunger" from "silent mod write"
--    without a second trip to the server.
--
--  * A fracture audit. Vanilla can only mint a fracture through
--    generateFracture, which no-ops when the sandbox option is off
--    (BodyPart.java:818-826); the bare setFractureTime setter carries no such
--    gate. So on a BoneFracture=false world, ANY part with fractureTime > 0
--    is a sandbox-bypassing mod write, and it logs as such - one row per
--    fracture, re-arming when the clock clears.
--
-- Server-side on purpose: for MP players the wound DoT and the authoritative
-- stats tick here, not on the owning client (DamageUpdate returns early for
-- the local player on clients, BodyPart.java:142-144). The client-only lanes
-- (FALLDOWN, FIRE) still surface as health steps in the sampler; they arrive
-- unattributed, which is honest - this side cannot see who pushed them, only
-- that no server-side lane did. Nothing here runs in solo, where the problem
-- was never reported and the client walk skips on the isServer() gate below.
--
-- The dial is RFTDOddsAndEnds.TriageEnable, default ON while the hunt runs;
-- off, every handler returns on its first line. Retirement plan (sect. 14):
-- flip the dial off once the hunt closes, delete the module when a season's
-- reports stay quiet.

if not isServer() then return end

require "OEShared"

TRDamage = TRDamage or {}

local STREAM = "triage"
local MODID  = "RFTDOddsAndEnds"

-- user -> { lanes = { LANE = total }, n = events } for the current game-minute
local acc = {}
-- user -> overall body health at the last sample
local lastHP = {}
-- user -> { [partIndex] = true } fracture rows already reported this fracture
local flagged = {}

Events.OnPlayerGetDamage.Add(function(character, damageType, amount)
    if not OEShared.enabled("TriageEnable") then return end
    -- FIRE is triggered from IsoGameCharacter for any burning character
    -- (IsoGameCharacter.java:5555), so the argument is not always a player.
    if not character or not instanceof(character, "IsoPlayer") then return end
    local user = character:getUsername()
    if not user then return end
    local a = acc[user]
    if not a then
        a = { lanes = {}, n = 0 }
        acc[user] = a
    end
    local lane = tostring(damageType)
    a.lanes[lane] = (a.lanes[lane] or 0) + (tonumber(amount) or 0)
    a.n = a.n + 1
end)

local function lanesLine(lanes)
    local out = {}
    for lane, amt in pairs(lanes) do
        out[#out + 1] = lane .. "=" .. string.format("%.3f", amt)
    end
    table.sort(out)
    return table.concat(out, " ")
end

-- Wound CLOCK census - the damage-bearing half of the panel split. The flags
-- are deliberately not read: a clock without its flag is invisible on the
-- health panel yet still deals damage every DamageUpdate, and that exact
-- state is one of the things this module exists to catch.
local function woundClocks(bd)
    local parts = bd:getBodyParts()
    local scr, cut, deep, bite, burn, bleed, frac = 0, 0, 0, 0, 0, 0, 0
    for idx = 0, parts:size() - 1 do
        local part = parts:get(idx)
        if part:getScratchTime()   > 0 then scr   = scr   + 1 end
        if part:getCutTime()       > 0 then cut   = cut   + 1 end
        if part:getDeepWoundTime() > 0 then deep  = deep  + 1 end
        if part:getBiteTime()      > 0 then bite  = bite  + 1 end
        if part:getBurnTime()      > 0 then burn  = burn  + 1 end
        if part:getBleedingTime()  > 0 then bleed = bleed + 1 end
        if part:getFractureTime()  > 0 then frac  = frac  + 1 end
    end
    return "scr=" .. scr .. " cut=" .. cut .. " deep=" .. deep .. " bite=" .. bite
        .. " burn=" .. burn .. " bleed=" .. bleed .. " frac=" .. frac
end

local function fractureAudit(p, user, bd)
    if not (SandboxVars and SandboxVars.BoneFracture == false) then return end
    local seen = flagged[user]
    local parts = bd:getBodyParts()
    for idx = 0, parts:size() - 1 do
        local part = parts:get(idx)
        local clock = part:getFractureTime()
        if clock > 0 then
            if not (seen and seen[idx]) then
                if not seen then
                    seen = {}
                    flagged[user] = seen
                end
                seen[idx] = true
                RDLog.forensic(STREAM, "TR.IMPOSSIBLE_FRACTURE", p, {
                    part   = tostring(BodyPartType.getDisplayName(BodyPartType.FromIndex(idx))),
                    index  = idx,
                    clock  = string.format("%.1f", clock),
                    splint = part:isSplint() and 1 or 0,
                }, MODID)
            end
        elseif seen and seen[idx] then
            seen[idx] = nil
        end
    end
end

Events.EveryOneMinute.Add(function()
    if not OEShared.enabled("TriageEnable") then return end
    local players = getOnlinePlayers()
    if not players then return end
    for pi = 0, players:size() - 1 do
        local p = players:get(pi)
        if p and not p:isDead() then
            local user = p:getUsername()
            local bd = user and p:getBodyDamage()
            if bd then
                fractureAudit(p, user, bd)
                local hp = bd:getOverallBodyHealth()
                local prev = lastHP[user]
                lastHP[user] = hp
                local a = acc[user]
                acc[user] = nil
                if prev then
                    local drop = prev - hp
                    if a and a.n > 0 then
                        RDLog.forensic(STREAM, "TR.DAMAGE_MINUTE", p, {
                            hp     = string.format("%.2f", hp),
                            drop   = string.format("%.3f", drop),
                            events = a.n,
                            lanes  = lanesLine(a.lanes),
                        }, MODID)
                    elseif drop > 0.1 then
                        local m = p:getMoodles()
                        RDLog.forensic(STREAM, "TR.UNATTRIBUTED_DROP", p, {
                            hp        = string.format("%.2f", hp),
                            drop      = string.format("%.3f", drop),
                            heavyLoad = m:getMoodleLevel(MoodleType.HEAVY_LOAD),
                            sick      = m:getMoodleLevel(MoodleType.SICK),
                            hungry    = m:getMoodleLevel(MoodleType.HUNGRY),
                            thirst    = m:getMoodleLevel(MoodleType.THIRST),
                            bleedingM = m:getMoodleLevel(MoodleType.BLEEDING),
                            clocks    = woundClocks(bd),
                        }, MODID)
                    end
                end
            end
        end
    end
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
