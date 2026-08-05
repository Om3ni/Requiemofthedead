-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSuppress - the family's weapon suppression service (client-side).
--
-- Owns EVERY write to a weapon's damage fields. Grew out of RQJuggernaut's
-- applyAura/releaseAura pair, which had two structural holes once suppression
-- stopped being a single on/off aura:
--
--   1. STACKING. applyAura was a no-op when the weapon was already tagged, so
--      a second suppression source arriving mid-suppression was silently
--      discarded -- the exact case the RFTDLimes zone term multiplies into.
--      Here the original damage is snapshotted ONCE and every write computes
--      original * effective, so the effective multiplier can deepen, shallow,
--      or change sources without ever re-snapshotting nerfed values as
--      "original".
--
--   2. THE KITING EXPLOIT. The debuff was gated on the player standing inside
--      a ~3-tile aura while firearms operate from far outside it: aggro a
--      Juggernaut, step out of the ring, and shotguns fired at full damage.
--      Players were dropping Juggernauts in seconds on the live box. Sources
--      are now weapon-class aware: holding a firearm extends the engagement
--      band to cfg.rangedProtectRadius (sandbox RangedProtectRadius) against
--      Juggernauts, Bosses, and ENRAGED Scavengers, resolved from state the
--      client already has (RQRegistry + RQReconcile) -- zero new wire traffic.
--
-- COMPOSITION MODEL (locked in design review, ready for RFTDLimes):
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
--     deliberately softens the old "restores when you leave the aura"
--     tooltip promise by three seconds.
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
end

-- ---------------------------------------------------------------------------
-- Effective multiplier
-- ---------------------------------------------------------------------------
local function computeEffective(player, weapon, now)
    local effective = 1.0
    for _, g in pairs(groups) do
        local mult = nil
        for _, predicate in pairs(g.sources) do
            local ok, m = pcall(predicate, player, weapon)
            if ok and m then
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
-- Built-in sources: the aura term
-- ---------------------------------------------------------------------------
-- Melee band: the flags each special's render tick publishes. PZ registers
-- OnRenderTick handlers in file load order and client files load
-- alphabetically, so RQBoss/RQJuggernaut/RQScavenger all publish before this
-- file's tick reads -- every flag is same-frame fresh. (The old
-- Juggernaut-reads-Scavenger path was a frame stale by the same mechanism.)
local function auraMult()
    return RQConfig.get().juggernautAuraMultiplier
end

RQSuppress.register("aura", "juggernaut", function()
    if RQJuggernaut and RQJuggernaut.playerInAura then return auraMult() end
end)

RQSuppress.register("aura", "boss", function()
    if RQBoss and RQBoss.playerInAura then return auraMult() end
end)

RQSuppress.register("aura", "scavenger", function()
    if RQScavenger and RQScavenger.playerInAura then return auraMult() end
end)

-- Ranged band: the kiting counter. Active while the player holds a firearm
-- within rangedProtectRadius of any Juggernaut or Boss, or any Scavenger the
-- server reports enraged (RQReconcile.scavClientState -- already synced for
-- the rage gradient, so the gate costs one table read).
--
-- Positions come from RQReconcile.lastKnownPos: ~2s stale against a 15-tile
-- band is fine, and it means no cell scans and no findZombieByID here --
-- pure arithmetic per registered special per frame. MP-only by construction:
-- in SP the reconcile channel never populates, so specials without a pos
-- entry are skipped, and an SP player has no server to exploit anyway.
--
-- Same multiplier as the melee band on purpose: this is the same debuff with
-- an honest reach for weapons that out-range a 3-tile ring, not a second
-- knob. It joins the same "aura" group, so standing inside the ring while
-- holding a gun does not double-apply.
RQSuppress.register("aura", "ranged", function(player, weapon)
    if not weapon then return end
    local okF, firearm = pcall(weapon.isAimedFirearm, weapon)
    if not okF or not firearm then return end

    local cfg    = RQConfig.get()
    local radius = cfg.rangedProtectRadius
    if radius <= 0 then return end

    local rSq = radius * radius
    local px  = player:getX()
    local py  = player:getY()

    for oid, zType in pairs(RQRegistry.activeZombies) do
        local protected = (zType == "Juggernaut") or (zType == "Boss")
        if not protected and zType == "Scavenger" then
            local st  = RQReconcile.scavClientState[oid]
            protected = (st and st.enraged) or false
        end
        if protected then
            local pos = RQReconcile.lastKnownPos[oid]
            if pos then
                local dx = px - pos.x
                local dy = py - pos.y
                if dx * dx + dy * dy <= rSq then
                    return auraMult()
                end
            end
        end
    end
end)

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
