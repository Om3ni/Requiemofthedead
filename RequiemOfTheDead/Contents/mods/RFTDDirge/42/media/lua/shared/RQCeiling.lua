-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQCeiling.lua - how healthy is this special SUPPOSED to be?
--
-- Two callers needed the same answer and were about to compute it twice:
-- RQMcCoy, which must not heal a zombie past the health its type entitles it
-- to, and RQHealthBar, which must not draw a bar that is permanently full.
-- Shared rather than duplicated, and shared/ rather than server/ because one of
-- those callers is a client render path.
--
-- THE RULE: store the BASE, derive the ceiling. `RQBaseHP` holds the zombie's
-- health before conversion; the ceiling is that times the type's multiplier,
-- times any growth the type has earned. Storing the ceiling instead would have
-- been one fewer multiplication and wrong the moment an operator retuned
-- JuggernautHealthMultiplier mid-season - every already-converted Juggernaut
-- would carry a number that no longer matched what conversion produces.
--
-- WHY THIS FILE EXISTS AT ALL. Four of the seven states a special can be in
-- could not reconstruct their ceiling after a chunk reload: an enraged
-- Scavenger, a Screamer, an EMP and a Boss. For those, current health IS the
-- only surviving evidence, and a damaged one reads as "already at its ceiling"
-- and never heals. The alternative to a persisted field was healing that
-- silently stops working after every reload, which is the kind of failure that
-- gets found by a player months later.
-- =============================================

RQCeiling = RQCeiling or {}

-- ---------------------------------------------------------------------------
-- reconstructBase - for specials converted before RQBaseHP existed
-- ---------------------------------------------------------------------------
-- Best evidence first. The two legacy keys are both POST-conversion values, so
-- dividing by the type multiplier recovers the base exactly. Falling all the
-- way through to current health is the same best-guess the reload backfill in
-- RQServer already documents as imperfect: it is right for an undamaged zombie
-- and low for a hurt one, which fails safe - a low ceiling under-heals rather
-- than inflating a special past what it should be.
function RQCeiling.reconstructBase(md, zType, mult)
    if not md or not mult or mult <= 0 then return nil, "no-multiplier" end

    local stamped = md["RQBaseHP"]
    if stamped and stamped > 0 then return stamped, "stamped" end

    local juggMax = md["RQJuggMaxHP"]
    if zType == "Juggernaut" and juggMax and juggMax > 0 then
        return juggMax / mult, "legacy-jugg"
    end

    local gluttonBase = md["RQGluttonBaseHealth"]
    if gluttonBase and gluttonBase > 0 then
        return gluttonBase / mult, "legacy-glutton"
    end

    return nil, "unreconstructable"
end

-- ---------------------------------------------------------------------------
-- resolve
-- ---------------------------------------------------------------------------
-- `opts` carries what only the caller can know:
--
--   ragePeak  - an enraged Scavenger's FROZEN rage ceiling. When present it
--               wins outright and no multiplier is applied. Rage decay owns
--               that number and walks it down on its own curve; deriving a
--               ceiling from the base here would let healing climb back above
--               the decay target and quietly defeat the ten-minute mechanic.
--   eatMult   - growth a feeding type has earned, as a multiplier (1.0 = has
--               eaten nothing). The two callers legitimately disagree about
--               this: McCoy passes what the zombie has ACTUALLY eaten, because
--               healing to a cap it never reached would hand it free health;
--               the health bar passes the theoretical cap, because a bar that
--               reads full until the last bite tells the player nothing.
--   currentHP - a floor. A zombie is never told its ceiling is below where it
--               already is; that would make McCoy's "heal only when below the
--               ceiling" test read as "never" for anything the old model had
--               already inflated.
--
-- Returns nil plus a named reason when no ceiling can be established, and the
-- caller is expected to do nothing rather than invent one.
function RQCeiling.resolve(md, zType, mult, opts)
    opts = opts or {}

    if opts.ragePeak and opts.ragePeak > 0 then
        return opts.ragePeak, "rage-peak"
    end

    local base, how = RQCeiling.reconstructBase(md, zType, mult)
    if not base then return nil, how end

    local ceiling = base * mult

    local eatMult = opts.eatMult
    if eatMult and eatMult > 1.0 then
        ceiling = ceiling * eatMult
    end

    if opts.currentHP and opts.currentHP > ceiling then
        ceiling = opts.currentHP
    end

    return ceiling, how
end

return RQCeiling

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
