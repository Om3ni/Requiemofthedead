-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMSuppress.lua - the per-zone weapon suppression term (§7.6).
--
-- Dirge's RQSuppress composes weapon-damage suppression from TERM GROUPS: the
-- deepest multiplier wins within a group, and groups MULTIPLY against each
-- other. Its header has been holding a slot for us since the design review -
-- the call shape is written there verbatim:
--
--     RQSuppress.register("zone", "limes", function(player, weapon)
--         return zoneMultOrNil
--     end)
--
-- so a zone term of 0.6 stacking with an aura term of 0.4 lands at 0.24 weapon
-- damage. That compounding is deliberate: an escorted special inside a hard
-- zone is meant to be a strategic decision rather than a DPS check.
--
-- CLIENT ONLY, because RQSuppress is - it writes two float fields on the
-- inventory item every render tick while suppressed and never touches the
-- network. The zone lookup it needs is a local table read (§6: every consumer
-- read is local), so this whole feature costs zero packets.
--
-- Removing this file removes the zone term and nothing else: the aura term,
-- the linger window and the write path are all Dirge's and untouched.

if isServer() then return end

require "LMCore"

LMSuppress = LMSuppress or {}

-- side = client: RQSuppress is the only consumer and it runs here, so the
-- server has no use for this value - but unlike the dirge vocabulary it must
-- reach clients, which is exactly the distinction the tag exists to make (§5).
Limes.fields.register("LMSuppress", "weaponDebuffMult",
    { type = "number", min = 0, max = 1, side = "client" })

-- nil, not 1.0, when there is nothing to say. RQSuppress treats a falsey
-- return as "this source is quiet", and a quiet source keeps the whole group
-- inactive - which matters because an active group holds its multiplier
-- through LINGER_MS after it goes silent. Returning 1.0 would keep the zone
-- term perpetually "active at no effect" and drag that linger machinery along
-- for every player on every tick, for nothing.
local function zoneMult(player)
    if not player then return nil end
    local ok, zone = pcall(function()
        return Limes.getLocation(player:getX(), player:getY())
    end)
    if not ok or not zone or not zone.fields then return nil end

    local mult = zone.fields.weaponDebuffMult
    -- Unset inherits (the blank-inherits contract), and a value of 1 is "no
    -- suppression here" stated explicitly - both mean: stay quiet.
    if mult == nil or mult >= 1 then return nil end
    return mult
end

function LMSuppress.install()
    if not RQSuppress or not RQSuppress.register then return false end
    RQSuppress.register("zone", "limes", function(player) return zoneMult(player) end)
    print("[Limes] LMSuppress: zone term registered into RQSuppress")
    return true
end

-- Deferred for the same reason LMDirge's bridge is: mod load order decides
-- whether Dirge's client files have been parsed when this one runs, and the
-- server's Mods= line is not ours to depend on. RQSuppress.register overwrites
-- by (group, source) key, so a double install replaces the predicate rather
-- than stacking a second one.
if not LMSuppress.install() and Events and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        if not LMSuppress.install() then
            print("[Limes] LMSuppress: Dirge not present, no zone suppression term")
        end
    end)
end

return LMSuppress

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
