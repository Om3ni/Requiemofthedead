-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQTailor - keeps this client's copy of a special looking like its livery.
--
-- Two jobs, one responsibility: what a Dirge special looks like on THIS
-- machine. The server owns the persistent outfit id (RQSvLivery); this file
-- owns the local model that has to catch up with it.
--
--   1. REDRESS. A zombie this client already had when the server dressed it
--      never sees the new id - the existing-zombie packet path applies
--      movement and state only (NetworkZombieSimulator.java:258-269). The
--      server sends one targeted zombieLivery command instead, and redress
--      applies the named outfit to the local copy.
--
--   2. STRIP. Every zombie dressed from a persistent id gets random vanilla
--      wounds and bandages rolled onto it by the engine's outfitter
--      (PersistentOutfits.java:277-280 -> IsoZombie.addRandomBloodDirtHolesEtc
--      :3743-3749 -> addRandomVisualDamages :4216-4222 and
--      addRandomVisualBandages :4198-4207). They are texture overlays added
--      as BODY VISUALS (HumanVisual.java:681-713). The bipeds mask all
--      sixteen body parts, but the body-visual pass composites over a mask
--      reset to all-visible (ModelInstanceTextureCreator.java:235), so the
--      vanilla body still draws, transparent everywhere except the wound
--      pixels - a white halo above the head, a patch on a shin, wherever
--      the vanilla body pokes through the mesh. The rolls are made
--      independently by every side that dresses the zombie, so nothing the
--      server does reaches a client's copy; each client strips its own.
--
-- =============================================
-- WHY REDRESS VERIFIES INSTEAD OF ASSUMING
-- =============================================
-- dressInNamedOutfit CLEARS wornItems, the human visual and itemVisuals
-- BEFORE it looks the outfit up (IsoZombie.java:3878-3880). Both of its
-- failure paths therefore leave the zombie naked:
--   * outfit not found     -> returns at :3882-3884, already cleared.
--   * outfit not yet loaded -> loadItems, parks the name in
--                              pendingOutfitName, returns at :3885-3888. The
--                              engine retries from clothingItemChanged
--                              (:3932-3943) and the zombie is naked until
--                              it does. This is the likely one on a client
--                              seeing a livery for the first time.
-- The outfit name is set only on the success path (HumanVisual.java:638-640
-- via setOutfit :849; read back by IsoZombie.getOutfitName :4844-4852), so
-- that is what is checked. On a miss the server's persistent id - captured
-- before the call, because the call destroys it - is re-applied, and the
-- pending name is deliberately left alone so the engine's own retry still
-- lands. Old look now, new look shortly; never naked.
--
-- =============================================
-- WHY STRIP RUNS PER FRAME
-- =============================================
-- There is no event between "model added and dressed" and "first frame":
-- OnZombieCreate fires before either. So this is an OnZombieUpdate lane,
-- like RQGlutton's, and it earns that by cost: one getOutfitName and one
-- prefix test per zombie per update, plus one getBodyVisuals and one size()
-- per LIVERIED zombie. The counters below are the readback.
--
-- THE CLEAR STICKS. The client re-dresses from the persistent id only while
-- persistentOutfitInit is false (ModelManager.java:509-511, :522-524), and
-- dressInPersistentOutfitID sets it true (IsoZombie.java:3902). A model
-- reset (IsoGameCharacter.java:1580-1582) rebuilds the texture without
-- rolling the wounds again. A re-dress DOES roll them again, and the size()
-- test catches that within a frame.

if not isClient() then return end

require "RQLivery"

RQTailor = RQTailor or {}

RQTailor.stats = { redressed = 0, restored = 0, seen = 0, cleared = 0, stripped = {} }

-- Apply a named livery to the local copy. Returns true when the outfit is
-- now the zombie's, false when it did not apply and the server's persistent
-- outfit was restored instead.
function RQTailor.redress(zombie, outfitName)
    local oid = zombie:getOnlineID()
    -- Captured BEFORE the call, because the call is what destroys it.
    local fallbackID = zombie:getPersistentOutfitID()

    zombie:dressInNamedOutfit(outfitName)                -- IsoZombie.java:3876-3894

    if zombie:getOutfitName() ~= outfitName then
        if fallbackID ~= 0 then
            zombie:dressInPersistentOutfitID(fallbackID)   -- IsoZombie.java:3898-3908
        end
        zombie:resetModelNextFrame()
        RQTailor.stats.restored = RQTailor.stats.restored + 1
        print("[RFTDDirge] livery " .. tostring(outfitName) .. " did not apply to id="
            .. tostring(oid) .. "; restored outfit id " .. tostring(fallbackID))
        return false
    end

    zombie:resetModelNextFrame()                         -- IsoGameCharacter.java:1580-1582
    RQTailor.stats.redressed = RQTailor.stats.redressed + 1
    return true
end

-- Strip the engine's wound and bandage overlays from one zombie if it wears
-- a livery and has any. Returns the number removed.
function RQTailor.strip(zombie)
    local name = zombie:getOutfitName()                  -- IsoZombie.java:4844
    if not RQLivery.wears(name) then return 0 end
    local s = RQTailor.stats
    s.seen = s.seen + 1
    local visuals = zombie:getHumanVisual():getBodyVisuals()   -- HumanVisual.java:673
    local n = visuals:size()
    if n == 0 then return 0 end
    for i = 0, n - 1 do
        local itemType = visuals:get(i):getItemType()
        s.stripped[itemType] = (s.stripped[itemType] or 0) + 1
    end
    visuals:clear()
    zombie:resetModelNextFrame()                         -- IsoGameCharacter.java:1580-1582
    s.cleared = s.cleared + 1
    return n
end

local function onZombieUpdate(zombie)
    RQTailor.strip(zombie)
end

Events.OnZombieUpdate.Add(onZombieUpdate)

-- Console readback: how often the lane ran, how often it acted, and which
-- vanilla overlays it has been removing.
function RQTailor.summary()
    local s = RQTailor.stats
    print(string.format("[RFTDDirge] tailor: redressed=%d restored=%d seen=%d cleared=%d",
        s.redressed, s.restored, s.seen, s.cleared))
    local keys = {}
    for k in pairs(s.stripped) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        print(string.format("[RFTDDirge]   %-40s %d", k, s.stripped[k]))
    end
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
