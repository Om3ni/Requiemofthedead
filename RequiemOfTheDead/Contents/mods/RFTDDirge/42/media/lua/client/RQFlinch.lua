-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQFlinch.lua - make a zombie's hit reaction cost it nothing.
--
-- MECHANISM ONLY. This file knows how to stop a flinch from mattering; it has
-- no opinion about WHO should get that. RQPoise decides. Anything else that
-- wants a zombie to shrug off a hit calls in here and does its own
-- bookkeeping - which is the whole point of the split.
--
-- =============================================
-- WHY THIS EXISTS, AND WHY THE OBVIOUS APPROACHES DO NOT WORK
-- =============================================
-- Owner report, 2026-08-24: a .45 kept a Boss staggered for an entire
-- encounter. Two attempts failed before this one, and both are worth keeping
-- written down because each looks correct from the Lua side.
--
-- ATTEMPT 1 - clear isStaggerBack(). Did nothing at all. CombatManager
-- resolves each hit into EITHER a named hit reaction OR a stagger, never both
-- (CombatManager.java:2410-2417). A bullet always takes the reaction branch,
-- so the stagger flag it was watching is never set by gunfire.
--
-- ATTEMPT 2 - clear the hit reaction string as well. The graph does read
-- exactly that, so the target was right - but we are ALWAYS ONE FRAME LATE.
-- The hit sets the reaction, the state machine transitions, and only then does
-- the next OnZombieUpdate come round to clear it. Worse, we now know the clear
-- was redundant anyway: ZombieHitReactionState.exit (:60, :67, :69) already
-- calls setStaggerBack(false) and setHitReaction("") on its way out. We were
-- racing the engine to do something the engine does for us.
--
-- WHAT ACTUALLY WORKS. Stop trying to win a race we cannot win, and change
-- what the flinch COSTS instead. There are two lanes and they need different
-- levers, which is the thing that took three attempts to see:
--
--   GUNFIRE -> the `hitreaction` state. Exits on an ANIMATION event:
--     actiongroups/zombie/hitreaction/to_idle.xml is
--     <eventOccurred>ActiveAnimFinishing</eventOccurred>. So a node with a
--     large m_SpeedScale genuinely ends the state early. That is
--     RQFlinch.set plus media/AnimSets/zombie/hitreaction/RQFlinch.xml.
--
--   MELEE / SHOVE -> the `staggerback` state. Exits on a TIMER:
--     actiongroups/zombie/staggerback/to_idle.xml is
--     <lessEqual a="stateEventDelayTimer" b="0.0000" />. Speed scaling cannot
--     touch it, and StaggerBackState.getMaxStaggerTime is clamped to [20, 30]
--     frames (:58-64) so shortening it by hitForce is not available either.
--     The timer itself is public though - IsoMovingObject.java:1960 - so we
--     zero it. That is RQFlinch.releaseStagger.
--
--   CRITICAL HIT -> the `hitreaction-shothead-*` fall chain. A crit resolves
--     to SHOT_HEAD_FWD/FWD02/BWD (CombatManager.resolveHitReaction:2313-2331)
--     and the actiongroup routes into the fall on the reaction STRING alone,
--     inside the same engine tick that set it - every Lua hit event
--     (OnHitZombie, IsoZombie.java:1107; OnWeaponHitCharacter,
--     IsoGameCharacter.java:5705) fires BEFORE hitConsequences writes the
--     string, so there is no code of ours between the write and the read.
--     This lane cannot be refused, only COMPRESSED: nodes in the three
--     shothead states and both getup states (all exit on ActiveAnimFinishing;
--     onground between them is flag-gated transit) shrink the measured
--     125-frame / 2083ms floor trip to roughly ten frames. A crit reads as a
--     dip-and-recover, not a knockdown. Measured before the fix, Mosaic
--     2026-08-25: twelve suppressed hits at 2-6 frames, then one crit took
--     the boss down for the full two seconds.
--
-- The two halves of the animation graph load DIFFERENTLY, and that asymmetry
-- is the entire reason the gunfire lane is possible at all:
--
--   actiongroups (the state TRANSITIONS) - ActionGroup.load() uses
--     getMediaFile() plus listFiles() on the base directory. NOT mod-loadable.
--     This is why we cannot simply refuse the transition.
--   AnimSets (the animation NODES) - AnimationSet:54 uses
--     resolveAllDirectories, and AnimState.Parse:64 uses resolveAllFiles. Both
--     walk game AND mod roots and dedupe on the RELATIVE path
--     (ZomboidFileSystem.java:1174-1195), so our one file joins vanilla's
--     twelve in the same AnimState rather than replacing the folder.
--
-- SERVER-SIDE THIS FILE IS INERT BY ENGINE DESIGN, which is why it lives in
-- client/. IsoGameCharacter.setVariable returns null without doing anything
-- when GameServer.server and the target is an IsoZombie (:11343-11346). There
-- is no server-side version of this to write.
--
-- CHECKSUM WARNING. AdvancedAnimator.load() hashes base AND mod AnimSets into
-- NetChecksum (:752-762). Shipping the node changes the animation checksum, so
-- client and server must carry byte-identical copies. Fine for this suite -
-- one atomic Workshop item - but it means a client with a stale copy is
-- REJECTED rather than desynced.
-- =============================================

require "RDLedger"
require "RQCommon"

RQFlinch = RQFlinch or {}

-- The animation variable our AnimSets node keys on. Changing this string means
-- changing media/AnimSets/zombie/hitreaction/RQFlinch.xml to match, and a
-- mismatch fails SILENTLY - the node simply never wins and flinches look
-- normal. Kept here as the single definition so the pair is findable, and
-- test_rqflinch.lua reads the XML back to prove they still agree.
local VARIABLE = "RQNoFlinch"
RQFlinch.VARIABLE = VARIABLE

-- The action-context state whose exit is timer-driven rather than animation
-- driven. Compared case-insensitively: the name comes from the actiongroups
-- FOLDER name, and vanilla compares these with equalsIgnoreCase throughout
-- (e.g. PlayerSitOnFurnitureState.java:120).
local STAGGER_STATE = "staggerback"

RQFlinch.stats = {
    set      = 0,   -- suppression switched on
    cleared  = 0,   -- suppression switched off
    released = 0,   -- staggerback timers zeroed
    spans    = 0,   -- completed hit reactions measured
    longest  = 0,   -- worst single reaction, in ms
}

-- Turn flinch suppression on or off for one zombie.
--
-- Unlike the flag-clearing this replaced, there is no race to lose: the graph
-- evaluates this variable when it PICKS a node, so it does not matter whether
-- we set it before or after the hit lands. Idempotent, and cheap enough to
-- call every update.
--
-- setVariable is the ordinary animation-variable surface - the same one
-- RQSvEating and RQGlutton already use for "bPathfind" and "bMoving".
function RQFlinch.set(zombie, on)
    if not zombie then return false end
    zombie:setVariable(VARIABLE, on and true or false)
    if on then
        RQFlinch.stats.set = RQFlinch.stats.set + 1
    else
        RQFlinch.stats.cleared = RQFlinch.stats.cleared + 1
    end
    return true
end

-- Is suppression currently on for this zombie? Reads the variable back rather
-- than keeping a shadow copy, so there is one source of truth and no way for a
-- cached answer to drift from what the graph will actually see. That also
-- makes the caller self-healing: a zombie rebuilt by a chunk reload comes back
-- with an empty variable slot, and the next update re-asserts it.
function RQFlinch.isSet(zombie)
    if not zombie then return false end
    return zombie:getVariableBoolean(VARIABLE) == true
end

-- "Has this zombie just been rocked?" - and it is TWO states, not one.
--
-- CORRECTED 2026-08-24, after the first version of this shipped watching only
-- isStaggerBack() and did nothing at all against a .45. CombatManager resolves
-- every hit into ONE of two mutually exclusive outcomes (:2410-2417):
--
--     if (hitReaction != HitReaction.NONE) target.setHitReaction(value);
--     else                                 zombie.setStaggerBack(true);
--
-- A bullet resolves to a real directional HitReaction, so it takes the FIRST
-- branch and staggerBack is never set. Watching one flag catches half the
-- lanes; this is the whole surface.
function RQFlinch.isReacting(zombie)
    if not zombie then return false end
    if zombie:isStaggerBack() then return true end
    local reaction = zombie:getHitReaction()
    return reaction ~= nil and reaction ~= ""
end

-- The melee lane: end a staggerback early by zeroing the timer its exit
-- transition waits on.
--
-- NARROWLY GATED ON PURPOSE. stateEventDelayTimer is a GENERIC countdown -
-- ZombieEatBodyState:55 and ZombieIdleState:81 both wait on the same field -
-- so zeroing it unconditionally would quietly cut short unrelated behaviour,
-- including our own Gluttons mid-meal. We therefore only touch it while the
-- zombie is actually in the staggerback state, which is the one place the
-- timer means "how much longer are you stumbling".
function RQFlinch.releaseStagger(zombie)
    if not zombie then return false end
    local state = zombie:getCurrentActionContextStateName()
    if not state or string.lower(state) ~= STAGGER_STATE then return false end
    zombie:setStateEventDelayTimer(0.0)
    RQFlinch.stats.released = RQFlinch.stats.released + 1
    return true
end

-- ---------------------------------------------------------------------------
-- The witness
-- ---------------------------------------------------------------------------
-- WHY THIS REPLACED THE ANIMATION-DEBUG PROBE. The previous version turned on
-- the engine's Animation DebugLog channel at OnGameStart to catch
-- AnimState.Parse announcing "hitreaction -> AnimNode: rqflinch" (:66). It
-- armed correctly on Mosaic and caught nothing, because the anim sets are
-- parsed during LOAD - AdvancedAnimator work appears roughly 3,400 log lines
-- BEFORE OnGameStart fires. It could never have witnessed the parse, so it is
-- gone rather than left in looking useful.
--
-- This measures the thing we actually care about instead: how long a hit
-- reaction LASTS. That is better evidence than "did the file parse", because
-- it is the effect rather than a proxy for it, and it is unambiguous without
-- needing a control group - a vanilla reaction animation runs about a second,
-- so a span of one or two frames can only mean our node won selection.
--
-- Returns the completed span when a reaction ENDS, otherwise nil. Deliberately
-- returns rather than logs: the caller owns the zombie's identity and the log
-- budget, and this file should not reach for either.
-- WAS A "WEAK" TABLE UNTIL 2026-08-25, which in Kahlua means it was a strong
-- one: J2SEPlatform.newTable() hands back a LinkedHashMap and nothing in the
-- engine reads `__mode` (see RDLedger's header). A zombie that unloaded
-- mid-reaction therefore left its span row here for the life of the session,
-- pinning the IsoZombie so the engine could never collect it. The ledger's
-- liveness rule is what actually reclaims those now.
local spans = RDLedger.new({
    name = "RQFlinch.spans",
    live = function(zombie) return zombie and not zombie:isDead() end,
})

function RQFlinch.observe(zombie, now)
    if not zombie then return nil end
    local reacting = RQFlinch.isReacting(zombie)
    local span = spans.get(zombie)

    if reacting then
        if span then
            span.frames = span.frames + 1
        else
            spans.set(zombie, { startedAt = now, frames = 1 })
        end
        return nil
    end

    if not span then return nil end
    spans.remove(zombie)

    local finished = { ms = now - span.startedAt, frames = span.frames }
    RQFlinch.stats.spans = RQFlinch.stats.spans + 1
    if finished.ms > RQFlinch.stats.longest then
        RQFlinch.stats.longest = finished.ms
    end
    return finished
end

function RQFlinch.reset()
    spans.clear()
    RQFlinch.stats.set      = 0
    RQFlinch.stats.cleared  = 0
    RQFlinch.stats.released = 0
    RQFlinch.stats.spans    = 0
    RQFlinch.stats.longest  = 0
end

Events.OnGameStart.Add(RQFlinch.reset)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
