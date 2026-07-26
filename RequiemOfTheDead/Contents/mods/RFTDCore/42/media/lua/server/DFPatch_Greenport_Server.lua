-- DFPatch_Greenport_Server.lua — Dragonfly removable third-party patch (server authority)
--
-- Authoritative half of the Greenport ground-item fix. The client half
-- (client/DFPatch_Greenport.lua) neutralizes Greenport's buggy client spawner and
-- pings us once per configured coord a player loads; this file does the real work
-- on the server, where it is safe and persistent:
--
--   * CLEANUP: reap the duplicate item piles the original bug dumped (keep one of
--     each configured item per square) and remove the vestigial invisible
--     bookkeeping objects it spammed (IsoObject.new + AddSpecialObject carrying
--     .spawnedItems). Server-side removal via removeFromSquare()/removeFromWorld()
--     — the same three-step DFZombiesTab_Server uses — so it actually sticks in MP
--     instead of being re-sent by the server.
--   * ONE-AND-DONE: each configured coord+type spawns exactly once, EVER. The
--     "already spawned/taken" record lives in a server-saved global ModData table,
--     so a picked-up item never comes back — not on revisit, not after a restart.
--   * SPAWN: server-side AddWorldInventoryItem + transmitCompleteItemToClients,
--     mirroring how DFPatch_RVInterior places its generator, behind the same
--     square:getChunk() loaded-guard to avoid the native unloaded-chunk NPE.
--
-- Because the server's Lua runs single-threaded, two players loading the same
-- secret square cannot race a double-spawn: commands are handled in sequence, so
-- the first sets the record before the second is served.
--
-- NEW PATTERN NOTE: this is the first place in Dragonfly to use global ModData
-- (ModData.getOrCreate). It is used purely as a server-side saved table — never
-- transmitted, never read by clients — so there is no sync plumbing. If the API
-- ever misbehaves we fall back to an in-memory table (patch still works for the
-- session, just loses cross-restart persistence).
--
-- Greenport spawner reference: common/media/lua/client/GP_GroundItemSpawner.lua
--   (getFullType-vs-bare compare @91, getObjects-vs-AddSpecialObject @71/@132,
--    `return`-aborts-square @102). GroundItemSpawnerItems is defined in
--   common/media/lua/shared/GP_GroundItemSpawner_Items.lua (loads server-side too).
--
-- REMOVABLE: delete this file AND client/DFPatch_Greenport.lua to drop the patch;
-- Greenport reverts to its original behaviour. Nothing else in Dragonfly depends
-- on this. Note it only prevents/cleans over-spawning going forward and reaps
-- existing piles as squares are visited; it does not force-load the map to sweep
-- unvisited chunks.

if not isServer() then return end

local MODULE = "DFGreenport"
local STORE  = "DFGreenportConsumed"
local ZERO   = { x = 0, y = 0, z = 0 }

local store         -- persistent consumed set: "x|y|z|Base.Type" -> true
local defsByCoord   -- "x|y|z" -> { def, ... }

local function countKeys(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

local function initStore()
    if store then return store end
    local s
    local ok = pcall(function() s = ModData.getOrCreate(STORE) end)
    if not ok or type(s) ~= "table" then s = {} end   -- fallback: in-memory only
    store = s
    return store
end

local function buildDefs()
    defsByCoord = {}
    if type(GroundItemSpawnerItems) ~= "table" then return end
    for i = 1, #GroundItemSpawnerItems do
        local d = GroundItemSpawnerItems[i]
        local k = d.x .. "|" .. d.y .. "|" .. d.z
        defsByCoord[k] = defsByCoord[k] or {}
        table.insert(defsByCoord[k], d)
    end
end

-- Canonical module-qualified type ("ShotgunShells" -> "Base.ShotgunShells"),
-- resolved the same way the spawner does so it equals getFullType() on the item.
local function fullTypeOf(d)
    if not d._ft then
        local probe
        pcall(function() probe = instanceItem(d.itemFullType) end)
        d._ft = (probe and probe:getFullType()) or d.itemFullType
    end
    return d._ft
end

-- Reap all-but-one world item of fullType on the square. Returns how many were
-- present before reaping (>=1 means one copy remains).
local function reapDuplicates(square, fullType)
    local matches = {}
    local ok, wobs = pcall(function() return square:getWorldObjects() end)
    if ok and wobs then
        for i = 0, wobs:size() - 1 do
            local wo = wobs:get(i)
            local it = wo and wo:getItem()
            if it and it:getFullType() == fullType then
                matches[#matches + 1] = wo
            end
        end
    end
    for k = 2, #matches do
        local wo = matches[k]
        pcall(function() square:transmitRemoveItemFromSquare(wo) end)
        pcall(function() wo:removeFromSquare() end)
        pcall(function() wo:removeFromWorld() end)
    end
    return #matches
end

-- Remove the invisible bookkeeping objects the original bug piled up. Harmless if
-- any linger (no sprite), but we clean them since the store replaces them.
local function reapOrphanMarkers(square)
    local ok, sobs = pcall(function() return square:getSpecialObjects() end)
    if not ok or not sobs then return 0 end
    local rm = {}
    for i = 0, sobs:size() - 1 do
        local o = sobs:get(i)
        local md = o and o:getModData()
        if md and md.spawnedItems then rm[#rm + 1] = o end
    end
    for _, o in ipairs(rm) do
        pcall(function() square:transmitRemoveItemFromSquare(o) end)
        pcall(function() o:removeFromSquare() end)
        pcall(function() o:removeFromWorld() end)
    end
    return #rm
end

-- Mirrors Greenport's own placement (GP_GroundItemSpawner.lua:100-141) but on the
-- server and transmitting to clients instead of to server.
local function spawnDef(square, d, fullType)
    local item
    pcall(function() item = instanceItem(fullType) end)
    if not item then return false end

    local placed
    local ok = pcall(function()
        local off = d.offset or ZERO
        placed = square:AddWorldInventoryItem(item, off.x, off.y, off.z, false)
    end)
    if not ok or not placed then return false end

    local worldItem
    pcall(function() worldItem = placed:getWorldItem() end)

    if type(d.rotation) == "number" then
        pcall(function() placed:setWorldZRotation(d.rotation) end)
    end
    if worldItem then pcall(function() worldItem:setIgnoreRemoveSandbox(true) end) end

    if d.onCreateItem and type(_G[d.onCreateItem]) == "function" then
        pcall(_G[d.onCreateItem], placed, square)
    end
    if d.onCreateWorldItem and type(_G[d.onCreateWorldItem]) == "function" and worldItem then
        pcall(_G[d.onCreateWorldItem], worldItem, square)
    end

    if worldItem then pcall(function() worldItem:transmitCompleteItemToClients() end) end
    return true
end

local function processCoord(x, y, z)
    local ck = x .. "|" .. y .. "|" .. z
    local list = defsByCoord and defsByCoord[ck]
    if not list then return end   -- not a configured coord (ignore spoofed/bogus pings)

    local square
    pcall(function() square = getCell():getGridSquare(x, y, z) end)
    if not square then return end

    local chunkOk = false
    pcall(function() chunkOk = square:getChunk() ~= nil end)
    if not chunkOk then return end   -- chunk not loaded server-side; skip (RVInterior lesson)

    local s = initStore()
    reapOrphanMarkers(square)

    local spawned, reaped = 0, 0
    for i = 1, #list do
        local d = list[i]
        local ft = fullTypeOf(d)
        local key = ck .. "|" .. ft

        local before = reapDuplicates(square, ft)
        if before > 1 then reaped = reaped + (before - 1) end

        if before >= 1 then
            s[key] = true              -- one copy present: lock it (spawned-ever)
        elseif s[key] then
            -- already spawned once and since taken: one-and-done, leave gone
        else
            if spawnDef(square, d, ft) then
                s[key] = true
                spawned = spawned + 1
            end
        end
    end

    if spawned > 0 or reaped > 0 then
        print(string.format("[Dragonfly] DFPatch_Greenport: %d,%d,%d -> spawned %d, reaped %d duplicate(s)",
            x, y, z, spawned, reaped))
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= "visit" then return end
    if type(args) ~= "table" then return end
    local x, y, z = args.x, args.y, args.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return end
    pcall(processCoord, x, y, z)
end
Events.OnClientCommand.Add(onClientCommand)

Events.OnServerStarted.Add(function()
    initStore()
    buildDefs()
    print(string.format("[Dragonfly] DFPatch_Greenport (server) ready: %d configured coord(s), %d consumed key(s) loaded",
        countKeys(defsByCoord), countKeys(store)))
end)
