-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSuppress - the family's weapon suppression service (client-side).
--
-- Owns EVERY write to a weapon's damage fields.
--
-- DIRGE NO LONGER USES THIS FILE. Read that first, because the history below
-- is about a feature that is gone. Slice 6 of the Bulwark rework (2026-08-24)
-- removed Dirge's four terms - the three per-type aura sources and the ranged
-- engagement band - and RQBulwark now mitigates on the SERVER, against the
-- zombie that was actually struck. What survives here is the registry and its
-- composition model, kept for RFTDLimes, which is a real external consumer
-- (LMSuppress.lua:67). The removal note further down states why both answers
-- could not coexist.
--
-- HOW IT GOT THIS SHAPE. It grew out of RQJuggernaut's applyAura/releaseAura
-- pair, which had two structural holes once suppression stopped being a single
-- on/off aura. Both are worth keeping written down: the first is a property of
-- the registry and is still load-bearing for Limes, and the second is the
-- exploit that eventually justified moving the whole mechanic server-side.
--
--   1. STACKING - still true, still the design. applyAura was a no-op when the
--      weapon was already tagged, so a second suppression source arriving
--      mid-suppression was silently discarded -- the exact case the RFTDLimes
--      zone term multiplies into. Here the original damage is snapshotted ONCE
--      and every write computes original * effective, so the effective
--      multiplier can deepen, shallow, or change sources without ever
--      re-snapshotting nerfed values as "original".
--
--   2. THE KITING EXPLOIT - fixed, but NOT here any more. The debuff was gated
--      on the player standing inside a ~3-tile aura while firearms operate
--      from far outside it: aggro a Juggernaut, step out of the ring, and
--      shotguns fired at full damage. Players were dropping Juggernauts in
--      seconds on the live box. This file's answer was a weapon-class-aware
--      source that extended the band to cfg.rangedProtectRadius; that answer
--      was removed with the rest of Dirge's terms. The hole stays closed
--      because RQBulwark soaks on the server no matter where the shooter is
--      standing, so there is no band left to step outside of.
--
-- COMPOSITION MODEL (locked in design review, live for RFTDLimes):
--   * Sources register into TERM GROUPS. Within a group the deepest (minimum)
--     multiplier among active sources wins -- the three aura specials share
--     one config value today, so that min is currently a formality.
--   * Across groups, terms MULTIPLY. When Limes lands, its per-zone term
--     stacks against the aura term (0.6 zone x 0.4 aura = 0.24 weapon
--     damage). Intentional: an escorted special inside a hard zone is meant
--     to be a strategic decision, not a DPS check. Register a zone source as:
--         RQSuppress.register("zone", "limes", function(player, weapon)
--             return zoneMultOrNil
--         end)
--   * LINGER: a group stays active LINGER_MS after its last active frame, so
--     duck-out-fire-duck-in rhythm never sees a full-damage window. This
--     deliberately softened the old "restores when you leave the aura" tooltip
--     promise by three seconds. That tooltip was Dirge's and no longer
--     describes anything this file does; the behaviour remains correct for a
--     zone term, which is what is left.
--
-- The write path runs every render tick while suppressed and is deliberately
-- unconditional: two float field writes on an inventory item, no network.
-- The old change-detection guard was what let a weapon swapped in from a bag
-- keep a stale multiplier; recomputing from the snapshot each frame makes
-- staleness unrepresentable.
--
-- TAG COMPATIBILITY: the modData keys are the same RQOrigMin/RQOrigMax the
-- shipped version used, so weapons tagged by either version are restored by
-- the other's login sweep. Do not rename them.

RQSuppress = RQSuppress or {}

local LINGER_MS = 3000

-- groupId -> {
--   sources    = { sourceId -> predicate(player, weapon) -> mult | nil },
--   lingerAt   = ms timestamp until which the group stays active after its
--                sources all go quiet,
--   lingerMult = the mult held through the linger window,
-- }
local groups = {}

-- groupId -> { sourceId -> true }. A foreign predicate can be evaluated every
-- render tick, so its failure must be visible without turning one bad source
-- into an unbounded client-log stream.
local predicateFaults = {}

-- Multiplier currently written into weapon fields (1.0 = clean). Tracked so
-- the exit sweep fires exactly once per suppression episode.
local appliedEffective = 1.0

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
-- predicate(player, weapon) returns a damage multiplier (0..1) while the
-- source is active, or nil/false while it is not. weapon can be nil (fists,
-- bare hands) -- predicates that need one must handle that.
function RQSuppress.register(groupId, sourceId, predicate)
    if type(predicate) ~= "function" then
        print("[Dirge] RQSuppress.register: no predicate for "
            .. tostring(groupId) .. "." .. tostring(sourceId))
        return
    end
    local g = groups[groupId]
    if not g then
        g = { sources = {}, lingerAt = 0, lingerMult = 1.0 }
        groups[groupId] = g
    end
    g.sources[sourceId] = predicate
    local faults = predicateFaults[groupId]
    if faults then faults[sourceId] = nil end
end

-- ---------------------------------------------------------------------------
-- Effective multiplier
-- ---------------------------------------------------------------------------
local function computeEffective(player, weapon, now)
    local effective = 1.0
    for groupId, g in pairs(groups) do
        local mult = nil
        for sourceId, predicate in pairs(g.sources) do
            -- guard stays: predicates are registered by other RotD modules (and
            -- potentially other mods) through RQSuppress.register; one broken
            -- source must not take the whole multiplier pass down.
            local ok, m = pcall(predicate, player, weapon)
            if not ok then
                local faults = predicateFaults[groupId]
                if not faults then
                    faults = {}
                    predicateFaults[groupId] = faults
                end
                if not faults[sourceId] then
                    faults[sourceId] = true
                    print("[RFTDDirge] RQSuppress predicate "
                        .. tostring(groupId) .. "." .. tostring(sourceId)
                        .. " failed: " .. tostring(m))
                end
            elseif m then
                m = tonumber(m)
                if m and (not mult or m < mult) then
                    mult = m
                end
            end
        end
        if mult then
            g.lingerAt   = now + LINGER_MS
            g.lingerMult = mult
        elseif now < g.lingerAt then
            mult = g.lingerMult
        end
        if mult and mult < 1.0 then
            effective = effective * math.max(0, mult)
        end
    end
    return effective
end

-- ---------------------------------------------------------------------------
-- Weapon writes
-- ---------------------------------------------------------------------------
-- Snapshot once; every write recomputes from the snapshot. Never read the
-- weapon's live damage as a base while tagged -- that bakes a nerf in as
-- "original", which is exactly the corruption the old applyAura guard
-- existed to prevent (and the reason it couldn't stack).
local function writeWeapon(weapon, effective)
    local wmd = weapon:getModData()
    if not wmd["RQOrigMin"] then
        wmd["RQOrigMin"] = weapon:getMinDamage()
        wmd["RQOrigMax"] = weapon:getMaxDamage()
    end
    weapon:setMinDamage(wmd["RQOrigMin"] * effective)
    weapon:setMaxDamage(wmd["RQOrigMax"] * effective)
end

local function restoreItem(item)
    local imd = item:getModData()
    if not imd["RQOrigMin"] then return false end
    item:setMinDamage(imd["RQOrigMin"])
    item:setMaxDamage(imd["RQOrigMax"])
    imd["RQOrigMin"] = nil
    imd["RQOrigMax"] = nil
    return true
end

-- Full-inventory sweep: suppression exit and login. Covers weapons holstered
-- or bagged while suppressed, same reasoning as the old releaseAura.
local function restoreAll(player)
    local inv = player:getInventory()
    if not inv then return end
    local items = inv:getItems()
    if not items then return end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.setMinDamage and item.getModData then
            if restoreItem(item) then
                RQDirgeLog.write("Suppress", "[INFO] restored weapon "
                    .. tostring(item:getName()))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- No built-in sources
-- ---------------------------------------------------------------------------
-- Dirge's four terms - the three per-type aura sources and the ranged
-- engagement band - were removed on 2026-08-24. RQBulwark decides tank
-- mitigation now, on the server, against the zombie that was actually struck.
--
-- WHY BOTH COULD NOT STAY. They are two answers to one question, and they
-- compound: a Juggernaut would have soaked the hit AND the hit would have been
-- weakened before it arrived. Beyond the balance nonsense, the older answer was
-- structurally weaker in two ways that are worth recording rather than
-- rediscovering. It changed the WEAPON, so it applied to every target the
-- player swung at, not only the special that earned it. And it was computed on
-- the attacking client, which is where the number the server accepts comes from
-- (see IsoGameCharacter.java:5723 and RQSvHit's header) - so it was
-- client-trusted by construction.
--
-- THE SERVICE STAYS. This file is a registry with a real external consumer:
-- RFTDLimes registers a per-zone term through RQSuppress.register, and the
-- term-group composition model exists for exactly that. Deleting the file
-- because its first consumer stopped using it would break a second one.
--
-- The `playerInAura` flags the aura term read are gone from RQBoss,
-- RQJuggernaut and RQScavenger with it. Their render ticks remain - they still
-- draw the ground rings and highlights - but nothing publishes a flag that
-- nothing reads.

-- ---------------------------------------------------------------------------
-- Main tick
-- ---------------------------------------------------------------------------
Events.OnRenderTick.Add(function()
    local player = getPlayer()
    if not player then return end

    local weapon = player:getPrimaryHandItem()
    if weapon and not weapon.setMinDamage then weapon = nil end

    local now       = getTimestampMs()
    local effective = computeEffective(player, weapon, now)

    if effective < 1.0 then
        if effective ~= appliedEffective then
            RQDirgeLog.write("Suppress", "[INFO] effective "
                .. string.format("%.2f", appliedEffective) .. " -> "
                .. string.format("%.2f", effective))
        end
        if weapon then
            writeWeapon(weapon, effective)
        end
    elseif appliedEffective < 1.0 then
        -- Suppression episode over (linger included): one sweep, then clean.
        RQDirgeLog.write("Suppress", "[INFO] suppression ended, restoring")
        restoreAll(player)
    elseif weapon then
        -- Steady clean state: reconcile-on-equip. A looted or traded weapon
        -- can arrive carrying another player's tag; zones will make that
        -- routine rather than corner-case, so it heals the moment it is
        -- drawn instead of at that player's next login.
        if restoreItem(weapon) then
            RQDirgeLog.write("Suppress", "[INFO] reconciled orphaned tag on "
                .. tostring(weapon:getName()))
        end
    end

    appliedEffective = effective
end)

Events.OnGameStart.Add(function()
    appliedEffective = 1.0
    for _, g in pairs(groups) do
        g.lingerAt   = 0
        g.lingerMult = 1.0
    end
    -- Weapon modData persists across sessions. If the player reconnects with
    -- a weapon still tagged from a prior session (crash mid-suppression, or
    -- a tagged weapon acquired in trade), restore it now.
    local player = getPlayer()
    if player then restoreAll(player) end
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
