-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQPoise.lua - Bulwarks do not flinch, full stop.
--
-- THE PROBLEM, measured 2026-08-24: a .45 kept a Boss staggered for an entire
-- encounter. Anything with a fast cycle does it - SMGs, shotguns, a fast melee
-- swing - because each hit re-triggers the reaction before the last one ends.
--
-- THE POLICY, owner decision 2026-08-25: FLAT IMMUNITY. A Bulwark does not
-- stumble and cannot be put on the floor. There is no counter and no window.
-- One stated exception, engine-imposed: a critical firearm hit routes into the
-- shothead fall on the reaction string alone, in the same tick that set it, so
-- it cannot be refused from Lua - RQFlinch compresses that fall to ~10 frames
-- instead. A crit reads as a dip-and-recover; everything else lands as a
-- 2-6 frame twitch.
--
-- WHAT THIS REPLACED, and why the replacement is not a loss. This file used to
-- implement poise: absorb a rolled number of staggers, then go immune for a
-- rolled duration. That model is gone. It was designed to keep the break point
-- uncountable, but flat immunity has no break point to hide, so the randomiser
-- had nothing left to do. It also cost two shipped attempts to discover that
-- the counting was never the part that did not work - the SUPPRESSION was
-- (see RQFlinch). Deleting the cycle removes the machinery that made those
-- failures hard to read.
--
-- WHY BULWARK CANNOT FIX THIS, and why raising its soak rates would have been
-- wasted work. The flinch is not part of the damage path. CombatManager
-- resolves each hit into a reaction on the ATTACKING side, and Bulwark's soak
-- exits at IsoGameCharacter.java:5711 - before hitConsequences ever runs - so
-- server-side a soaked hit produces no reaction at all. The client reacts
-- regardless. A fully soaked hit still flinches.
--
-- HOW THE FLINCH IS ACTUALLY DEFEATED: not by refusing it, which we cannot do
-- from Lua, but by making it cost nothing. RQFlinch owns that mechanism, owns
-- both of its lanes, and explains both. This file owns only WHO gets it.
--
-- WHY THIS IS CLIENT-SIDE while the rest of the mitigation family is not.
-- The reaction is entered by the animation graph on the machine simulating the
-- zombie, and that is the owning client for anything a player is shooting -
-- the hit probe recorded owner=client on 90 of 90 hits. The engine agrees hard
-- enough to enforce it: IsoGameCharacter.setVariable is a no-op for a zombie
-- when GameServer.server (:11343-11346), so there is no server-side version of
-- this to write. Bulwark therefore owns a server-side soak and this file owns
-- a client-side stagger rule; that split is real and is stated rather than
-- hidden.
--
-- ADDING A TYPE is one row in TYPES below. The mechanism is type-agnostic, so
-- extending immunity to another zombie is a data change, not a code change.
-- =============================================

-- No isServer guard: media/lua/client is client-only, and no other file in this
-- directory carries one. The per-zombie owner gate lives in update().

require "RDLedger"
require "RDZombieId"
require "RQCommon"
require "RQDirgeLog"
require "RQFlinch"
require "RQRegistry"
require "RQReconcile"

RQPoise = RQPoise or {}

-- Who is a Bulwark. Screamers, EMPs, Gluttons and passive Scavengers are
-- absent on purpose - they are not tanks, and being staggerable is most of
-- what makes them fragile.
local TYPES = {
    Boss       = true,
    Juggernaut = true,
    Scavenger  = true,   -- enraged only; see typeFor
}
RQPoise.TYPES = TYPES

-- Bounded instrumentation (CLAUDE.md section 14). Reaction spans are the only
-- evidence that RQFlinch's node is winning selection at all, so they are worth
-- logging - but a long firefight against several Bulwarks would otherwise
-- emit a line per hit per zombie. After this many the counters keep running
-- and the log goes quiet. Remove the whole span-logging block once a Mosaic
-- run has confirmed the node wins; RQFlinch.stats.longest is the number that
-- settles it.
local SPAN_LOG_LIMIT = 40

-- WAS A "WEAK" TABLE UNTIL 2026-08-25, and in Kahlua that meant a strong one -
-- `__mode` is never read (see RDLedger's header). It leaked for a specific
-- reason worth stating: update() returns early on isDead(), so a Bulwark's row
-- was never reached again after it died and stayed here pinning the IsoZombie
-- for the session. The ledger's liveness rule is what reclaims it now, and the
-- background sweep is what catches the chunk-unload case that fires no death
-- event at all.
local tracked = RDLedger.new({
    name = "RQPoise.tracked",
    live = function(zombie) return zombie and not zombie:isDead() end,
})
RQPoise.tracked = tracked

RQPoise.stats = {
    guarded = 0,    -- zombies that entered immunity
    released = 0,   -- zombies that stopped qualifying and were handed back
    logged  = 0,    -- span lines emitted
    byType  = {},
}

-- Which type applies to this zombie RIGHT NOW, or nil.
--
-- A Scavenger only qualifies while ENRAGED, matching Bulwark: a passive
-- Scavenger is not a tank and takes full damage and full stagger. That is the
-- sleeper-threat design, not an oversight.
local function typeFor(onlineID)
    local zType = RQRegistry.getType(onlineID)
    if not zType or not TYPES[zType] then return nil end
    if zType == "Scavenger" then
        local state = RQReconcile.scavClientState[onlineID]
        if not (state and state.enraged) then return nil end
    end
    return zType
end

-- One zombie, one frame. Called from OnZombieUpdate.
function RQPoise.update(zombie, now)
    if not zombie or zombie:isDead() then return end
    -- Owner-only, the same gate RQGlutton's navigation uses. Non-owning
    -- clients may briefly render a reaction the owner already ended - the flag
    -- is not carried in NetworkZombieVariables, so it does not propagate - and
    -- the owner's position updates settle it.
    if isClient() and zombie:isRemoteZombie() then return end

    -- `<= 0` here until 2026-08-25, which denied immunity to every zombie past
    -- the short wrap - about half the population on a long-running server. See
    -- RDZombieId: -1 is the only invalid id, negative ids are ordinary.
    local onlineID = RDZombieId.of(zombie)
    if not onlineID then return end

    local zType = typeFor(onlineID)
    if not zType then
        -- A zombie that stops qualifying (a Scavenger row can outlive a
        -- reload) must not keep its immunity. Only touched when we actually
        -- have a row, so an ordinary zombie never costs an engine call here.
        if tracked.get(zombie) then
            RQFlinch.set(zombie, false)
            tracked.remove(zombie)
            RQPoise.stats.released = RQPoise.stats.released + 1
        end
        return
    end

    if not tracked.get(zombie) then
        tracked.set(zombie, zType)
        RQPoise.stats.guarded = RQPoise.stats.guarded + 1
        RQPoise.stats.byType[zType] = (RQPoise.stats.byType[zType] or 0) + 1
    end

    -- ASSERTED FROM THE ENGINE'S OWN ANSWER, not from a shadow flag. The
    -- variable lives on the zombie, and a zombie rebuilt by a chunk reload
    -- comes back without it; reading it back each pass makes that self-healing
    -- and costs one call. Writing it only when it is actually missing keeps
    -- this off the per-frame write path.
    if not RQFlinch.isSet(zombie) then
        RQFlinch.set(zombie, true)
    end

    -- The melee lane. No-ops unless the zombie is genuinely mid-staggerback.
    RQFlinch.releaseStagger(zombie)

    -- The witness. Returns a span only on the frame a reaction ENDS.
    local span = RQFlinch.observe(zombie, now)
    if span and RQPoise.stats.logged < SPAN_LOG_LIMIT then
        RQPoise.stats.logged = RQPoise.stats.logged + 1
        -- The ROUTE is the half that names a lane. A long span alone says the
        -- suppression lost; the state list says WHERE - which is the evidence
        -- the knockdown-ordering question needs and could not get from
        -- reading the graph (hitreaction/RQFlinch.xml). Omitted entirely when
        -- empty rather than printed as an empty clause.
        local route = RQFlinch.routeText(span)
        RQDirgeLog.write("Poise", "[INFO] " .. zType .. " id=" .. tostring(onlineID)
            .. " reaction ended in " .. tostring(span.frames) .. " frames / "
            .. tostring(span.ms) .. "ms"
            .. (route and (" via " .. route) or "")
            .. (RQPoise.stats.logged == SPAN_LOG_LIMIT and " (span log full)" or ""))
    end
end

Events.OnZombieUpdate.Add(function(zombie)
    RQPoise.update(zombie, getTimestampMs())
end)

function RQPoise.reset()
    tracked.clear()
    RQPoise.stats.guarded  = 0
    RQPoise.stats.released = 0
    RQPoise.stats.logged   = 0
    RQPoise.stats.byType   = {}
end

Events.OnGameStart.Add(RQPoise.reset)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
