-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCSpawn - the vehicle spawn EXECUTOR (server only).
--
-- ONE spawn brain, many doors. Today the only caller is RCServer's
-- `spawnvehicle` handler (the staff spawner); the planned §4 recycle path
-- (token redemption -> vehicle) calls THIS SAME function through its own
-- gates, so spawn mechanics never fork. The executor does no permission or
-- ledger work - the CALLER gates and audits; this file owns validation and
-- construction only.
--
-- Trust model (the donor mod's hole, inverted): nothing in `spec` is believed.
--   * model     - must resolve in the ScriptManager (a forged string dies here)
--   * square    - must be a LOADED grid square. Deliberately no radius leash:
--                 getGridSquare() already fails on unloaded chunks, and a
--                 teleporting admin shouldn't fight a distance check.
--   * all rolls - direction, per-part condition bands, fuel, battery - happen
--                 HERE, per spawn. The donor rolled its "Random" condition ONCE
--                 at UI-build time and reused the frozen number all session.
--
-- Returns vehicle, nil, removedCount on success; nil, reason on failure
-- (reason: "badmodel" | "nosquare" | "failed"). removedCount is how many
-- parts the missingParts pass stripped (0 when the flag is off).

if not isServer() then return end

require "RCNoVanilla"

RCSpawn = RCSpawn or {}

local COND = { random = true, perfect = true, average = true, low = true }

-- Per-part wear roll for a condition band. "perfect" is exact; the bands
-- mirror the donor's (admins are used to them): average 40-80, low 1-40,
-- random anywhere in 1-100. Rolled per PART, so a band gives varied wear.
local function rollCondition(mode)
    if mode == "perfect" then return 100 end
    if mode == "average" then return ZombRand(40, 81) end
    if mode == "low" then return ZombRand(1, 41) end
    return ZombRand(1, 101)
end

-- spec = { model, x, y, z, direction (0-4, 0/absent = roll), condition
--          ("random"|"perfect"|"average"|"low"), noFuel, noBattery,
--          keyGlovebox, missingParts }
function RCSpawn.spawn(spec)
    spec = spec or {}

    -- Model: the ScriptManager IS the whitelist - length-capped like every
    -- other client-supplied string in this mod. The lookup is getVehicle
    -- (ScriptManager.java:831). ScriptManager has NO getVehicleScript in 42.20
    -- - the only getVehicleScript in the engine is UI3DScene's fromLua verb -
    -- so naming it that raised inside the pcall, script stayed nil, and every
    -- single spawn died here as "badmodel". getVehicle takes the full name and
    -- resolves a dotless one against the Base module on its own
    -- (ScriptBucketCollection.java:78-88).
    local model = spec.model
    if type(model) ~= "string" or model == "" or #model > 128 then return nil, "badmodel" end
    -- Bare: the null-bucket NPE (ScriptBucketCollection.java:86-87) is
    -- swallowed to nil by MethodCaller (MethodCaller.java:33-56); the nil
    -- test is the gate, and `model` is string-typed above.
    local script = getScriptManager():getVehicle(model)
    if not script then return nil, "badmodel" end

    -- Square: loaded-or-nothing.
    local x, y, z = tonumber(spec.x), tonumber(spec.y), tonumber(spec.z)
    if not (x and y) then return nil, "nosquare" end
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    local square = getCell():getGridSquare(x, y, z)
    if not square then return nil, "nosquare" end

    -- Direction: 1-4 = W/E/N/S; anything else rolls here, server-side.
    local d = tonumber(spec.direction) or 0
    if d < 1 or d > 4 then d = ZombRand(1, 5) end
    local direction = (d == 1 and IsoDirections.W)
        or (d == 2 and IsoDirections.E)
        or (d == 3 and IsoDirections.N)
        or IsoDirections.S

    local mode        = COND[spec.condition] and spec.condition or "random"
    local noFuel      = spec.noFuel == true
    local noBattery   = spec.noBattery == true
    local keyGlovebox = spec.keyGlovebox == true

    -- Latched so RCNoVanilla's story interceptor never burns a staff spawn:
    -- OnSpawnVehicleStart fires synchronously inside addVehicleDebug.
    RCNoVanilla.beginExempt()
    -- Bare: addVehicleDebug is an exposed global (LuaManager.java:8493-8526)
    -- whose body faults - the BaseVehicle constructor included - are
    -- swallowed and stack-traced by MethodCaller (MethodCaller.java:33-56),
    -- and the spawn event it fires runs every listener under the
    -- dispatcher's own per-listener catch (Event.java:52-63). Nothing here
    -- can throw past endExempt; a faulted build answers nil and reports
    -- "failed" exactly as before.
    local vehicle = addVehicleDebug(model, direction, nil, square)
    RCNoVanilla.endExempt()
    if not vehicle then return nil, "failed" end

    -- Wreck hulls (Burnt/Smashed) keep their as-spawned state: dressing a
    -- wreck in "perfect" parts is a contradiction, and burnt hulls have no
    -- working parts worth conditioning anyway.
    if RCShared.isWreck(vehicle) then return vehicle, nil end

    local count = vehicle:getPartCount()
    local partFailed, firstPartErr, firstPartId = 0, nil, nil
    for i = 0, count - 1 do
        -- RETAINED, one member of an independent batch: a modded part with a
        -- nonstandard layout must not abort conditioning for the rest of the
        -- vehicle (the dumpVehicleContainers lesson). setEngineFeature,
        -- createVehicleKey and setInventoryItem all cascade into part stats,
        -- mass and model visibility, and none is preflightable from Lua.
        --
        -- REDESIGNED twice over. The wear roll now runs FIRST: it is the one
        -- write every part needs, and sitting last meant a battery whose
        -- setUsedDelta threw ALSO silently lost its condition, so one odd part
        -- came out both unconditioned and unreported. The specialised branches
        -- are mutually exclusive by id, so at most one follows it.
        --
        -- And the pass now REPORTS. It used to swallow whole, which meant a
        -- modded vehicle where every part failed produced a car that looked
        -- spawned correctly and was uniformly untouched - the exact silent
        -- failure this refactor exists to delete.
        local okPart, partErr = pcall(function()
            local part = vehicle:getPartByIndex(i)
            if not part then return end
            local id = part:getId()
            local idLower = id and string.lower(id) or ""

            ----- every part: wear rolled inside the chosen band -----
            part:setCondition(rollCondition(mode))
            vehicle:transmitPartCondition(part)

            ----- battery charge: uniform 0-100% unless forced empty -----
            if string.contains(idLower, "battery") then
                local item = part:getInventoryItem()
                if item then
                    local delta = noBattery and 0 or (ZombRand(0, 101) / 100)
                    item:setUsedDelta(delta)
                    vehicle:transmitPartUsedDelta(part)
                end
            end

            ----- fuel: uniform % of tank capacity unless forced empty -----
            if string.contains(idLower, "tank") then
                local amount = 0
                if not noFuel then
                    local capacity = part:getContainerCapacity() or 0
                    amount = capacity * ZombRand(1, 101) / 100
                end
                part:setContainerContentAmount(amount)
                vehicle:transmitPartModData(part)
            end

            ----- engine: its own feature triple, not just part wear -----
            if idLower == "engine" then
                local loud  = vehicle:getScript():getEngineLoudness() or 100
                local force = vehicle:getScript():getEngineForce()
                vehicle:setEngineFeature(rollCondition(mode), loud, force)
                vehicle:transmitEngine()
            end

            ----- key in glovebox (+ door unlock, matching the donor UX) -----
            if idLower == "glovebox" and keyGlovebox then
                local key = vehicle:createVehicleKey()
                if key then part:getItemContainer():AddItem(key) end
                for j = 0, 4 do
                    local door = vehicle:getPassengerDoor(j)
                    if not door then break end
                    local dp = door:getDoor()
                    if dp then
                        dp:setLockBroken(false)
                        dp:setLocked(false)
                        vehicle:transmitPartDoor(door)
                    end
                end
            end

        end)
        if not okPart then
            partFailed = partFailed + 1
            if not firstPartErr then
                firstPartErr = partErr
                local p = vehicle:getPartByIndex(i)
                firstPartId = p and p:getId() or ("index " .. tostring(i))
            end
        end
    end
    if partFailed > 0 then
        print(string.format(
            "[RC] spawn: %d of %d part(s) could not be conditioned on %s (first: %s - %s)",
            partFailed, count, tostring(model), tostring(firstPartId), tostring(firstPartErr)))
    end

    -- Missing parts: strip a random 1..cap installable parts so a reclaimed
    -- hull needs sourcing before it rolls. ONLY reachable from the staff
    -- spawner (this is the sole caller path), so it can never touch a world,
    -- player, or reclaimed vehicle. Never the engine (excluded by request - a
    -- car with no engine reads as a total wreck, not a project). A part is
    -- "installable/removable" exactly when it currently holds an inventory
    -- item; setInventoryItem(nil) is vanilla's own uninstall. Runs AFTER
    -- conditioning so we pick from the parts that ended up installed. The cap
    -- is the SpawnerMissingPartsMax sandbox option (default 6).
    local removed = 0
    if spec.missingParts == true then
        local cap = RCShared.cfg().spawnerMissingMax
        local candidates = {}
        -- bounds-checked walk and field returns (VehicleParts.java:111,
        -- VehiclePart.java:130/166) - no guard needed
        for i = 0, count - 1 do
            local part = vehicle:getPartByIndex(i)
            if part then
                local id = part:getId()
                if id and string.lower(id) ~= "engine" and part:getInventoryItem() ~= nil then
                    candidates[#candidates + 1] = part
                end
            end
        end
        local pool = #candidates
        if pool > 0 then
            local n = ZombRand(1, math.min(pool, cap) + 1)
            -- Partial Fisher-Yates: swap a random tail element into slot k, so
            -- the first n picks are distinct with no per-part retry loop.
            for k = 1, n do
                local j = ZombRand(k, pool + 1)   -- k..pool inclusive
                candidates[k], candidates[j] = candidates[j], candidates[k]
                -- Bare: setInventoryItem(nil) is vanilla's own idiom
                -- (ISUninstallVehiclePart.lua:64, Vehicles.lua:1359) - nil is
                -- legal for an object parameter, and any cascade fault inside
                -- the body (VehiclePart.java:184-186) is swallowed and
                -- stack-traced by MethodCaller (MethodCaller.java:33-56). The
                -- pcall here could never fire, so "a failed strip is never
                -- counted as a strip" was an illusion - the count was already
                -- unconditional in practice, and now says so.
                candidates[k]:setInventoryItem(nil)
                vehicle:transmitPartItem(candidates[k])
                removed = removed + 1
            end
        end
    end

    return vehicle, nil, removed
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
