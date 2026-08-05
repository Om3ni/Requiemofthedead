-- SPDX-License-Identifier: GPL-3.0-or-later
-- RLShared.lua - Reliquary: shared constants + pure helpers (no side effects).
--
-- A Reliquary is an admin-placed, whitelist-gated container that holds
-- whatever staff puts into it and DISSOLVES once it has been emptied. It is a
-- vessel for a single handover - a restored death loadout, an event prize, a
-- quartermaster drop for one named player - that leaves nothing behind to be
-- farmed, re-looted, or forgotten in a field.
--
-- It was called BoonBox before the migration into the bundle. "Box" put it one
-- consonant from Ban Box in every sentence anyone spoke, so the name went and
-- the concept stayed. NOTE for anyone with a test box in a local save: the
-- modData key moved with the name (RFTDBoonBox -> RFTDReliquary), so old boxes
-- become ordinary lockers. Nothing ever shipped under the old name, so nothing
-- in a live world is owed a migration.
--
-- This file is the single source of truth for the modData schema, the sprite,
-- and the pure helpers (list parsing + authorization) that BOTH sides need.
-- One file = one purpose; server/client own behaviour, this owns shared facts.
--
-- The wire token is NOT here - it is OEShared.MODULE, the one token the whole
-- mod speaks on, dispatched by RDNet.

Reliquary = Reliquary or {}
local RL = Reliquary

-- Nothing below is indexed at file scope, but both globals are indexed on
-- every gated path; require() pulls them forward on the client, where the
-- alphabetical walk across all mods would otherwise reach "RLShared.lua"
-- before "RDAccess.lua".
require "RDAccess"
require "OEShared"

-- Vanilla metal-locker sprite (small metal locker, W face). A real B42
-- tilesheet entry, so it renders and re-loads from a save with no custom art.
-- Swap freely to another face/locker:
--   W=furniture_storage_02_8  N=_9  E=_10  S=_11   (big locker = _12..)
RL.SPRITE = "furniture_storage_02_8"

-- modData table key stamped onto the placed IsoObject. Presence of this table
-- == "this is a Reliquary".
RL.MODKEY = "RFTDReliquary"

-- "Unlimited" capacity. The engine wants a number; this is bottomless as far
-- as any handover is concerned.
RL.CAPACITY = 1000000

-- Audit log filename, written to Zomboid/Lua/ via getFileWriter. Server owns
-- it; appended forever (never truncated), and the volume is tiny.
--
-- The .txt is load-bearing, not cosmetic: 42.20 added an extension allowlist
-- to LuaManager.getFileWriter (ini/cfg/txt/log only) and everything outside it
-- returns nil - SILENTLY, since the `if w then` guard in RLServer means pcall
-- never errors and the caller is told it wrote. Do not rename this to .jsonl.
RL.LOGFILE = "RFTDReliquary_Audit.txt"

-- Internal ItemContainer type. "crate" gives sensible open/close/transfer
-- sounds.
RL.CONTAINER_TYPE = "crate"

-- Hard cap on items added in a single fill. Defence in depth: the command is
-- capability-gated and RDNet re-checks that gate server-side, but a spoofed
-- client could still ask for an enormous qty and lag the server spawning
-- items. 10k is far above any legitimate handover.
RL.MAX_PER_FILL = 10000

-- The item staff spawn and place. Placing it is what creates the world
-- container; the item is consumed in the act.
RL.ITEM = "RFTDOddsAndEnds.Reliquary"

-- Master kill switch, per the Odds & Ends enable model.
function RL.isEnabled()
    return OEShared.enabled("ReliquaryEnable")
end

-- Hours a freshly placed Reliquary waits before it gives up and takes its
-- contents with it. 0 means it waits forever.
function RL.defaultHours()
    local sv = SandboxVars and SandboxVars.RFTDOddsAndEnds
    local v = sv and tonumber(sv.ReliquaryDefaultHours)
    if v == nil then return 72 end
    return v
end

-- ---------------------------------------------------------------------------
-- Authorization (pure)
--
-- Two different questions, deliberately answered by two different gates:
--   mayManage    - place, fill, re-address. The AddItem capability, the same
--                  one Dragonfly's item-spawn handlers use, because filling a
--                  Reliquary IS spawning items.
--   isAuthorized - open and loot it. Any staff capability at all, or being the
--                  one player it was addressed to.
-- A staffer without AddItem can therefore see and hand over a Reliquary that
-- someone else stocked, but cannot conjure its contents.
-- ---------------------------------------------------------------------------

-- In pure single player there is no role and no server to re-validate, and the
-- player already has the debug menu; gating them out of their own test box
-- protects nothing.
local function soloPlayer()
    return not isClient() and not isServer()
end

-- Deliberately NO access-level escape here. This must mirror RDNet's server
-- gate exactly - RDAccess.can(player, "AddItem"), nothing more - or an admin
-- whose role has been edited to drop AddItem gets offered a menu whose every
-- option the server then refuses. Vanilla's Admin role holds every capability,
-- so the two agree by default; the role editor is where that changes, and it
-- should change both sides at once.
function RL.mayManage(player)
    if not player then return false end
    return RDAccess.can(player, "AddItem") or soloPlayer()
end

-- Read the Reliquary modData table off an IsoObject, or nil if it isn't one.
function RL.getData(obj)
    if not obj or not obj.getModData then return nil end
    local md = obj:getModData()
    return md and md[RL.MODKEY] or nil
end

-- Can this player OPEN/loot it? `data` is the table from RL.getData(); an
-- empty whitelist means staff-only.
function RL.isAuthorized(player, data)
    if not player then return false end
    if RDAccess.can(player, "any") or RDAccess.isTopAdmin(player) or soloPlayer() then return true end
    if not data then return false end
    local wl = data.whitelist
    if not wl or wl == "" then return false end
    local name = player.getUsername and player:getUsername() or nil
    return name ~= nil and name == wl
end

-- ---------------------------------------------------------------------------
-- List parsing (pure)
-- ---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse an admin's "qty;fulltype" CSV into {entries = {{qty=, type=}, ...},
-- errors = {..}}. Accepts: "5;Base.ScrapSword, 10;Base.Nails". Lenient
-- niceties:
--   * whitespace around tokens/separators is trimmed
--   * a bare type with no "." gets a "Base." prefix ("Nails" -> "Base.Nails")
--   * "qty;type" or "type;qty" both work (whichever side is the number is qty)
-- Type validity is NOT checked here (no ScriptManager on the pure layer); the
-- server validates against the real item table and reports unknown types back.
-- errors[] holds malformed tokens only.
function RL.parseList(str)
    local out = { entries = {}, errors = {} }
    if not str or trim(str) == "" then return out end

    -- Spec is comma-separated, but a multiline entry box invites newlines;
    -- treat both as separators.
    str = str:gsub("[\r\n]+", ",")

    for token in (str .. ","):gmatch("([^,]*),") do
        local t = trim(token)
        if t ~= "" then
            local a, b = t:match("^(.-)%s*;%s*(.-)$")
            if not a then
                table.insert(out.errors, t)
            else
                a, b = trim(a), trim(b)
                local qty, typ
                if tonumber(a) then
                    qty, typ = tonumber(a), b
                elseif tonumber(b) then
                    qty, typ = tonumber(b), a
                end
                if not qty or qty < 1 or typ == "" then
                    table.insert(out.errors, t)
                else
                    if not typ:find("%.") then typ = "Base." .. typ end
                    table.insert(out.entries, { qty = math.floor(qty), type = typ })
                end
            end
        end
    end
    return out
end

-- Stable string id for a Reliquary from its world coords: the server registry
-- key, and the identifier every audit line carries.
function RL.keyFor(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

return RL

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
