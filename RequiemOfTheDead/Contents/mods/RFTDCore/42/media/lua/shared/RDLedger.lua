-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RDLedger.lua - keyed rows with an explicit lifetime, swept on a budget.
--
-- THE PROBLEM THIS EXISTS TO SOLVE, and it is not a style preference.
--
-- KAHLUA HAS NO WEAK TABLES. Verified against the 42.20.3 decompile
-- 2026-08-25: `J2SEPlatform.newTable()` returns
-- `new KahluaTableImpl(new LinkedHashMap<Object, Object>())`
-- (J2SEPlatform.java:41-43), `KahluaTableImpl.setMetatable` stores the
-- metatable without ever inspecting it, and the string `__mode` appears
-- NOWHERE in the engine. So `setmetatable({}, { __mode = "k" })` is
-- decoration. The table is strong, it pins every IsoZombie you put in it for
-- the life of the process, and it stops the engine collecting them.
--
-- This is the worst shape of bug this codebase can have, because
-- `run-tests.bat` runs REAL Lua 5.1, which really does have weak tables. All
-- 100+ fixtures pass green while the shipped mod leaks. Same family as
-- `next()` - see CLAUDE.md section 3.
--
-- Fourteen sites across seven files were written against the weak-table
-- assumption. Rather than hand-roll fourteen different eviction rules, a row
-- lives HERE and states its own liveness rule once.
--
-- =============================================
-- WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
-- =============================================
-- It is not a database and does not pretend to be one. There is no query
-- planner, no join, no index, no transaction. What it does take from that
-- world is the only part that was actually missing: a row has a stated
-- liveness rule, and something walks the table on a budget and enforces it.
--
--   ledger.set(k, v)     write a row
--   ledger.get(k)        read one, checking liveness first
--   ledger.forEach(fn)   visit every LIVE row, evicting the dead as it goes
--   ledger.sweep(n)      bounded incremental housekeeping
--
-- If a query surface is ever genuinely needed, the place to add it is a
-- secondary index inside this file - NOT a scan at each call site, which is
-- the mistake `RQCore.findZombieByID` already makes (a 31x31 grid walk per
-- special per render tick).
--
-- =============================================
-- WHY AN ARRAY, AND WHY BACKWARDS
-- =============================================
-- `next()` DOES NOT EXIST IN KAHLUA, so a resumable cursor cannot be built on
-- stateful `next(t, key)` iteration the way real Lua would do it. Every row's
-- key therefore also lives in a plain array, and the sweep cursor is an index
-- into that array. Removal is swap-with-last plus pop, which is O(1) and keeps
-- the array dense.
--
-- That same swap is why `forEach` walks BACKWARDS. Removing element i moves
-- the last element into slot i; walking forwards would skip it, and walking
-- backwards cannot, because everything past i has already been visited.
-- Mutating the ledger from inside a forEach callback is therefore safe, which
-- matters because "visit each row and drop the ones that died" is the single
-- most common thing callers want to do.
--
-- =============================================
-- THE SWEEP IS SELF-DRIVING
-- =============================================
-- A ledger you have to remember to housekeep is a ledger that leaks, which is
-- exactly how we got here. Creating one registers it, and the heartbeat at the
-- bottom of this file sweeps every registered ledger on a small budget. A
-- caller that never thinks about lifetime again still gets correct lifetime.
-- =============================================

RDLedger = RDLedger or {}

-- Rows examined per ledger per sweep. Small on purpose: the sweep is a
-- background tidy, not a scan. Anything urgent is caught by get()/forEach()
-- checking liveness at the moment of use.
local DEFAULT_SWEEP_BUDGET = 32

-- How often the heartbeat runs. Wall clock, not tick counts - OnTick sags
-- under load and this must not sag with it.
local SWEEP_INTERVAL_MS = 2000

-- Every ledger ever created, so one call can housekeep the suite. These are
-- module-level and live for the whole session by design; this array is not a
-- leak, it IS the registry.
RDLedger.ledgers = RDLedger.ledgers or {}

-- Create a ledger.
--
--   name         string, required. Appears in stats and reports; make it the
--                thing being tracked, not the module doing the tracking.
--   live         function(key, value) -> boolean. The liveness rule. Omitted
--                means rows only leave when a caller removes them - legitimate
--                for a pure cache, but state it deliberately.
--   onEvict      function(key, value, reason). Optional cleanup hook.
--   sweepBudget  rows examined per sweep pass.
function RDLedger.new(opts)
    local name = opts and opts.name
    if type(name) ~= "string" or name == "" then
        error("RDLedger.new: a ledger must be named")
    end
    local live    = opts and opts.live
    local onEvict = opts and opts.onEvict
    local budget  = (opts and tonumber(opts.sweepBudget)) or DEFAULT_SWEEP_BUDGET

    -- rows: key -> value. keys: dense array of keys. slot: key -> array index.
    -- The array and the slot map exist only to make the sweep resumable and
    -- removal O(1); rows is the source of truth.
    local rows, keys, slot = {}, {}, {}
    local cursor = 0

    local ledger = {}
    ledger.name = name
    ledger.stats = {
        set     = 0,   -- rows written
        hits    = 0,   -- get() found a live row
        misses  = 0,   -- get() found nothing, or found a dead row
        evicted = 0,   -- rows removed, any reason
        expired = 0,   -- subset of evicted: failed the liveness rule
        swept   = 0,   -- rows examined by the background sweep
    }
    local stats = ledger.stats

    -- Swap-with-last removal. Order matters: the moved key's slot is written
    -- BEFORE the removed key's slot is cleared, so the pos == last case (where
    -- they are the same key) still ends with the slot gone.
    local function detach(key)
        local pos = slot[key]
        if not pos then return end
        local last  = #keys
        local moved = keys[last]
        keys[pos]   = moved
        slot[moved] = pos
        keys[last]  = nil
        slot[key]   = nil
        rows[key]   = nil
    end

    local function evict(key, reason)
        local value = rows[key]
        if value == nil then return false end
        detach(key)
        stats.evicted = stats.evicted + 1
        if onEvict then onEvict(key, value, reason or "removed") end
        return true
    end

    -- Writing nil is a removal rather than an error: it lets a caller mirror
    -- plain table assignment without special-casing the clear.
    function ledger.set(key, value)
        if key == nil then return false end
        if value == nil then return evict(key, "nil-value") end
        if rows[key] == nil then
            keys[#keys + 1] = key
            slot[key] = #keys
        end
        rows[key] = value
        stats.set = stats.set + 1
        return true
    end

    -- Liveness is checked HERE, not only in the sweep. The sweep is a budgeted
    -- tidy that may not have reached this row yet, so a read must never hand
    -- back something the rule says is gone.
    function ledger.get(key)
        if key == nil then return nil end
        local value = rows[key]
        if value == nil then
            stats.misses = stats.misses + 1
            return nil
        end
        if live and not live(key, value) then
            stats.expired = stats.expired + 1
            evict(key, "dead-on-read")
            stats.misses = stats.misses + 1
            return nil
        end
        stats.hits = stats.hits + 1
        return value
    end

    -- Present at all, liveness NOT consulted. For the rare caller that needs
    -- to know a key was written without paying for (or triggering) eviction.
    function ledger.has(key)
        return key ~= nil and rows[key] ~= nil
    end

    function ledger.remove(key)
        if key == nil then return false end
        return evict(key, "removed")
    end

    function ledger.count()
        return #keys
    end

    -- Visit every LIVE row, dropping dead ones on the way past. Backwards, so
    -- the caller may safely set/remove from inside `visit` - see the header.
    -- Returns the number of rows actually visited.
    function ledger.forEach(visit)
        if not visit then return 0 end
        local seen = 0
        for i = #keys, 1, -1 do
            local key = keys[i]
            if key ~= nil then
                local value = rows[key]
                if value ~= nil then
                    if live and not live(key, value) then
                        stats.expired = stats.expired + 1
                        evict(key, "dead-on-visit")
                    else
                        seen = seen + 1
                        visit(key, value)
                    end
                end
            end
        end
        return seen
    end

    -- Bounded incremental housekeeping. Walks at most `limit` rows from where
    -- it left off, wrapping. Returns how many it evicted.
    --
    -- This is what catches rows nobody reads any more - a zombie whose chunk
    -- unloaded fires no death event, so a death hook alone would keep it
    -- forever. That gap is the whole reason the sweep exists.
    function ledger.sweep(limit)
        local total = #keys
        if total == 0 or not live then return 0 end
        local examine = tonumber(limit) or budget
        if examine > total then examine = total end
        local removed = 0
        for _ = 1, examine do
            local size = #keys
            if size == 0 then break end
            cursor = cursor + 1
            if cursor > size then cursor = 1 end
            local key = keys[cursor]
            local value = key ~= nil and rows[key] or nil
            stats.swept = stats.swept + 1
            if value ~= nil and not live(key, value) then
                stats.expired = stats.expired + 1
                evict(key, "swept")
                removed = removed + 1
                -- The swap moved an unexamined key into this slot, so step
                -- back and let the increment above land on it next time.
                cursor = cursor - 1
                if cursor < 0 then cursor = 0 end
            end
        end
        return removed
    end

    -- Drops every row WITHOUT calling onEvict: this is a session reset, not a
    -- lifecycle event, and firing per-row cleanup for a world that no longer
    -- exists is how stale handles get touched.
    function ledger.clear()
        rows, keys, slot = {}, {}, {}
        cursor = 0
    end

    RDLedger.ledgers[#RDLedger.ledgers + 1] = ledger
    return ledger
end

-- Housekeep every registered ledger once, on a budget each.
function RDLedger.sweepAll(limit)
    local removed = 0
    for i = 1, #RDLedger.ledgers do
        removed = removed + RDLedger.ledgers[i].sweep(limit)
    end
    return removed
end

-- One line per ledger. The observability half of CLAUDE.md section 14: a
-- lifetime bug shows up here as a count that only ever climbs.
function RDLedger.report()
    local out = {}
    for i = 1, #RDLedger.ledgers do
        local l = RDLedger.ledgers[i]
        local s = l.stats
        out[#out + 1] = string.format(
            "%s rows=%d set=%d hits=%d misses=%d evicted=%d expired=%d swept=%d",
            l.name, l.count(), s.set, s.hits, s.misses, s.evicted, s.expired, s.swept)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The heartbeat
-- ---------------------------------------------------------------------------
-- Shared/ loads on BOTH sides, and both sides own ledgers, so this is
-- deliberately unguarded by context. `Events` is presence-checked only because
-- fixtures load this file without one.
if Events and Events.OnTick and Events.OnTick.Add then
    local nextSweepAt = 0
    Events.OnTick.Add(function()
        local now = getTimestampMs()
        if now < nextSweepAt then return end
        nextSweepAt = now + SWEEP_INTERVAL_MS
        RDLedger.sweepAll()
    end)
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
