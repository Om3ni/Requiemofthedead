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
--  * A wound watcher (added for the "scratches from nowhere" reports). Wound
--    APPLICATION fires no OnPlayerGetDamage lane, and every wound's DoT
--    except bleeding runs through CombatManager.applyDamage - a bare
--    ReduceHealth with no event (CombatManager.java:1083) - so both halves
--    are invisible to the two recorders above. This one diffs each part's
--    wound clocks (scratch, cut, deep wound, bite, burn, glass) between
--    samples and logs TR.WOUND_NEW / TR.WOUND_GREW rows. The STARTING clock
--    fingerprints the author: vegetation scratches start at 1-3 and grow by
--    1-3 per brush (IsoPlayer.java:7570-7592); generic setScratched rolls
--    7-15 and window climbs 12-20, both scaled by healer traits and injury
--    severity (BodyPart.java:719-746, :846-874); a sub-0.5 clock is a mod
--    that shrank its own wound. Each row also carries the part's IsInfected
--    at that moment - whether THIS wound rolled zombie infection - plus
--    vehicle/climbing context for the exit-a-moving-car and window lanes.
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
-- user -> { [partIndex] = { scratch=, cut=, deepwound=, bite=, burn=, glass= } }
local woundPrev = {}

-- The wound clocks, in the order they are read and diffed. Bleeding is
-- deliberately absent: its damage already names itself on the BLEEDING lane,
-- and its clock is re-derived from the others by generateBleeding.
local CLOCKS = {
    { key = "scratch",   get = "getScratchTime" },
    { key = "cut",       get = "getCutTime" },
    { key = "deepwound", get = "getDeepWoundTime" },
    { key = "bite",      get = "getBiteTime" },
    { key = "burn",      get = "getBurnTime" },
}

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

-- A new wound is a 0 -> >0 clock transition; growth is a rise of 0.5+ on a
-- clock that was already running (vegetation adds 1-3 per brush, so real
-- growth clears the threshold and float noise does not). A falling clock is
-- ordinary healing and only updates the baseline. The first sample after a
-- player appears stores a baseline silently, so a relog does not re-report
-- every wound they already carried.
local function woundWatch(p, user, bd)
    local prev = woundPrev[user]
    local first = (prev == nil)
    if first then
        prev = {}
        woundPrev[user] = prev
    end
    local parts = bd:getBodyParts()
    for idx = 0, parts:size() - 1 do
        local part = parts:get(idx)
        local was = prev[idx]
        if not was then
            was = { scratch = 0, cut = 0, deepwound = 0, bite = 0, burn = 0, glass = false }
            prev[idx] = was
        end
        for ci = 1, #CLOCKS do
            local c = CLOCKS[ci]
            local cur = part[c.get](part)
            if not first then
                local kind = nil
                if was[c.key] <= 0 and cur > 0 then kind = "TR.WOUND_NEW"
                elseif cur > was[c.key] + 0.5 then kind = "TR.WOUND_GREW" end
                if kind then
                    RDLog.forensic(STREAM, kind, p, {
                        part     = tostring(BodyPartType.getDisplayName(BodyPartType.FromIndex(idx))),
                        index    = idx,
                        type     = c.key,
                        clock    = string.format("%.2f", cur),
                        delta    = string.format("%.2f", cur - was[c.key]),
                        infected = part:IsInfected() and 1 or 0,
                        vehicle  = p:getVehicle() and 1 or 0,
                        climbing = p:isClimbing() and 1 or 0,
                    }, MODID)
                end
            end
            was[c.key] = cur
        end
        local glass = part:haveGlass()
        if not first and glass and not was.glass then
            RDLog.forensic(STREAM, "TR.WOUND_NEW", p, {
                part     = tostring(BodyPartType.getDisplayName(BodyPartType.FromIndex(idx))),
                index    = idx,
                type     = "glass",
                clock    = "0.00",
                delta    = "0.00",
                infected = part:IsInfected() and 1 or 0,
                vehicle  = p:getVehicle() and 1 or 0,
                climbing = p:isClimbing() and 1 or 0,
            }, MODID)
        end
        was.glass = glass
    end
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
                woundWatch(p, user, bd)
                local hp = bd:getOverallBodyHealth()
                local prev = lastHP[user]
                lastHP[user] = hp
                local a = acc[user]
                acc[user] = nil
                if prev then
                    local drop = prev - hp
                    if a and a.n > 0 then
                        -- gap = drop minus everything the lanes explain. Wound
                        -- DoT (except bleeding) never fires a lane, so a
                        -- persistently positive gap is a ticking wound clock
                        -- hiding behind whatever lane DID fire - on this
                        -- server, usually heavy load. Negative gap is regen.
                        local laneTotal = 0
                        for _, amt in pairs(a.lanes) do laneTotal = laneTotal + amt end
                        RDLog.forensic(STREAM, "TR.DAMAGE_MINUTE", p, {
                            hp     = string.format("%.2f", hp),
                            drop   = string.format("%.3f", drop),
                            events = a.n,
                            lanes  = lanesLine(a.lanes),
                            gap    = string.format("%.3f", drop - laneTotal),
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
-- Credit 
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
