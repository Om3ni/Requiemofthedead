-- SPDX-License-Identifier: GPL-3.0-or-later
-- TRMood - Triage: per-player mood attribution (server).
--
-- The second half of the 2026-08-20 hunt: a player reporting depression her
-- build should resist. Sadness has no wound panel at all, so attribution
-- needs the writes themselves. Two recorders:
--
--  * A per-minute UNHAPPINESS sampler for every online player. Steps of 2+
--    (the stat is 0-100) log with their co-deltas, because the interesting
--    writers have distinguishable shapes:
--      - vanilla accrual is smooth and small: unhappinessIncrease scaled by
--        the boredom/stress moodle level (BodyDamage.java:1714-1717), or
--        event-shaped from food/literature getUnhappyChange
--        (IsoGameCharacter.java:5488, BodyDamage.java:654).
--      - Expanded Moodles' proc moves UNHAPPINESS, STRESS and WETNESS in the
--        SAME minute with ANGER as the multiplier (EM_Core.lua:711-717,
--        1-in-30 per game-minute, server-side in MP). No vanilla lane steps
--        those together, so the co-movement is a fingerprint, tagged
--        "em-proc" on the row.
--    ANGER itself has no vanilla source in 42.20 - the engine only decays it
--    (IsoGameCharacter.java:9224) - so any anger observed here came from a
--    mod, and EM feeds it from INTOXICATION, which drugs raise as readily as
--    drink. Both are sampled on every row for exactly that trail.
--
--  * A lazy wrap of ExpandedMoodles.addStat. EM routes every stat write it
--    makes through that one function (EM_Core.lua:414-446), so wrapping it
--    attributes every EM mood write by stat and amount, no inference needed.
--    The wrap logs and passes through. It never catches: a throw inside EM
--    must propagate exactly as it would unwrapped, so there is no pcall here
--    and none belongs (a swallow would change EM's behaviour, not observe it).
--    Binding happens on the first minute tick rather than at file scope so it
--    works regardless of mod load order, and a server without EM simply never
--    binds.
--
-- Same dial as TRDamage: RFTDOddsAndEnds.TriageEnable, default ON for the
-- hunt, every path returns on its first line when off. Retirement per
-- sect. 14: dial off when the hunt closes, delete when reports stay quiet.
-- Trait rosters are deliberately NOT logged here - Memoir's snapshots already
-- record every character's traits, and duplicating that record would be a
-- second copy of its semantics.

if not isServer() then return end

require "OEShared"

TRMood = TRMood or {}

local STREAM = "triage"
local MODID  = "RFTDOddsAndEnds"

-- EM writes worth a row: the sadness engine and its feeders.
local WATCH = {
    UNHAPPINESS   = true,
    ANGER         = true,
    STRESS        = true,
    WETNESS       = true,
    FOOD_SICKNESS = true,
}

-- UNHAPPINESS is 0-100; vanilla per-minute accrual sits well under this.
local STEP = 2

-- user -> { unh, str, ang, intox, bored, wet } at the last sample
local prev = {}

local emWrapped = false
local function wrapExpandedMoodles()
    if emWrapped then return end
    local em = ExpandedMoodles
    if type(em) ~= "table" or type(em.addStat) ~= "function" then return end
    emWrapped = true
    local origAdd = em.addStat
    em.addStat = function(player, stats, bodyDamage, key, amount)
        if OEShared.enabled("TriageEnable") and WATCH[key]
                and player and instanceof(player, "IsoPlayer") then
            RDLog.forensic(STREAM, "TR.EM_WRITE", player, {
                stat   = tostring(key),
                amount = string.format("%.4f", tonumber(amount) or 0),
            }, MODID)
        end
        return origAdd(player, stats, bodyDamage, key, amount)
    end
end

Events.EveryOneMinute.Add(function()
    if not OEShared.enabled("TriageEnable") then return end
    wrapExpandedMoodles()
    local players = getOnlinePlayers()
    if not players then return end
    for pi = 0, players:size() - 1 do
        local p = players:get(pi)
        if p and not p:isDead() then
            local user = p:getUsername()
            local st = user and p:getStats()
            if st then
                local cur = {
                    unh   = st:get(CharacterStat.UNHAPPINESS),
                    str   = st:get(CharacterStat.STRESS),
                    ang   = st:get(CharacterStat.ANGER),
                    intox = st:get(CharacterStat.INTOXICATION),
                    bored = st:get(CharacterStat.BOREDOM),
                    wet   = st:get(CharacterStat.WETNESS),
                }
                local was = prev[user]
                prev[user] = cur
                if was then
                    local du = cur.unh - was.unh
                    if du >= STEP or du <= -STEP then
                        local ds = cur.str - was.str
                        local da = cur.ang - was.ang
                        local dw = cur.wet - was.wet
                        local shape = (du > 0 and ds > 0 and (dw > 0 or da > 0))
                            and "em-proc" or "-"
                        RDLog.forensic(STREAM, "TR.MOOD_STEP", p, {
                            u     = string.format("%.1f", cur.unh),
                            du    = string.format("%.2f", du),
                            ds    = string.format("%.4f", ds),
                            da    = string.format("%.4f", da),
                            di    = string.format("%.2f", cur.intox - was.intox),
                            db    = string.format("%.2f", cur.bored - was.bored),
                            dw    = string.format("%.2f", dw),
                            anger = string.format("%.3f", cur.ang),
                            intox = string.format("%.2f", cur.intox),
                            shape = shape,
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
