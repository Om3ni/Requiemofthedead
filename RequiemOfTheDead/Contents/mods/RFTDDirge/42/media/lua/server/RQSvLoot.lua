-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvLoot - server-authoritative special-zombie corpse rewards.

RQSvLoot = RQSvLoot or {}

local LOOT_POOLS = {
    Screamer   = { "Base.Bandage", "Base.AlcoholBandage", "Base.Antibiotics", "Base.PillsVitamins", "Base.Bullets9mmBox", "Base.ShotgunShellsBox" },
    Juggernaut = { "Base.Axe", "Base.BaseballBat", "Base.Crowbar", "Base.HuntingKnife", "Base.Katana", "Base.Pistol", "Base.Shotgun", "Base.ShotgunShellsBox", "Base.Bullets9mmBox" },
    EMP        = { "Base.Battery", "Base.ElectronicsScrap", "Base.Screwdriver", "Base.HandTorch", "Base.WalkieTalkie1", "Base.Bandage", "Base.PillsVitamins" },
    Glutton    = { "Base.Bandage", "Base.AlcoholBandage", "Base.SutureNeedle", "Base.WaterBottle", "Base.TinnedBeans", "Base.CannedCorn" },
    Scavenger  = { "Base.WaterBottle", "Base.TinnedBeans", "Base.CannedCorn", "Base.CannedChili", "Base.Bandage" },
    Boss       = { "Base.Katana", "Base.Pistol", "Base.Shotgun", "Base.HuntingRifle", "Base.Bullets9mmBox", "Base.ShotgunShellsBox", "Base.223Box", "Base.Antibiotics", "Base.SutureNeedle", "Base.AlcoholBandage" },
}

local DROP_COUNTS = {
    Screamer   = { 1, 2 },
    Juggernaut = { 1, 3 },
    EMP        = { 1, 2 },
    Glutton    = { 1, 2 },
    Scavenger  = { 1, 2 },
    Boss       = { 3, 5 },
}

function RQSvLoot.drop(zombie, zType)
    if not zombie then return end
    local inv = zombie:getInventory()
    if not inv then return end

    local pool = LOOT_POOLS[zType]
    if not pool then return end

    local counts = DROP_COUNTS[zType] or { 1, 2 }
    local count = counts[1] + ZombRand(counts[2] - counts[1] + 1)
    local sm = getScriptManager()

    for i = 1, count do
        local itemType = pool[ZombRand(#pool) + 1]
        if sm and sm:getItem(itemType) then
            -- ItemContainer.AddItem(String) returns nil for missing/obsolete
            -- scripts after its own FindItem check, and vanilla Lua calls it
            -- directly for fixed Base.* item rewards. Evidence:
            -- ItemContainer.java:506-532; SpawnItems.lua:72-91, 151-155.
            inv:AddItem(itemType)
        end
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
