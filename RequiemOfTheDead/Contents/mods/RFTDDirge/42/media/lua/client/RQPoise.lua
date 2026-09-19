-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQPoise - name the reaction, so the engine never reaches for a stagger.
--
-- NOT THE RQPOISE THAT CAME OUT ON 2026-09-15. That one, with RQFlinch, was
-- flat immunity: it fought the reaction from OnZombieUpdate, had to win a race
-- against the attacker's update every frame, and lost it structurally - the
-- Bulwark lab measured zombies parked in a deferred-movement latch (lab
-- FINDINGS F15, F21, F22). This file has no timing in it. It is the lab's
-- BZPoise, proven on Mosaic, under Dirge's name.
--
-- =============================================
-- THE FACT THIS IS BUILT ON
-- =============================================
-- CombatManager.processHit ends with one either/or (CombatManager.java:
-- 2410-2417): a hit becomes EITHER a named reaction OR a stagger, never both,
-- and the stagger is the fallback for a hit that named nothing. The name comes
-- from the ATTACKER (:2383 reads the wielder's `ZombieHitReaction` animation
-- variable), which the player's own attack animation sets: every armed melee
-- node assigns one. A SHOVE assigns nothing, so it reads "" -> NONE ->
-- setStaggerBack(true). That is where a staggered special comes from, and it
-- is why a shove is the opening move of the kill chain.
--
-- This file fills in that blank, for specials only, from inside the hit event:
--     IsoGameCharacter.Hit :5705  OnWeaponHitCharacter   <- us
--                          :5725  hitConsequences -> IsoZombie:3453 -> processHit
-- One synchronous call stack. Our write happens twenty lines above the read, in
-- the same invocation. There is no frame to be late for.
--
-- The write never leaves the machine: IsoGameCharacter.setVariable
-- (:11334-11340) sends a VariableSync packet only for keys in
-- VariableSyncPacket.syncedVariables, which only the Lua global
-- addVariableToSyncList (LuaManager.java:7268) adds to, and vanilla never
-- registers this key.
--
-- =============================================
-- WHY ShotBellyStep
-- =============================================
-- Four requirements on the name, in the order they bite:
--   1. IN THE ENUM. fromString on an unknown name returns NONE and we have
--      written a stagger by hand. ShotBellyStep is HitReaction.SHOT_BELLY_STEP
--      (HitReaction.java:13).
--   2. NO ROUTE TO THE FLOOR. Ten names unlock a to_knockeddown-* transition
--      out of hitreaction: HeadLeft, HeadRight, HeadTop, Uppercut,
--      ShotChestStepL/R, ShotLegL/R, ShotShoulderL/R. The lab's first version
--      chose HeadLeft and every shove went to the floor for ninety frames (lab
--      F23). ShotBellyStep appears in no to_knockeddown-*.xml; its exits are
--      to_idle on ActiveAnimFinishing and to_hitreaction-hit on the next hit.
--   3. A NODE THAT WILL BE SELECTED. hitreaction/to_idle.xml exits on an
--      ANIMATION event, so a name with no matching node freezes the zombie
--      (AnimState.java:43-55). ShotBellyStep has two: vanilla's, and ours.
--   4. A NODE THAT IS FAST. AnimSets/zombie/hitreaction/RQPoiseShotBellyStep.xml
--      plays vanilla's clip at twenty times speed whenever RQPoised is true on
--      the zombie. A poised zombie takes ours and the reaction is over in a few
--      frames; an unpoised one takes vanilla's at full speed. Neither freezes.
--
-- WHAT IT COSTS. A shove no longer staggers a special. It still INTERRUPTS one
-- - attack/to_hitreaction.xml and lunge/to_hitreaction.xml fire on any named
-- reaction - so players keep the defensive interrupt they shove for and lose
-- only the free knockdown that used to follow it. And it only acts where the
-- engine was already going to stagger: an armed swing that named its own
-- reaction is left alone.
--
-- =============================================
-- THE GUNFIRE LANE
-- =============================================
-- Naming fixes MELEE, because melee's blank was the stagger. Gunfire is a
-- different failure: each shot enters a reaction of about a second, and a fast
-- weapon re-triggers it before the last one ended, so a special is held still
-- until the magazine runs out. That reaction cannot be named from here - a
-- firearm's is resolved at CombatManager.java:937, before Hit is called at
-- :949 - but it can be made cheap: thirteen AnimSets nodes, one per gunfire
-- reaction string, play vanilla's clip at twenty times speed and are chosen
-- over vanilla's by m_ConditionPriority 100 (AnimNode.java:283-306,
-- AnimState.java:43-55) whenever the zombie carries RQPoised == true. With the
-- variable absent the node fails its own condition and an ordinary zombie is
-- untouched. Shipping AnimSets changes the network animation checksum
-- (AdvancedAnimator.load():752-760): every client must carry the same files
-- as the server, which the bundle already guarantees.
--
-- The variable must exist on EVERY client that simulates the zombie, not only
-- the attacker's, because the action machine runs independently per client and
-- the copy that matters is the owner's. So a one-second pass walks the
-- registry and asserts it - a write with no timing in it, because the graph
-- reads the variable when it PICKS a node. It reads the value back rather
-- than trusting a shadow copy, so a zombie rebuilt by a chunk reload is
-- re-asserted within a second, and it takes the variable back from anything
-- that has stopped being special.
--
-- ONE DIAL for both lanes, RFTDDirge.Poise (default on): the melee name only
-- lands on our fast node while RQPoised is asserted, so the two cannot be
-- separated honestly.

require "RQConfig"
require "RQRegistry"

RQPoise = RQPoise or {}

-- The attacker-side animation variable processHit reads (CombatManager.java
-- :2383). Named once because a typo fails SILENTLY - fromString returns NONE
-- and we write the very stagger we are avoiding. test_rqpoise pins it.
local VARIABLE = "ZombieHitReaction"
RQPoise.VARIABLE = VARIABLE

-- HitReaction.SHOT_BELLY_STEP (HitReaction.java:13). Changing this is a
-- floor-route decision, not a cosmetic one: check the name against every
-- to_knockeddown-*.xml first.
local REACTION = "ShotBellyStep"
RQPoise.REACTION = REACTION

-- The zombie-side variable the thirteen nodes condition on.
local POISED = "RQPoised"
RQPoise.POISED = POISED

-- Bounded by special count, so this is cheap; a second is fast enough that a
-- reloaded chunk is covered well before a firefight resolves.
local ASSERT_EVERY_MS = 1000
local nextAssertMs = 0

-- Which oids we have written to, so the variable can be taken BACK when a
-- zombie stops being special. Without this an ex-special would keep
-- compressed reactions for the rest of its life and nothing would say why.
local asserted = {}

RQPoise.stats = {
    named   = 0,   -- staggers replaced with a named reaction
    left    = 0,   -- the swing named its own reaction; we did nothing
    skipped = { notzombie = 0, remote = 0, noid = 0, ordinary = 0, dead = 0, floor = 0 },
    gunfire = { set = 0, cleared = 0, passes = 0, missing = 0 },
}

-- ---------------------------------------------------------------------------
-- The pure seam
-- ---------------------------------------------------------------------------
-- The entire melee policy as data, with no engine calls in it. `current` is
-- what the attacker's variable already says - getVariableString returns "" for
-- an unset key, never nil (IAnimationVariableSource.java:17-20), and nil is
-- accepted anyway so a fixture cannot lie about the contract by accident.
--   off      - the dial is down, do nothing
--   fallback - nothing named, the engine was about to stagger, so we name it
--   named    - the swing named its own, leave vanilla alone
function RQPoise.plan(current, dialOn)
    if not dialOn then
        return { write = false, reason = "off" }
    end
    if current == nil or current == "" then
        return { write = true, name = REACTION, reason = "fallback" }
    end
    return { write = false, reason = "named", had = current }
end

-- ---------------------------------------------------------------------------
-- The melee listener
-- ---------------------------------------------------------------------------
-- Full engine signature is (wielder, target, weapon, damageSplit); the last two
-- are deliberately not taken, because naming a reaction is a decision about the
-- TARGET's footing and has nothing to do with how hard it was hit. Refusals are
-- counted by name: "it did nothing" and "it refused for this reason" are
-- different answers and only one of them is debuggable.
local function onWeaponHitCharacter(wielder, target)
    if not RQConfig.get().poise then return end
    local s = RQPoise.stats

    if not instanceof(target, "IsoZombie") then
        s.skipped.notzombie = s.skipped.notzombie + 1
        return
    end
    -- Only the attacking client runs processHit (IsoZombie.java:3453 guards on
    -- !bRemote); a write anywhere else cannot reach it.
    if not instanceof(wielder, "IsoPlayer") or not wielder:isLocalPlayer() then
        s.skipped.remote = s.skipped.remote + 1
        return
    end
    local oid = target:getOnlineID()          -- IsoZombie.java:435
    if oid == nil or oid == -1 then
        s.skipped.noid = s.skipped.noid + 1
        return
    end
    if not RQRegistry.isSpecial(oid) then
        s.skipped.ordinary = s.skipped.ordinary + 1
        return
    end
    if target:isDead() then                   -- IsoGameCharacter.java:12060
        s.skipped.dead = s.skipped.dead + 1
        return
    end
    -- A zombie already on the floor is in a different graph; naming a standing
    -- reaction for it would be a lie the graph cannot act on.
    if target:isOnFloor() then
        s.skipped.floor = s.skipped.floor + 1
        return
    end

    local current = wielder:getVariableString(VARIABLE)  -- IAnimationVariableSource.java:17
    local p = RQPoise.plan(current, true)
    if not p.write then
        s.left = s.left + 1
        return
    end
    wielder:setVariable(VARIABLE, p.name)     -- IsoGameCharacter.java:11333
    s.named = s.named + 1
end

-- ---------------------------------------------------------------------------
-- The gunfire lane: keep the animation variable asserted
-- ---------------------------------------------------------------------------
-- One pass, split from the tick so a fixture can drive it directly. `resolve`
-- is how an oid becomes a zombie on this machine - RQZombieCache, through
-- RQCore.findZombieByID, which refuses a dead one - so this function never
-- holds a zombie itself and cannot pin one.
function RQPoise.assertPass(resolve, dialOn)
    local s = RQPoise.stats.gunfire
    s.passes = s.passes + 1
    local wanted = {}
    if dialOn then
        for oid in pairs(RQRegistry.activeZombies) do
            wanted[oid] = true
            local zombie = resolve(oid)
            if zombie == nil then
                -- Known to the registry but not loaded here: another client
                -- has it, or it is out of range. Ordinary, and counted so it
                -- can be told from a failure to write.
                s.missing = s.missing + 1
            else
                -- Read back rather than trust `asserted`: a chunk reload
                -- rebuilds the zombie with an empty variable slot and a shadow
                -- copy would never notice (IAnimationVariableSource.java:34-37).
                if zombie:getVariableBoolean(POISED) ~= true then
                    zombie:setVariable(POISED, true)      -- IsoGameCharacter.java:11344
                    s.set = s.set + 1
                end
                asserted[oid] = true
            end
        end
    end
    -- Take it back from anything that has stopped being special - or from
    -- everything, when the dial is turned off mid-session.
    for oid in pairs(asserted) do
        if not wanted[oid] then
            local zombie = resolve(oid)
            if zombie then
                zombie:setVariable(POISED, false)
                s.cleared = s.cleared + 1
            end
            asserted[oid] = nil
        end
    end
    return s
end

local function onTick()
    local now = getTimestampMs()                      -- LuaManager.java:4283
    if now < nextAssertMs then return end
    nextAssertMs = now + ASSERT_EVERY_MS
    RQPoise.assertPass(RQCore.findZombieByID, RQConfig.get().poise)
end

-- Console readback.
function RQPoise.summary()
    local s = RQPoise.stats
    print(string.format("[RFTDDirge] poise: named=%d left=%d  skipped notzombie=%d remote=%d noid=%d ordinary=%d dead=%d floor=%d",
        s.named, s.left, s.skipped.notzombie, s.skipped.remote, s.skipped.noid,
        s.skipped.ordinary, s.skipped.dead, s.skipped.floor))
    print(string.format("[RFTDDirge]   gunfire: passes=%d set=%d cleared=%d missing=%d",
        s.gunfire.passes, s.gunfire.set, s.gunfire.cleared, s.gunfire.missing))
end

Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
Events.OnTick.Add(onTick)
Events.OnGameStart.Add(function()
    asserted = {}
    nextAssertMs = 0
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
