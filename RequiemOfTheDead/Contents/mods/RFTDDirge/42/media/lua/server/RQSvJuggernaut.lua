-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvJuggernaut.lua
-- Juggernaut conversion and type state. NO alive behaviour tick - see the note
-- below, which this header used to contradict outright: it claimed "handles the
-- alive behavior tick" and "jugg has one job here: apply a HP buff to nearby
-- non-special zombies", twenty lines above the paragraph explaining that both
-- of those jobs left in the 2026-08-24 slice. The buff aura became a hit-time
-- lookup in RQBulwark; the self-regen became RQMcCoy, which does it for every
-- special type.
if not isServer() then return end

RQSvJuggernaut = RQSvJuggernaut or {}

-- The `buffed` weak table is GONE (2026-08-24). It latched every zombie this
-- aura had ever touched so the one-time HP grant could not stack - and that
-- latch was the whole problem. The grant outlived its source, so killing the
-- Juggernaut left its escort permanently tough; walking out of the radius did
-- nothing; and it cost one owner-directed HP command per zombie per sweep.
-- RQBulwark now answers the same question when a hit actually lands.

-- NO ALIVE BEHAVIOUR TICK, deliberately. Both of this type's jobs left in the
-- same slice: the buff aura became a hit-time lookup in RQBulwark, and the
-- self-regen became RQMcCoy. RQServer no longer dispatches Juggernauts on the
-- behaviour pass at all, the same way it has never dispatched EMP zombies.
--
-- An empty tick() was the first version of this, and check-helpers was right to
-- reject it: an empty body is not an implementation, and leaving one here would
-- have cost a call per Juggernaut per pass to do nothing. When Juggernauts grow
-- new alive behaviour, the dispatch comes back with it.

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
