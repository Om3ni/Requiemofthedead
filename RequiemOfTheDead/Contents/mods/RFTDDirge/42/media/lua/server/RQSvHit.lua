-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQSvHit.lua - Dirge's single server-side hit intake.
--
-- ONE LISTENER. Every combat responsibility that needs to know a special was
-- struck goes through here in a fixed order, rather than each module adding its
-- own OnHitZombie handler and inheriting whatever order the engine happens to
-- register them in. Before this file there was exactly one such listener
-- (Scavenger rage); the point is that there is still exactly one after three
-- more responsibilities land on it.
--
-- WHERE THIS RUNS, and why the answer is not obvious. On a dedicated server a
-- client's attack does not stay on the client: the hit crosses the wire and the
-- server applies it through WeaponHit.process, which calls
-- target.Hit(weapon, wielder, damage, ignore, range, true) - the trailing true
-- being bRemote (WeaponHit.java:72). IsoZombie.Hit fires OnHitZombie at
-- IsoZombie.java:1107, BEFORE delegating to the base character pipeline at
-- :1109, so this listener sees the hit while the damage is still undecided.
-- That pre-damage position is what makes target-side mitigation possible at all.
--
-- WHAT THE SERVER DOES NOT DO is recompute the damage. IsoGameCharacter.java:5723
-- reads `bRemote ? damageSplit : processHitDamage(...)` - on the remote path the
-- attacker's own number is taken verbatim. Worth stating plainly because it is
-- the reason the shipped mitigation model is client-trusted: RQSuppress nerfs
-- the client's weapon fields so the client sends a smaller number. Anything
-- decided in THIS file is decided server-side instead.
--
-- ORDER IS THE CONTRACT. See dispatch() below.
-- =============================================

if not isServer() then return end

require "RQCommon"
require "RQDirgeLog"
require "RQSvShared"
require "RQSvScavenger"
require "RQMcCoy"
require "RQBloodhound"
require "RQBulwark"

RQSvHit = RQSvHit or {}

-- No setActiveZombies here on purpose. RQSvShared already holds the injected
-- registry and now exposes RQSvShared.typeOf as the one place that answers
-- "what kind of special is this" - registry first, the zombie's own RQType
-- second. A fifth copy of the injector was the first thing check-helpers
-- rejected about this file, and it was right to: the resolution rule belongs in
-- one place, not once per module that needs to ask.

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
-- Always on, because they are integer increments and answering "did the intake
-- ever run, and what did it turn away" must not require a server restart with a
-- debug flag. The expensive probe below is a separate decision.
RQSvHit.stats = {
    seen       = 0,   -- OnHitZombie fired at all
    dispatched = 0,   -- survived validation and reached the modules
    refused    = {},  -- reason -> count
}

local function refuse(reason)
    local r = RQSvHit.stats.refused
    r[reason] = (r[reason] or 0) + 1
end

-- ---------------------------------------------------------------------------
-- The probe (Slice 1 deliverable, debug-gated)
-- ---------------------------------------------------------------------------
-- This exists to answer ONE question that no amount of decompile reading
-- settles: for a zombie owned by a remote client, does a server-side
-- setAvoidDamage actually hold, or does the owning client's next sync overwrite
-- the outcome? RQSvShared's health path already documents that pure server-side
-- setHealth gets clobbered by NetworkZombiePacker.applyZombie on the next
-- inbound sync, so the same question has to be asked of avoidance rather than
-- assumed. The counters below split every qualifying hit by who owns the target.
--
-- REMOVAL: this is instrumentation, not behaviour. It stays behind DebugMode
-- and Slice 8 decides whether it is retired or kept as a standing diagnostic.
-- It must never become load-bearing for a gameplay decision.
local PROBE_LOG_MAX = 200
RQSvHit.probe = {
    logged      = 0,
    suppressed  = 0,
    ownerServer = 0,  -- getOwnerPlayer() nil: this server is authoritative
    ownerClient = 0,  -- a remote client owns the zombie
    remoteFlag  = 0,  -- isRemoteZombie() true
    ranged      = 0,
    melee       = 0,
    unarmed     = 0,
    byType      = {},
}

local function probe(ctx)
    local p = RQSvHit.probe
    -- getOwnerPlayer is nullable BY DESIGN: no owner means this server already
    -- owns the zombie (IsoZombie.java:454-456, via NetworkZombieComponent).
    local owner = ctx.zombie:getOwnerPlayer()
    if owner then p.ownerClient = p.ownerClient + 1
    else p.ownerServer = p.ownerServer + 1 end
    if ctx.zombie:isRemoteZombie() then p.remoteFlag = p.remoteFlag + 1 end

    if not ctx.weapon then p.unarmed = p.unarmed + 1
    elseif ctx.isRanged then p.ranged = p.ranged + 1
    else p.melee = p.melee + 1 end

    p.byType[ctx.zType] = (p.byType[ctx.zType] or 0) + 1

    if p.logged >= PROBE_LOG_MAX then
        p.suppressed = p.suppressed + 1
        return
    end
    p.logged = p.logged + 1
    -- Owner is recorded as a CATEGORY, never a username. Who owns a zombie is
    -- an engine bookkeeping detail; naming the player would put an identity in
    -- a stream that has no operational need for one.
    RQDirgeLog.write("Hit", "[PROBE] type=" .. tostring(ctx.zType)
        .. " owner=" .. (owner and "client" or "server")
        .. " remote=" .. tostring(ctx.zombie:isRemoteZombie())
        .. " weapon=" .. (ctx.weapon and (ctx.isRanged and "ranged" or "melee") or "unarmed")
        -- Health BEFORE the pipeline runs. Lethality is deliberately not
        -- reported: this listener fires ahead of the damage calculation, so
        -- whether the hit kills is not knowable here, and guessing from
        -- damageSplit would be wrong for exactly the bRemote reason in the
        -- header. hpBefore is what is actually observable at this point.
        .. " hpBefore=" .. string.format("%.2f", ctx.zombie:getHealth())
        .. (p.logged == PROBE_LOG_MAX and "  (probe log cap reached)" or ""))
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------
-- THE ORDER IS DELIBERATE AND IS THE WHOLE REASON THIS FILE EXISTS.
--
--   1. Scavenger rage      - a passive Scavenger becomes hostile
--   2. RQMcCoy.onAttacked  - arm/refresh the healing window      (Slice 4)
--   3. RQBloodhound        - acquire a ranged attacker           (Slice 3)
--   4. RQBulwark.resolve   - decide whether the hit penetrates   (Slice 2)
--
-- Bulwark goes LAST so that a successful soak cannot suppress the three
-- decisions above it. A soaked hit is still an attack: it still enrages, still
-- arms healing, still makes a shooter the quarry. Putting mitigation first
-- would make a well-armoured target progressively harder to provoke, which is
-- the opposite of the intent.
--
-- Slices 2-4 add their line at the marked position. There is deliberately no
-- registration framework and no nil-guarded call to a module that does not
-- exist yet - a slot that silently does nothing is indistinguishable from a
-- slot that is broken.
local function dispatch(ctx)
    -- Type-gated HERE rather than inside onPlayerHit. The listener this
    -- replaced tested `zType ~= "Scavenger"` before calling; dropping that test
    -- and relying on onPlayerHit finding no state row for a Juggernaut would
    -- work today and would be an accident, not a contract. The intake knows the
    -- type, so the intake states it.
    if ctx.zType == "Scavenger" then
        RQSvScavenger.onPlayerHit(ctx.zombie)
    end

    RQMcCoy.onAttacked(ctx)
    RQBloodhound.onAttacked(ctx)

    -- LAST. Everything above has already run, so a successful soak cannot stop
    -- a Scavenger enraging, a healing window arming, or a shooter being marked.
    RQBulwark.resolve(ctx)
end

-- ---------------------------------------------------------------------------
-- Intake
-- ---------------------------------------------------------------------------
-- Builds the normalized context every downstream module reads, or refuses with
-- a named reason. Nothing here trusts a client command: the engine hands us the
-- zombie, the wielder and the weapon directly.
function RQSvHit.onHitZombie(zombie, wielder, bodyPart, weapon)
    RQSvHit.stats.seen = RQSvHit.stats.seen + 1

    if not zombie then return refuse("no-zombie") end
    if not wielder then return refuse("no-wielder") end
    -- Zombie-on-zombie and environmental damage both reach Hit(). Only a player
    -- attack is a provocation any of these four responsibilities cares about.
    if not instanceof(wielder, "IsoPlayer") then return refuse("not-player") end
    if zombie:isDead() then return refuse("already-dead") end

    local zType = RQSvShared.typeOf(zombie)
    if not zType then return refuse("not-special") end

    -- isRanged is a plain field return (HandWeapon.java:824-826), but `weapon`
    -- is whatever the player swung: nil for fists, and an InventoryItem that is
    -- not a HandWeapon carries no such method. Indexing an absent method yields
    -- nil rather than throwing, so the presence test IS the guard and no pcall
    -- is warranted. isRanged() rather than isAimedFirearm() is a decided policy
    -- (owner, 2026-08-24): crossbows and modded ranged weapons count, which is
    -- wider than the shipped RQSuppress band.
    local isRanged = (weapon ~= nil and weapon.isRanged ~= nil and weapon:isRanged()) or false

    local ctx = {
        zombie         = zombie,
        attacker       = wielder,
        weapon         = weapon,
        bodyPart       = bodyPart,
        zType          = zType,
        isPlayerAttack = true,
        isRanged       = isRanged,
        now            = getTimestampMs(),
    }

    RQSvHit.stats.dispatched = RQSvHit.stats.dispatched + 1
    if RQSvShared.getSvConfig().debugMode then probe(ctx) end
    dispatch(ctx)
end

Events.OnHitZombie.Add(RQSvHit.onHitZombie)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
