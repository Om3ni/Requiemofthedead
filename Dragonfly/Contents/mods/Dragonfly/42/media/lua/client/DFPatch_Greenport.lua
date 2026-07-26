-- DFPatch_Greenport.lua — Dragonfly removable third-party patch (client trigger)
--
-- Client half of the Greenport ground-item fix. Two jobs, both cheap:
--
--   1. NEUTRALIZE Greenport's buggy client spawner. Its LoadGridsquare handler
--      re-spawns scripted world items (shotgun shells, candles, tarot deck, etc.)
--      on every square load because both of its dedup guards compare the wrong
--      thing, and in MP each spawn's transmit triggers a square re-sync that
--      re-fires the handler — so ammo visibly pours onto the ground while a player
--      just stands there. The handler is a `local` bound straight to the event
--      with no module return, so there is nothing to require() or reassign (unlike
--      DFPatch_RVInterior / DFPatch_Spongies). We disable it through the one shared
--      surface it reads every call — the global GroundItemSpawnerItems list — by
--      emptying it at boot: with an empty list its getGroundItemsToSpawnAtCoords()
--      returns {}, so the handler becomes an inert no-op regardless of load order.
--
--   2. PING the server once per configured coord this client loads, so the server
--      (DFPatch_Greenport_Server.lua) can authoritatively clean duplicates and
--      spawn exactly one of each, one-and-done. The server keeps its own intact
--      copy of GroundItemSpawnerItems; emptying it here only affects this client.
--
-- Bugs referenced (common/media/lua/client/GP_GroundItemSpawner.lua): getFullType
-- vs bare compare @91, getObjects vs AddSpecialObject @71/@132, `return` @102.
--
-- DEDICATED-MP scoped, matching Dragonfly overall. In true single-player (no
-- server) the visit ping has no handler, so the scripted items will not spawn;
-- that is an unsupported config (SP players would not run Dragonfly anyway). This
-- file mirrors Greenport's own `if isServer() then return end`.
--
-- REMOVABLE: delete this file AND server/DFPatch_Greenport_Server.lua to drop the
-- patch. Greenport reverts to its original behaviour; nothing else depends on it.

if isServer() then return end

local MODULE = "DFGreenport"

local applied = false
local coords = {}   -- "x|y|z" -> true (configured spawn squares)
local pinged = {}   -- "x|y|z" -> true (already reported to the server this session)

local function apply()
    if applied then return end
    if type(GroundItemSpawnerItems) ~= "table" or #GroundItemSpawnerItems == 0 then
        return -- Greenport (or its item list) not present
    end
    applied = true

    local n = 0
    for i = 1, #GroundItemSpawnerItems do
        local d = GroundItemSpawnerItems[i]
        local k = d.x .. "|" .. d.y .. "|" .. d.z
        if not coords[k] then coords[k] = true; n = n + 1 end
    end

    -- Neutralize the original client spawner (see header).
    for i = #GroundItemSpawnerItems, 1, -1 do
        GroundItemSpawnerItems[i] = nil
    end

    print("[Dragonfly] DFPatch_Greenport (client) applied: watching " .. n
        .. " coord(s); original client spawner disabled")
end
Events.OnGameBoot.Add(apply)

local function onLoadGridSquare(square)
    if not applied then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local k = x .. "|" .. y .. "|" .. z
    if coords[k] and not pinged[k] then
        local p = getPlayer()
        if p then
            -- mark only after we actually send, so an early load before the player
            -- exists doesn't burn the ping for the whole session
            pinged[k] = true
            pcall(sendClientCommand, p, MODULE, "visit", { x = x, y = y, z = z })
        end
    end
end
Events.LoadGridsquare.Add(onLoadGridSquare)
