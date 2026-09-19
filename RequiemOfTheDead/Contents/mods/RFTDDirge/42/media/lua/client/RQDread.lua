-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQDread - the dread a special projects: weapons falter near it.
--
-- Dirge's one term in RQSuppress. Inside a band around a Juggernaut, a Boss or
-- an enraged Scavenger, the player's weapon keeps only a configured share of
-- its damage; firearms are covered to twice the melee radius, so a special
-- cannot simply be shot from outside the ring. RQSuppress owns everything
-- about the weapon - the snapshot, the write, the linger, the restore - and
-- this file only answers its question: how much, right now, for this player.
--
-- =============================================
-- WHY THE WEAPON, AND WHY THE CLIENT
-- =============================================
-- The attacking client computes the damage and owns the zombie's health; the
-- server takes its number verbatim (IsoGameCharacter.java:5723, and RQSvHit's
-- header). Exactly two levers land where that number is computed: clothing
-- armour on the livery items, applied during attack resolution, and this,
-- which scales the weapon in that client's own hands. Neither is argued with.
-- The server-side soak that used to answer this question was retired on
-- 2026-09-17 because it protected only the server's copy.
--
-- WHAT IT COSTS. It changes the WEAPON, not the target: while suppressed,
-- every swing is weaker, including swings at ordinary zombies standing next to
-- the special. That is inherent to the pattern and is the price of landing
-- where the number is real. It is client-trusted by construction - so is the
-- damage number itself, and every other combat value the client computes.
--
-- THE FAIL-SAFE. When the sandbox cannot be read, suppress NOTHING. Nerfing a
-- player's weapon because the server's config could not be read is worse than
-- leaving it alone; fail toward the player, never toward the mod. RQConfig
-- carries the two values as nil when its source is unreadable for exactly
-- this reason, and 100 percent or a zero radius reads as off.

require "RQConfig"
require "RQRegistry"
require "RQReconcile"
require "RQSuppress"

RQDread = RQDread or {}

-- Which types project. The Scavenger only while enraged: passive, it is
-- eating and it is not a threat, and a band around every sleeper would give
-- the game away.
local PROJECTS = { Juggernaut = true, Boss = true, Scavenger = "enraged" }

RQDread.stats = { meleeBand = 0, rangedBand = 0 }

local function projects(oid, zType)
    local rule = PROJECTS[zType]
    if rule == nil then return false end
    if rule == true then return true end
    local st = RQReconcile.scavClientState[oid]
    return st ~= nil and st.enraged == true
end

-- The multiplier for this player and weapon, or nil when nothing nearby
-- projects. Pure apart from the registry walk, and `resolve` is injected so a
-- fixture needs no zombie cache. Floors are not transparent to a band: a
-- special one storey down must not weaken a swing up here.
function RQDread.multiplier(player, weapon, cfg, resolve)
    local percent, radius = cfg.suppressPercent, cfg.suppressRadius
    if percent == nil or radius == nil then return nil end
    if percent >= 100 or radius <= 0 then return nil end
    if percent < 0 then percent = 0 end

    -- isAimedFirearm exists only on the HandWeapon subtypes the engine treats
    -- as guns, so the presence test is the guard.
    local isRanged = weapon ~= nil and weapon.isAimedFirearm ~= nil and weapon:isAimedFirearm()
    local band = isRanged and radius * 2 or radius
    local bandSq = band * band

    local px, py = player:getX(), player:getY()
    local pz = math.floor(player:getZ())
    for oid, zType in pairs(RQRegistry.activeZombies) do
        if projects(oid, zType) then
            local zombie = resolve(oid)
            if zombie and math.floor(zombie:getZ()) == pz then
                local dx, dy = px - zombie:getX(), py - zombie:getY()
                if dx * dx + dy * dy <= bandSq then
                    if isRanged then
                        RQDread.stats.rangedBand = RQDread.stats.rangedBand + 1
                    else
                        RQDread.stats.meleeBand = RQDread.stats.meleeBand + 1
                    end
                    return percent / 100
                end
            end
        end
    end
    return nil
end

-- The term. RQSuppress evaluates it every render tick while a player exists
-- and composes it with any other group (Limes' zone term multiplies in).
RQSuppress.register("dread", "dirge", function(player, weapon)
    return RQDread.multiplier(player, weapon, RQConfig.get(), RQCore.findZombieByID)
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
