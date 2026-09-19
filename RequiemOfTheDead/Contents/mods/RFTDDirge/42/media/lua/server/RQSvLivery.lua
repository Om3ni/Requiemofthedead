-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQSvLivery - the server dresses a special in its livery, and tells the
-- clients that already have it.
--
-- =============================================
-- WHY THE SERVER'S OUTFIT ID IS THE AUTHORITY
-- =============================================
-- A zombie's appearance on the wire is one integer, the persistent outfit
-- id. A client that first receives the zombie after it was dressed creates
-- it from that id (NetworkZombieSimulator.java:182), and the owner's sync
-- never writes the id back - the existing-zombie path applies movement and
-- state only (NetworkZombieSimulator.java:258-269). So the server's write
-- is not argued with, and late joiners and chunk reloads are correct for
-- free. Virtualization keeps the complete id (RQSvDormant's header), which
-- is also why the dormant identity record must be minted AFTER the dress:
-- RQServer.svTryConvert calls svDressForType before svMarkZombie.
--
-- What the id does NOT do is re-dress a client that already has the
-- zombie. That is the one-shot targeted command below: sent only to players
-- within RQSvShared.RELEVANCE_WINDOW of the zombie, each of whom re-dresses
-- their own copy (RQTailor). Not a broadcast, not a periodic stream.
--
-- =============================================
-- WHY A DRESS IS VERIFIED AND NEVER ASSUMED
-- =============================================
-- dressInPersistentOutfit resolves the name to an id (IsoGameCharacter.java:
-- 1735-1740 -> PersistentOutfits.pickOutfit :162-169) and an unknown name
-- resolves to 0 (:145, :155). dressInPersistentOutfitID CLEARS the visuals
-- before it tests the id (IsoZombie.java:3898-3905), so a failed resolve
-- leaves the zombie naked - and that naked id then goes out on the wire to
-- every client that creates the zombie later. The previous id is captured
-- before the call and restored on a miss, and the miss is printed
-- unconditionally: a livery that does not resolve is a packaging fault, not
-- a diagnostic.

if not isServer() then return end

require "RQCommon"
require "RQLivery"
require "RQSvShared"
require "RQDirgeLog"

RQSvLivery = RQSvLivery or {}

-- Server -> client, targeted. The client half is RQCore's zombieLivery
-- branch, which hands the outfit name to RQTailor.redress.
RQSvLivery.COMMAND = "zombieLivery"

RQSvLivery.stats = { dressed = 0, unresolved = 0, repaints = 0 }

-- Tell every player within relevance to re-dress their copy. Returns how
-- many were told, for the log line. A dress happens once per conversion and
-- once per Scavenger rage; the window and the loop are RQSvShared.sendNear's.
local function repaint(zombie, oid, outfitName)
    local sent = RQSvShared.sendNear(zombie, RQSvLivery.COMMAND, {
        onlineID = oid,
        outfit   = outfitName,
    })
    RQSvLivery.stats.repaints = RQSvLivery.stats.repaints + sent
    return sent
end

-- Dress one zombie in one named outfit. Returns true when the outfit
-- resolved and is now the zombie's persistent outfit.
local function dress(zombie, zType, outfitName)
    local oid = zombie:getOnlineID()
    local previous = zombie:getPersistentOutfitID()
    zombie:dressInPersistentOutfit(outfitName)        -- IsoGameCharacter.java:1735-1740
    if zombie:getPersistentOutfitID() == 0 then
        -- Restore the id it already had; that id resolved once, so it
        -- resolves again. Loud on purpose (see header).
        if previous ~= 0 then
            zombie:dressInPersistentOutfitID(previous)    -- IsoZombie.java:3898-3908
        end
        RQSvLivery.stats.unresolved = RQSvLivery.stats.unresolved + 1
        print("[RFTDDirge] livery " .. outfitName .. " did not resolve for "
            .. tostring(zType) .. " id=" .. tostring(oid)
            .. "; restored outfit id " .. tostring(previous))
        return false
    end
    RQSvLivery.stats.dressed = RQSvLivery.stats.dressed + 1
    local told = repaint(zombie, oid, outfitName)
    RQDirgeLog.write(zType, "[INFO] livery " .. outfitName .. " id=" .. tostring(oid)
        .. " outfitID=" .. tostring(zombie:getPersistentOutfitID())
        .. " repaint recipients=" .. told)
    return true
end

-- Conversion-time dress. Called by RQServer.svTryConvert BEFORE svMarkZombie
-- so the dormant identity record sees the final outfit id. A type with no
-- livery is left exactly as it was and answers false.
--
-- The Boss draws one of its four bodies here, once, at conversion. The roll
-- is server-side and the result travels as the persistent outfit id like any
-- other livery, so every client and every reload agrees on which body it is.
function RQSvLivery.svDressForType(zombie, zType)
    local roll = (zType == "Boss") and ZombRand(#RQLivery.BOSS_OUTFITS) or nil
    local outfitName = RQLivery.outfitFor(zType, roll)
    if not outfitName then return false end
    return dress(zombie, zType, outfitName)
end

-- The Scavenger's rage flip: emerald core to crimson. Called once by
-- RQSvScavenger.onPlayerHit, which owns the debounce - rage is a one-way
-- flip there, so this is never asked twice for the same zombie. Not gated on
-- what it wore before: an enraged Scavenger is crimson, full stop, including
-- one converted before liveries existed.
function RQSvLivery.svEnrage(zombie)
    return dress(zombie, "Scavenger", RQLivery.ENRAGED_SCAVENGER)
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
