-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RDZombieId.lua - what a zombie's network id is, and when it is real.
--
-- ONE RULE, WRITTEN ONCE, BECAUSE WE GOT IT WRONG THREE TIMES.
--
-- `IsoZombie.onlineId` is a **short** - `public short onlineId = (short)-1;`
-- (IsoZombie.java:325) - handed out by `ServerMap.getUniqueZombieId()`
-- (IsoZombie.java:2781). A short runs out at 32767 and WRAPS INTO NEGATIVE
-- NUMBERS. A zombie with id -10307 is not broken; it is the ten-thousandth
-- zombie after the wrap, and it is as ordinary as id 5.
--
-- The engine agrees. Every validity test in the decompile is `== -1`:
--   IsoZombie.java:2780        if (GameServer.server && this.onlineId == -1)
--   FakeClientManager.java:1397 if (z == null || z.onlineId == -1) continue;
--   VoiceManager.java:781      if (me.onlineId == -1)
--   NetworkZombiePacker.java:176 if (z.onlineId == -1) continue;
-- and the two places the engine clears an id write exactly -1
-- (IsoZombie.java:3569, :3663). Nothing anywhere treats "negative" as
-- "invalid".
--
-- WHAT THE WRONG TEST COSTS. `id > 0` looks equivalent and is not: on any
-- server that has been up long enough to wrap, it silently discards roughly
-- half the zombie population. Three of our own sites did this - RQPoise's
-- stagger immunity, and RQSvShared's health and movement delivery - so a
-- Bulwark past the wrap got no immunity, no boosted HP and no sprint profile.
-- Every symptom of that reads as "specials are flaky", never as an id bug,
-- which is why it survived so long. Found 2026-08-25 from live reflect data
-- full of ids like -10307 and -10653.
--
-- Sixteen files across six mods call getOnlineID. If you are about to write a
-- comparison against zero, use this instead.
-- =============================================

RDZombieId = RDZombieId or {}

-- The engine's sentinel for "this zombie has no network identity yet", and the
-- ONLY invalid value. Client-side an id arrives with the packet
-- (NetworkZombieSimulator.java:187); server-side it is assigned on first need.
RDZombieId.NONE = -1

-- Is this a real network id? Note what is deliberately NOT here: no positivity
-- test, and no upper bound.
function RDZombieId.isValid(id)
    return id ~= nil and id ~= RDZombieId.NONE
end

-- The id of a zombie, or nil when it does not have one yet.
--
-- Returning nil rather than -1 is the point: it makes the common call site
-- `local oid = RDZombieId.of(zombie); if not oid then return end`, which is
-- correct by construction, where `if oid > 0` is the bug this file exists to
-- stop. A stale Java reference also reports -1 forever while still answering
-- isDead() = false (seen at RQServer.lua:1159), so this doubles as the
-- liveness check those call sites actually wanted.
function RDZombieId.of(zombie)
    if not zombie then return nil end
    local id = zombie:getOnlineID()
    if not RDZombieId.isValid(id) then return nil end
    return id
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
