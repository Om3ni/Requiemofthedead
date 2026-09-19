-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQSvHit.lua - Dirge's single server-side hit intake.
--
-- ONE LISTENER. Every combat responsibility that needs to know a special was
-- struck goes through here in a fixed order, rather than each module adding its
-- own OnHitZombie handler and inheriting whatever order the engine happens to
-- register them in. Before this file there was exactly one such listener
-- (Scavenger rage); the point is that there is still exactly one after the
-- others landed on it.
--
-- WHERE THIS RUNS, and why the answer is not obvious. On a dedicated server a
-- client's attack does not stay on the client: the hit crosses the wire and the
-- server applies it through WeaponHit.process, which calls
-- target.Hit(weapon, wielder, damage, ignore, range, true) - the trailing true
-- being bRemote (WeaponHit.java:72). IsoZombie.Hit fires OnHitZombie at
-- IsoZombie.java:1107, BEFORE delegating to the base character pipeline at
-- :1109, so this listener sees the hit while the damage is still undecided.
--
-- WHAT THE SERVER DOES NOT DO is decide the damage. IsoGameCharacter.java:5723
-- reads `bRemote ? damageSplit : processHitDamage(...)` - on the remote path the
-- attacker's own number is taken verbatim, and the attacking client owns the
-- zombie's health besides. That is why Dirge's durability levers all land on
-- the ATTACKING CLIENT: clothing defence on the livery items (read from the
-- item during attack resolution, before Hit is ever called), the weapon term
-- RQDread registers with RQSuppress, and RQPoise's reaction naming. The
-- server-side soak that used to be dispatched LAST from this file - RQBulwark,
-- setAvoidDamage on the server's copy - protected only the server's copy of a
-- zombie the server did not own; it was retired 2026-09-17 on the Bulwark
-- lab's reading of exactly this path, and the debug probe that existed to ask
-- whether it held went with it. Nothing decided here mitigates; this file
-- notifies - and since 2026-09-17 one of the things it notifies is the
-- escort: a struck Juggernaut or Boss musters the ordinary zombies in its
-- aura onto the attacker (RQSvMuster, applied by each owning client).
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
require "RQSvMuster"

RQSvHit = RQSvHit or {}

-- No setActiveZombies here on purpose. RQSvShared already holds the injected
-- registry and exposes RQSvShared.typeOf as the one place that answers "what
-- kind of special is this" - registry first, the zombie's own RQType second.
-- A fifth copy of the injector was the first thing check-helpers rejected
-- about this file, and it was right to: the resolution rule belongs in one
-- place, not once per module that needs to ask.

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
-- Always on, because they are integer increments and answering "did the intake
-- ever run, and what did it turn away" must not require a server restart with a
-- debug flag.
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
-- Dispatch
-- ---------------------------------------------------------------------------
-- THE ORDER IS DELIBERATE AND IS THE WHOLE REASON THIS FILE EXISTS.
--
--   1. Scavenger rage      - a passive Scavenger becomes hostile
--   2. RQMcCoy.onAttacked  - arm/refresh the healing window
--   3. RQBloodhound        - acquire a ranged attacker
--   4. RQSvMuster          - a struck Juggernaut or Boss musters its escort
--
-- Rage first, because everything after it reads the Scavenger's state:
-- Bloodhound pursues an ENRAGED Scavenger and a hit that both enrages and is
-- pursued must be read in that order, not the reverse. Muster last: it
-- mutates nothing on the server and only tells clients, so every stage that
-- changes state has done so before the notification goes out. There is deliberately
-- no registration framework and no nil-guarded call to a module that does not
-- exist - a slot that silently does nothing is indistinguishable from a slot
-- that is broken.
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
    RQSvMuster.onAttacked(ctx)
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
    -- attack is a provocation any of these responsibilities cares about.
    if not instanceof(wielder, "IsoPlayer") then return refuse("not-player") end
    if zombie:isDead() then return refuse("already-dead") end

    -- Specials only. An ordinary zombie used to reach this far so that the
    -- soak could ask whether a special's aura covered it; with the soak
    -- retired nothing downstream has a use for an ordinary hit, and it is
    -- refused by name again rather than dispatched to three modules that
    -- would each decline it.
    local zType = RQSvShared.typeOf(zombie)
    if not zType then return refuse("not-special") end

    -- isRanged is a plain field return (HandWeapon.java:824-826), but `weapon`
    -- is whatever the player swung: nil for fists, and an InventoryItem that is
    -- not a HandWeapon carries no such method. Indexing an absent method yields
    -- nil rather than throwing, so the presence test IS the guard and no pcall
    -- is warranted. isRanged() rather than isAimedFirearm() is a decided policy
    -- (owner, 2026-08-24): crossbows and modded ranged weapons count, which is
    -- wider than RQDread's firearm band on the client.
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
