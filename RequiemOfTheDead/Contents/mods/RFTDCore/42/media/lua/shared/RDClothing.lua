-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDClothing.lua - clothing state primitives the engine exposes but nothing wraps.
--
-- WHY THIS IS IN CORE: two consumers. Dragonfly's admin panel needs to mend holes
-- (its Repair All could not) and Wardrobe will need to reproduce holes when it
-- restores a stored outfit. Both also need the clothing sync below, and getting
-- that wrong is invisible in single-player, which is exactly the kind of mistake
-- that should be made once in one place.
--
-- THE SYNC TRAP, which is the real reason this file exists. Clothing blood, dirt,
-- holes and patches do NOT live on the InventoryItem - they live on its ItemVisual
-- (private byte[] blood / dirt arrays indexed by BloodBodyPartType). sendItemStats
-- syncs item STAT FIELDS and does not touch the visual, so a server-side write to
-- any of them lands on the server and is never seen by another client. Dragonfly's
-- Repair All had this bug: it cleared blood and dirt and synced with
-- sendItemStats, so nothing propagated. The fix is syncClothingFields, a Lua
-- global (LuaManager.java:3719) that is server-gated internally.
--
-- Clothing.fullyRestore() is the exception - it sends SyncClothing to all itself
-- (Clothing.java:1012), so callers using it do not additionally need sync(). It is
-- also the right call for a FULL restore, because it clears patches too, which we
-- cannot do from Lua: Clothing.patches is a private HashMap with no public
-- remover. setHoleCount below is therefore holes-only by necessity, not by choice.
--
-- HOLES GO BOTH WAYS. The earlier "remove-only, adding would be a griefing
-- primitive" rule was a POLICY decision baked into a MECHANISM, which is the
-- wrong layer and is why it was incoherent in practice.
--
-- Abuse is prevented at the authorization boundary, not by leaving capability
-- out of a primitive. Every write here arrives through DFServer's handler gate,
-- which checks the caller's role against the handler's Capability server-side
-- and audits the refusal (DFServer.lua:79-81); the item editor's gate is
-- Capability.EditItem. A caller who has passed that gate can already Dump
-- Contents and zero a garment's condition through the SAME handler - so
-- refusing five holes while permitting "delete everything they own" protected
-- nobody and only made the tool inconsistent with itself. Vanilla agrees: its
-- own admin health panel adds holes to another player's clothing server-side
-- (otherPlayer:addHole(part) then syncVisuals, vanilla
-- server/ClientCommands.lua:458-461).
--
-- The general rule this violated is CLAUDE.md section 11: a helper centralizes
-- mechanism, and call-site policy stays at the call site. Core owns "how to put
-- a hole in a garment correctly". Who may do it is Dragonfly's capability gate.
--
-- Condition math mirrors vanilla in BOTH directions and is not invented here:
-- Clothing.addPatch credits getCondLossPerHole() back when it fully restores a
-- part (Clothing.java:1029), and Clothing.addRandomHole debits exactly that per
-- hole added (:1112). Writes use setConditionNoSound (InventoryItem.java:2555)
-- so an admin edit that drives a garment to zero does not fire the break sound
-- and cascade of a real in-play breakage.
--
-- ENGINE-TOUCHING, unlike RDItemKind: BloodBodyPartType, syncClothingFields and
-- instanceof are all globals. Each is reached inside a function behind a
-- nil/type() check, so loading this file costs nothing and a test only stubs
-- what it actually calls.

RDClothing = RDClothing or {}

-- Number of body-part slots the blood/dirt/hole arrays are indexed by. Read from
-- the enum rather than hardcoded because it has changed across builds.
function RDClothing.partCount()
    -- index() is ordinal() (BloodBodyPartType:44); the chain covers the
    -- global being absent under test stubs
    local maxPart = BloodBodyPartType and BloodBodyPartType.MAX
    local n = maxPart and maxPart:index() or nil
    if type(n) ~= "number" or n <= 0 then return 0 end
    return n
end

function RDClothing.isClothing(item)
    if not item then return false end
    -- instanceof (LuaManager:2837) null-checks obj and falls through to
    -- false on an unknown name; the type() covers test stubs
    if type(instanceof) ~= "function" then return false end
    return instanceof(item, "Clothing") == true
end

-- The Dragonfly wire handler may invoke the function setter with an arbitrary
-- inventory object. InventoryItem.getVisual itself returns nil when no clothing
-- asset is ready (InventoryItem.java:2070-2082), but an unowned replacement
-- method can still throw. Keep that single foreign-object boundary here, where
-- mending can report the failure instead of silently pretending the item is
-- merely clean.
local function readVisual(item)
    if not item or type(item.getVisual) ~= "function" then return nil, "item has no visual" end
    local ok, visual = pcall(item.getVisual, item)
    if not ok then return nil, "item visual lookup failed: " .. tostring(visual) end
    if not visual then return nil, "item has no visual" end
    return visual
end

local function collectHoleParts(visual)
    local out = {}
    for i = 0, RDClothing.partCount() - 1 do
        -- getHole (ItemVisual:508) null-checks the holes array; FromIndex
        -- (:48) clamps, and i < MAX:index() keeps the byte index in bounds
        local hole = visual:getHole(BloodBodyPartType.FromIndex(i))
        if type(hole) == "number" and hole > 0 then
            out[#out + 1] = i
        end
    end
    return out
end

-- Body-part indices that currently have a hole, ascending.
function RDClothing.holeParts(item)
    local visual = readVisual(item)
    if not visual then return {} end
    return collectHoleParts(visual)
end

-- Covered parts this garment could still take a hole in, in covered-parts order.
-- Returns PART TOKENS (what setHole takes), unlike collectHoleParts above, which
-- returns INDICES (what removeHole takes) - the two engine methods genuinely
-- disagree (ItemVisual.java:505 vs :617).
--
-- DEDUPED, and that is not defensive: getCoveredParts concatenates the covered
-- list of every BloodClothingType the garment declares (BloodClothingType.java:86-93),
-- so a garment declaring two overlapping types lists the same part twice. Without
-- the dedupe we would "add" two holes to one part and report a count the engine
-- would never agree with, since a hole is one byte per part.
local function collectHolelessParts(item, visual)
    local out, seen = {}, {}
    if type(item.getCoveredParts) ~= "function" then return out end
    local parts = item:getCoveredParts()
    local n = parts and parts:size() or 0
    for i = 0, n - 1 do
        local part = parts:get(i)
        local key = tostring(part)
        if part ~= nil and not seen[key] and visual:getHole(part) <= 0 then
            seen[key] = true
            out[#out + 1] = part
        end
    end
    return out
end

-- Set the garment's hole count to targetCount, adding or removing as needed.
-- Returns ok, err, delta (delta > 0 added, < 0 removed).
--
-- ADDING mirrors Clothing.addRandomHole (Clothing.java:1102-1113) exactly: only
-- covered parts are eligible, canHaveHoles is honoured, one hole per part, and
-- condition is debited getCondLossPerHole per hole. The one deliberate
-- difference is that vanilla picks a RANDOM part and we walk ascending - an
-- admin setting a count wants a predictable result, and a hole is a hole to the
-- player either way.
--
-- REMOVING walks the highest index downward, crediting the same per-hole amount
-- back. Both orders are deterministic so the fixture can assert exact counts.
--
-- The cap is real, not arbitrary: a garment cannot hold more holes than it has
-- covered parts, because a hole is one byte per part (ItemVisual.java:505-511).
function RDClothing.setHoleCount(item, targetCount)
    if not item then return false, "no item", 0 end

    targetCount = tonumber(targetCount)
    if not targetCount then return false, "hole count must be a number", 0 end
    targetCount = math.floor(targetCount)
    if targetCount < 0 then targetCount = 0 end

    local visual, visualErr = readVisual(item)
    if not visual then return false, visualErr, 0 end

    local holed = collectHoleParts(visual)
    local current = #holed

    if targetCount == current then
        return false, string.format("already has %d hole(s)", current), 0
    end

    if targetCount < current then
        local removed = 0
        for i = current, targetCount + 1, -1 do
            -- removeHole (ItemVisual:617) null-checks the array; indices come
            -- from holeParts so they are in bounds
            visual:removeHole(holed[i])
            removed = removed + 1
        end
        RDClothing.creditHoleCondition(item, removed)
        return true, nil, -removed
    end

    -- Adding. canHaveHoles is a nullable Boolean on the script item
    -- (Clothing.java:825); vanilla derefs it unguarded at :1103, so it is set in
    -- practice - only an explicit false is a refusal.
    if item.getCanHaveHoles and item:getCanHaveHoles() == false then
        return false, "this garment cannot have holes", 0
    end

    local free = collectHolelessParts(item, visual)
    if #free == 0 then
        return false, string.format(
            "every covered part already has a hole (%d)", current), 0
    end

    local wanted = targetCount - current
    local added = 0
    for i = 1, math.min(wanted, #free) do
        -- setHole (ItemVisual:505) allocates the array on first write and takes
        -- the part token, not an index
        visual:setHole(free[i])
        added = added + 1
    end
    RDClothing.debitHoleCondition(item, added)

    if added < wanted then
        -- Partial success is reported, not silently rounded down: the admin
        -- asked for a number this garment cannot physically hold.
        return true, string.format(
            "added %d - this garment holds at most %d hole(s)", added, current + added), added
    end
    return true, nil, added
end

-- Condition credit / debit for holes, clamped to [0, max]. Split out so Wardrobe
-- can reuse them when it rebuilds a stored outfit's holes.
--
-- getCondLossPerHole is Clothing's alone (Clothing.java:1074) - anything else
-- that lands here bows out at the door instead of hiding behind a guard. The
-- rest are field reads (getCondition:2502, getConditionMax:2233).
-- setConditionNoSound (:2555) delegates to setCondition(v, false), which clamps
-- both ends itself; the false is what keeps an admin edit from firing the
-- breakage sound and onBreak path that a real in-play failure would.
local function adjustHoleCondition(item, holes, perHoleSign)
    if not item or not holes or holes <= 0 then return end
    if not item.getCondLossPerHole then return end

    local target = item:getCondition() + perHoleSign * item:getCondLossPerHole() * holes
    local maxCond = item:getConditionMax()
    if target > maxCond then target = maxCond end
    if target < 0 then target = 0 end

    local write = item.setConditionNoSound or item.setCondition
    write(item, math.floor(target))
end

function RDClothing.creditHoleCondition(item, holesRemoved)
    adjustHoleCondition(item, holesRemoved, 1)
end

function RDClothing.debitHoleCondition(item, holesAdded)
    adjustHoleCondition(item, holesAdded, -1)
end

-- ---------------------------------------------------------------------------
-- Blood / dirt, written where they actually live.
--
-- Clothing.setBloodLevel / setDirtiness are DERIVED-CACHE writes: the engine
-- recomputes both scalars as the average of the ItemVisual's per-part arrays
-- (calcTotalBloodLevel BloodClothingType.java:319, calcTotalDirtLevel :343,
-- called from synchWithVisual InventoryItem.java:2116-2119), and rendering
-- reads only the arrays. A bare scalar write therefore neither shows nor
-- survives the next recalc. Dragonfly's item editor shipped exactly that bug:
-- its Bloody/Dirty rows wrote numbers the engine quietly threw away.
--
-- These write the arrays across the garment's covered parts - the same surface
-- vanilla uses (ISGarmentUI.lua:43 iterates clothing:getCoveredParts();
-- ISDebugBlood.lua:72 calls setBlood) - then set the scalar to the average the
-- engine's own calcTotal would produce, re-READ through the visual so the byte
-- quantization (ItemVisual.java:527-555 stores amount*255 truncated to a byte)
-- is reflected instead of drifting until the next engine recalc.
-- ---------------------------------------------------------------------------

-- The two channels are exact parallels in the engine - twin per-part arrays on
-- ItemVisual, twin calcTotal bodies, one covered-parts rule - so they share one
-- entry point rather than a pair of twin wrappers.
local CHANNELS = {
    blood = { setPart = "setBlood", getPart = "getBlood", scalar = "setBloodLevel" },
    dirt  = { setPart = "setDirt",  getPart = "getDirt",  scalar = "setDirtiness"  },
}

-- Set a garment's blood or dirt level. channel is "blood" or "dirt"; pct is
-- 0-100, matching getBloodLevel/getDirtiness units. Returns ok, err. The caller
-- owns propagation: on the server follow a batch of these with RDClothing.sync().
function RDClothing.setVisualPercent(item, channel, pct)
    local ch = CHANNELS[channel]
    if not ch then return false, "unknown channel: " .. tostring(channel) end
    if not item then return false, "no item" end

    pct = tonumber(pct)
    if not pct then return false, "level must be a number" end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end

    local visual, visualErr = readVisual(item)
    if not visual then return false, visualErr end

    -- getCoveredParts is Clothing's alone (Clothing.java:1064) and derefs the
    -- script item (:1065), so both are preflighted: anything else that lands
    -- here bows out at the door, same as adjustHoleCondition.
    if type(item.getCoveredParts) ~= "function" then
        return false, "not a garment"
    end
    if type(item.getScriptItem) == "function" and not item:getScriptItem() then
        return false, "item has no script definition"
    end

    -- Never nil: BloodClothingType.getCoveredParts (:86) always returns the
    -- list, empty when the script declares no BloodLocation. Duplicates are
    -- harmless here, unlike for holes: every part gets the SAME value, so a
    -- part listed twice is written twice and weights the average identically.
    local parts = item:getCoveredParts()
    local n = parts and parts:size() or 0
    if n == 0 then return false, "garment has no blood/dirt-mappable parts" end

    -- setBlood/setDirt clamp 0..1 and allocate the array on first write
    -- (ItemVisual.java:527/:549) - total, no throw path.
    local amount = pct / 100
    for i = 0, n - 1 do
        visual[ch.setPart](visual, parts:get(i), amount)
    end

    -- Derived scalar, kept consistent the way calcTotal*Level derives it:
    -- average of the just-written parts, read back through the visual.
    local total = 0
    for i = 0, n - 1 do
        total = total + visual[ch.getPart](visual, parts:get(i)) * 100
    end
    item[ch.scalar](item, total / n)

    return true
end

-- Push clothing FIELD state (the ItemVisual side) to other clients. Server-gated
-- inside the engine, so calling it clientside is a harmless no-op. Call this once
-- after a batch of writes, not per item.
--
-- Not needed after Clothing.fullyRestore(), which sends SyncClothing itself.
function RDClothing.sync(player)
    if not player then return false end
    if type(syncClothingFields) ~= "function" then return false end
    -- LuaManager:3720 server-gates; GameServer.syncClothingFields:2298
    -- null-checks each worn item and INetworkPacket.send:127 try/catches
    syncClothingFields(player)
    return true
end

return RDClothing

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
