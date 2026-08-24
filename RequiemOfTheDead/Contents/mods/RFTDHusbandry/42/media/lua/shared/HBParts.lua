-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBParts - the animal-part placement watchlist, shared contract.
--
-- Which items count as animal materiel when they enter the world: butchered
-- heads and skulls, and the animal corpse item. The client drop reporter and
-- the server re-check both consult THIS table, so the two sides cannot drift.
--
-- The list is DERIVED, not authored. AnimalPartsDefinitions.animals is the
-- registry butchering itself reads (ButcheringUtil.getHead/getSkull walk it),
-- so each def's head and skull IS the exact fullType a butchering session can
-- hand a player - every vanilla breed, and any modded animal that registers
-- there, with no patterns and therefore no Bandage_Head / ClawhammerHead
-- exclusion list to maintain. A rename in the defs updates us for free.
--
-- Meat, bones, feathers and leather are deliberately NOT watched: they are
-- ordinary drops players make constantly, and the point of this stream is a
-- trickle a human can read, not a second guardian.

-- LOAD ORDER (same landmine HBCommands documents): the client walks
-- media/lua/shared alphabetically ACROSS ALL MODS, so this file runs before
-- Core's RDEvents.lua. require() pulls it forward; no-op if already run.
require "RDEvents"
require "Definitions/animal/AnimalPartsDefinitions"

HBParts = HBParts or {}

HBParts.MODULE = "RFTDHusbandry"
HBParts.STREAM = "parts"
HBParts.EVENT  = "HB.PART_PLACED"

RDEvents.registerNamespace("HB", HBParts.MODULE, {
    -- One event, discriminated by `path`: corpse_drop / place_item /
    -- hook_hang / hook_remove are server-observed (HBPartWatch), item_drop is
    -- client-asserted (HBPartDropClient -> HBPartWatch.onClientReport).
    PART_PLACED = {
        scope = "p",
        req   = { "path", "x", "y", "z" },
        loc   = { "x", "y", "z" },
    },
})

-- Built on first use, not at load: shared files load alphabetically across
-- mods on the client, so a modded animal registered by a file loading after
-- this one would be missed by a load-time walk. First use is always an
-- in-play event, long after every def is in. Built once and kept - the defs
-- table is load-time data, nothing mutates it in play.
local watched

local function buildWatchlist()
    local set = {}
    -- The one corpse item: every animal corpse in an inventory is this single
    -- type, with the animal itself in modData (ISGrabCorpseItem.lua:71,
    -- modData read at ButcheringUtil.lua:560-570).
    set["Base.CorpseAnimal"] = true
    local defs = AnimalPartsDefinitions and AnimalPartsDefinitions.animals
    for _, def in pairs(defs or {}) do
        if type(def.head)  == "string" then set[def.head]  = true end
        if type(def.skull) == "string" then set[def.skull] = true end
    end
    return set
end

function HBParts.isWatched(fullType)
    if type(fullType) ~= "string" or fullType == "" then return false end
    watched = watched or buildWatchlist()
    return watched[fullType] == true
end

return HBParts

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
