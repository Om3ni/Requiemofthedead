-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQFlinch.lua - make a zombie's hit reaction cost it nothing.
--
-- MECHANISM ONLY. This file knows how to stop a flinch from mattering; it has
-- no opinion about WHEN that should happen. RQPoise is the first caller and
-- decides the policy (how many hits, for how long). Anything else that wants a
-- zombie to shrug off a hit calls RQFlinch.set and does its own bookkeeping -
-- which is the whole point of the split.
--
-- =============================================
-- WHY THIS EXISTS, AND WHY THE OBVIOUS APPROACHES DO NOT WORK
-- =============================================
-- Owner report, 2026-08-24: a .45 kept a Boss staggered for an entire
-- encounter. Two attempts failed before this one, and both failures are worth
-- keeping written down because each looks correct from the Lua side.
--
-- ATTEMPT 1 - clear isStaggerBack(). Did nothing at all. CombatManager
-- resolves each hit into EITHER a named hit reaction OR a stagger, never both
-- (CombatManager.java:2410-2417). A bullet always takes the reaction branch, so
-- the stagger flag it was watching is never set by gunfire.
--
-- ATTEMPT 2 - clear the hit reaction string as well. The graph does read
-- exactly that (`hashitreaction` is bound live to hasHitReaction(),
-- IsoGameCharacter.java:832, which is `!isNullOrEmpty(getHitReaction())`), so
-- the target was right - but we are ALWAYS ONE FRAME LATE. The hit sets the
-- reaction, the state machine transitions, and only then does the next
-- OnZombieUpdate come round to clear it. By then the animation owns the zombie
-- and the state exits on its own schedule. Poise correctly reported breaking
-- and the Boss kept flinching, which is exactly that signature.
--
-- WHAT ACTUALLY WORKS. Stop trying to win a race we cannot win, and change
-- what the flinch COSTS instead. The animation graph is data:
-- media/AnimSets/zombie/hitreaction/ holds one animNode per reaction, each
-- picked by its conditions. We ship an extra node conditioned on a variable we
-- control, with a high m_ConditionPriority so it wins, and a speed scale that
-- makes the reaction finish almost immediately. The zombie still ENTERS the
-- state - nothing in Lua can prevent that - but it leaves within a frame or two
-- and keeps acting. Functionally that is stagger immunity.
--
-- The two halves of the graph load DIFFERENTLY, and that asymmetry is the
-- entire reason this is possible:
--
--   actiongroups (the state TRANSITIONS) - ActionGroup.load() uses
--     getMediaFile() plus listFiles() on the base directory. NOT mod-loadable.
--     This is why we cannot simply refuse the transition.
--   AnimSets (the animation NODES) - AnimationSet:54 uses
--     resolveAllDirectories -> walkGameAndModFiles, which IS mod-aware.
--
-- Selection is decided by AnimNode.compareSelectionConditions (:287-301):
-- abstract-ness first, then m_ConditionPriority, then condition COUNT. Our node
-- sets an explicit priority rather than relying on having more conditions,
-- because relying on the count would silently lose the day vanilla adds one.
--
-- CHECKSUM WARNING. AdvancedAnimator.load() hashes base AND mod AnimSets into
-- NetChecksum (:757-760). Shipping this file changes the animation checksum, so
-- client and server must carry byte-identical copies. That is fine for this
-- suite - one atomic Workshop item - but it means a client with a stale copy is
-- REJECTED rather than desynced, and that is the first place in this codebase
-- where a media file has to match across the wire.
-- =============================================

require "RQCommon"

RQFlinch = RQFlinch or {}

-- The animation variable our AnimSets node keys on. Changing this string means
-- changing media/AnimSets/zombie/hitreaction/RQFlinch.xml to match, and a
-- mismatch fails SILENTLY - the node simply never wins and flinches look
-- normal. Kept here as the single definition so the pair is findable.
local VARIABLE = "RQNoFlinch"
RQFlinch.VARIABLE = VARIABLE

RQFlinch.stats = {
    set     = 0,
    cleared = 0,
}

-- Turn flinch suppression on or off for one zombie.
--
-- Unlike the flag-clearing this replaced, there is no race to lose: the graph
-- evaluates this variable when it picks a node, so it does not matter whether
-- we set it before or after the hit lands. Idempotent, and cheap enough to call
-- every update.
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
-- cached answer to drift from what the graph will actually see.
function RQFlinch.isSet(zombie)
    if not zombie then return false end
    return zombie:getVariableBoolean(VARIABLE) == true
end

function RQFlinch.reset()
    RQFlinch.stats.set     = 0
    RQFlinch.stats.cleared = 0
end

-- ---------------------------------------------------------------------------
-- Diagnostic: did our animation node actually load?
-- ---------------------------------------------------------------------------
-- TEMPORARY INSTRUMENTATION, and the removal condition is written down: delete
-- this whole block once one Mosaic boot has confirmed the node either loads or
-- does not. It exists because the failure mode we cannot otherwise see is
-- SILENCE - if the XML is never found, nothing throws, nothing logs, and the
-- feature simply has no effect, which is indistinguishable from the node
-- loading and losing selection. Three attempts at this feature have now failed
-- in ways that looked identical from Lua, so the next one gets a witness.
--
-- What this does: turns on the engine's own Animation debug channel, which
-- makes AnimState.Parse announce every node it loads
-- ("hitreaction -> AnimNode: rqflinch"). It does NOT need -Ddebug: DebugLog is
-- setExposed and this is the same surface vanilla's DebugLogSettings.lua uses.
-- Anim sets load lazily on first use, so switching the channel on at game start
-- is normally early enough to catch the zombie set being parsed.
--
-- Every call is presence-checked. This is instrumentation; it must not be the
-- reason a client fails to start.
function RQFlinch.armNodeDiagnostic()
    if not DebugLog or not DebugLog.getDebugTypes then return false end
    local types = DebugLog.getDebugTypes()
    if not types or not types.size then return false end
    for i = 0, types:size() - 1 do
        local t = types:get(i)
        if t and tostring(t) == "Animation" then
            if DebugLog.setLogEnabled then
                DebugLog.setLogEnabled(t, true)
                print("[Dirge:Flinch] node diagnostic armed - watch for "
                    .. "'hitreaction -> AnimNode: rqflinch' at anim-set load")
                return true
            end
        end
    end
    return false
end

Events.OnGameStart.Add(function()
    -- DebugMode only: the Animation channel is chatty, and a release client
    -- should never pay for a diagnostic.
    if RQConfig and RQConfig.get and RQConfig.get().debugMode then
        RQFlinch.armNodeDiagnostic()
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
