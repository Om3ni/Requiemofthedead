-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQLoot - special zombie loot drops
-- Adds items to the zombie's corpse inventory when it dies.
-- Player picks them up by searching the body like normal.
-- Using base game items for now, custom items need Blender
-- work that hasn't happened yet.

RQLoot = RQLoot or {}

-- Loot pools per zombie type (base game items)
local LOOT_POOLS = {
    Screamer = {
        "Base.Bandage",
        "Base.AlcoholBandage",
        "Base.Antibiotics",
        "Base.PillsVitamins",
        "Base.Bullets9mmBox",
        "Base.ShotgunShellsBox",
    },
    Juggernaut = {
        "Base.Axe",
        "Base.BaseballBat",
        "Base.Crowbar",
        "Base.HuntingKnife",
        "Base.Katana",
        "Base.Pistol",
        "Base.Shotgun",
        "Base.ShotgunShellsBox",
        "Base.Bullets9mmBox",
    },
    EMP = {
        "Base.Battery",
        "Base.ElectronicsScrap",
        "Base.Screwdriver",
        "Base.HandTorch",
        "Base.WalkieTalkie1",
        "Base.Bandage",
        "Base.PillsVitamins",
    },
    Glutton = {
        "Base.Bandage",
        "Base.AlcoholBandage",
        "Base.SutureNeedle",
        "Base.WaterBottle",
        "Base.TinnedBeans",
        "Base.CannedCorn",
    },
    Scavenger = {
        "Base.WaterBottle",
        "Base.TinnedBeans",
        "Base.CannedCorn",
        "Base.CannedChili",
        "Base.Bandage",
    },
    Boss = {
        "Base.Katana",
        "Base.Pistol",
        "Base.Shotgun",
        "Base.HuntingRifle",
        "Base.Bullets9mmBox",
        "Base.ShotgunShellsBox",
        "Base.223Box",
        "Base.Antibiotics",
        "Base.SutureNeedle",
        "Base.AlcoholBandage",
    },
}

-- Number of items to drop per type
local DROP_COUNTS = {
    Screamer   = { min = 1, max = 2 },
    Juggernaut = { min = 1, max = 3 },
    EMP        = { min = 1, max = 2 },
    Glutton    = { min = 1, max = 2 },
    Scavenger  = { min = 1, max = 2 },
    Boss       = { min = 3, max = 5 },
}

-- Pick a random item from a loot pool
local function pickFromPool(pool)
    if not pool or #pool == 0 then return nil end
    return pool[ZombRand(#pool) + 1]
end

-- Trigger loot drop on special zombie death - adds items to zombie's inventory
-- Player loots them by searching the corpse like any other zombie
function RQLoot.dropForZombie(zombie)
    if not zombie then return end

    local oid = zombie:getOnlineID()
    if not oid then return end
    local zType = RQRegistry.getType(oid)
    if not zType then return end

    local inv = zombie:getInventory()
    if not inv then return end

    local pool = LOOT_POOLS[zType]
    if not pool then return end

    local counts = DROP_COUNTS[zType] or { min = 1, max = 2 }
    local dropCount = counts.min + ZombRand(counts.max - counts.min + 1)

    local given = {}
    for i = 1, dropCount do
        local itemType = pickFromPool(pool)
        if itemType then
            local sm = getScriptManager()
            if sm and sm:getItem(itemType) then
                -- ItemContainer.AddItem(String) returns nil for missing/obsolete
                -- scripts after its own FindItem check, and vanilla Lua calls it
                -- directly for fixed Base.* item rewards. Evidence:
                -- ItemContainer.java:506-532; SpawnItems.lua:72-91, 151-155.
                local item = inv:AddItem(itemType)
                if item then
                    given[#given + 1] = itemType
                end
            end
        end
    end

    if #given > 0 then
        RQDirgeLog.write(zType, "[INFO] corpse loaded with " .. #given .. " items: " .. table.concat(given, ", "))
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
