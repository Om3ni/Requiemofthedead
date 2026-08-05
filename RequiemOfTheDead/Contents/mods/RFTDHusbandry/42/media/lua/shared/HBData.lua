-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBData - ModData schema, persistent ID generation, herd registry, seen list.
-- Read operations (getRecord, constants) are safe from both sides.
-- Write operations are server-only and guarded accordingly.

HBData = {}

-- ModData namespace keys - centralised here; never hardcode these elsewhere.
HBData.NS_ANIMAL = "RQHB"        -- per-animal pedigree/genetics record
HBData.NS_HERD   = "RQHB_herd"   -- per-player herd membership list
HBData.NS_SRV    = "RQHB_srv"    -- server globals (ID counter)
HBData.NS_HUTCH  = "RQHB_hutch"  -- per-hutch state (bedding) - keyed on the
                                 -- IsoHutch's own ModData, persists in saves

-- In-memory state (session-scoped; rebuilt on connect and encounter).
-- Server side only - not meaningful on the client.
HBData.seen  = {}  -- [onlineID:number] = true - all encountered animals this session
HBData.herds = {}  -- [username:string] = { rqhbId:string, ... }
HBData.idMap = {}  -- [rqhbId:string]   = onlineID:number

-- -------------------------------------------------------------------------
-- Read helpers (both sides)
-- -------------------------------------------------------------------------

-- Returns the RQHB record table from an animal's ModData, or nil if absent.
function HBData.getRecord(animal)
    return animal:getModData()[HBData.NS_ANIMAL]
end

-- -------------------------------------------------------------------------
-- Server-side logic
-- -------------------------------------------------------------------------

if not isServer() then return end

-- Increment and return the next persistent RQHB_id.
-- Counter lives in GameTime ModData so it survives server restarts.
local function nextId()
    local md = getGameTime():getModData()
    if not md[HBData.NS_SRV] then md[HBData.NS_SRV] = { n = 0 } end
    md[HBData.NS_SRV].n = md[HBData.NS_SRV].n + 1
    return "RQHB_" .. md[HBData.NS_SRV].n
end

-- Get (or create) the RQHB record on an animal, minting a persistent ID if needed.
-- Does not register the animal to any herd.
function HBData.ensureRecord(animal)
    local md = animal:getModData()
    if not md[HBData.NS_ANIMAL] then
        md[HBData.NS_ANIMAL] = { id = nextId() }
    end
    return md[HBData.NS_ANIMAL]
end

-- Get (or create) the herd record on a player's ModData.
local function ensureHerdMD(player)
    local md = player:getModData()
    if not md[HBData.NS_HERD] then md[HBData.NS_HERD] = { animals = {} } end
    return md[HBData.NS_HERD]
end

-- Mark a live animal as seen: adds its onlineID to the seen set and, if it
-- has an RQHB record, wires up idMap. Safe to call repeatedly.
function HBData.addSeen(animal)
    local ok, oid = pcall(function() return animal:getOnlineID() end)
    if not ok or not oid or oid == 0 then return end
    HBData.seen[oid] = true
    local rec = HBData.getRecord(animal)
    if rec and rec.id then HBData.idMap[rec.id] = oid end
end

-- Register a live animal to a player's herd.
-- Mints an RQHB_id if the animal has never been seen by the mod.
-- Idempotent: safe to call if already registered.
-- Returns the RQHB record.
function HBData.register(animal, player)
    local rec = HBData.ensureRecord(animal)
    local username = player:getUsername()

    HBData.addSeen(animal)

    local herdMD = ensureHerdMD(player)
    for _, id in ipairs(herdMD.animals) do
        if id == rec.id then return rec end  -- already registered
    end
    table.insert(herdMD.animals, rec.id)

    if not HBData.herds[username] then HBData.herds[username] = {} end
    table.insert(HBData.herds[username], rec.id)

    animal:transmitModData()
    player:transmitModData()
    return rec
end

-- Remove an animal from a player's herd.
-- Preserves the RQHB record on the animal (pedigree data is never deleted).
function HBData.unregister(animal, player)
    local rec = HBData.getRecord(animal)
    if not rec then return end
    local username = player:getUsername()

    local herdMD = ensureHerdMD(player)
    for i, id in ipairs(herdMD.animals) do
        if id == rec.id then table.remove(herdMD.animals, i); break end
    end

    if HBData.herds[username] then
        for i, id in ipairs(HBData.herds[username]) do
            if id == rec.id then table.remove(HBData.herds[username], i); break end
        end
    end

    player:transmitModData()
end

-- Load a player's persisted herd list into HBData.herds on connect.
-- The seen list is populated per-session by server-side encounter logic.
local function onClientConnect(player)
    local username = player:getUsername()
    local herdMD = ensureHerdMD(player)

    HBData.herds[username] = {}
    for _, rqhbId in ipairs(herdMD.animals) do
        table.insert(HBData.herds[username], rqhbId)
    end
end

-- Events.OnClientConnect is null on B42 dedicated servers per TIS docs;
-- Events.OnPlayerConnect is the correct B42 hook. Register on whichever
-- exists. Handler is idempotent so a duplicate fire is harmless.
local _hbConnectRegistered = {}
if Events.OnPlayerConnect then
    Events.OnPlayerConnect.Add(onClientConnect)
    _hbConnectRegistered[#_hbConnectRegistered + 1] = "OnPlayerConnect"
end
if Events.OnClientConnect then
    Events.OnClientConnect.Add(onClientConnect)
    _hbConnectRegistered[#_hbConnectRegistered + 1] = "OnClientConnect"
end
if #_hbConnectRegistered > 0 then
    print("[HB] Registered herd-load handler on: " ..
          table.concat(_hbConnectRegistered, ", "))
else
    print("[HB] WARNING: no player-connect event available; " ..
          "clients joining mid-game may have empty herd list until re-register")
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
