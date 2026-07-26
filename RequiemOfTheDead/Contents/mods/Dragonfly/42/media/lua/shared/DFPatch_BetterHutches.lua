-- DFPatch_BetterHutches.lua — Dragonfly removable third-party patch (SHARED: client + server)
--
-- Stops the repeating `ObjectModDataPacket.parse: object is null`
-- (objectType:1, objectId:-1) spam attributed to "STA Better Hutches".
--
-- Cause: Better Hutches' EveryOneMinute timer (STA_BetterHutches_Hutch.lua)
-- iterates DesignationZoneAnimal:getHutchs() — a zone list the engine NEVER
-- prunes per-hutch (only clear()+rebuild) — and calls Utils.setObjectModData()
-- twice per bedded hutch, which always does obj:transmitModData(). When the list
-- still holds a destroyed/orphaned hutch, that hutch has a square but is NOT in
-- its square's getObjects() (indexOf == -1), so the transmit serializes a junk
-- type-1/-1 ObjectModData packet that resolves to null on the receiver — every
-- game-minute, twice per stale hutch.
--
-- Fix: reimplement Utils.setObjectModData to keep the ModData write but only
-- transmit when the object is a LIVE world object (present in its square's
-- object list). A stale hutch is skipped — the packet was junk anyway. Live
-- hutches (player bedding/cleaning) transmit exactly as before. This is in
-- SHARED so it covers both the server timer and client-side timed actions.
--
-- This is also self-confirming: if Better Hutches was the source, the type-1/-1
-- spam disappears; if it persists, the culprit is elsewhere.
--
-- REMOVABLE: delete this file to drop the patch. Better Hutches keeps working
-- with its original behaviour; nothing else in Dragonfly depends on this.

local applied = false

-- Mirrors the engine's MovingObject type-1 identity: objectId =
-- square:getObjects():indexOf(obj); a value of -1 (object not in the list) is
-- the stale/orphaned case that produces the null-object packet.
local function isLiveWorldObject(obj)
    if not obj then return false end
    local ok, sq = pcall(function() return obj.getSquare and obj:getSquare() or nil end)
    if not ok or not sq then return false end
    local ok2, objs = pcall(function() return sq:getObjects() end)
    if not ok2 or not objs then return false end
    for i = 0, objs:size() - 1 do
        if objs:get(i) == obj then return true end
    end
    return false
end

local function apply()
    if applied then return end
    local ok, Utils = pcall(require, "STA_BetterHutches_Utils")
    if not ok or type(Utils) ~= "table" or type(Utils.setObjectModData) ~= "function" then
        return -- Better Hutches not present
    end
    applied = true

    Utils.setObjectModData = function(obj, key, value)
        if not obj then return end
        local data = obj:getModData()
        if not data then return end
        if not data[Utils.modID] then data[Utils.modID] = {} end
        data[Utils.modID][key] = value
        -- DRAGONFLY FIX: only sync a live, in-world object. Skipping a stale
        -- hutch's transmit removes the junk type-1/-1 ObjectModData packet.
        if isLiveWorldObject(obj) then
            obj:transmitModData()
        end
    end

    print("[Dragonfly] DFPatch_BetterHutches applied (stale-hutch transmit guard)")
end

-- Cover every context: OnServerStarted (dedicated server) and OnGameBoot
-- (client / single-player). The `applied` guard keeps it idempotent.
Events.OnServerStarted.Add(apply)
Events.OnGameBoot.Add(apply)
