-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMRoll - weighted selection without replacement, and nothing else.
--
-- Given a list of entries carrying weights and a number to draw, return WHICH
-- ONES. It does not know what an entry contains, who is drawing, or what the
-- result will be used for; a caller maps indices back onto its own data. That
-- ignorance is the point - the kit schema, a loot table and a "one of these
-- zombies has the key" pick are the same problem, and this is the one copy.
--
-- THE RANDOM SOURCE IS INJECTED, and that is the whole reason this file is
-- separate from the code that rolls. `ZombRand` is an engine global, so any
-- module calling it directly is untestable by construction: run-tests has no
-- engine, and a system whose output is random is exactly the kind you cannot
-- eyeball on a live server. With `rand` as an argument every outcome is pinned
-- in a fixture, including the ones a real roll would produce once in ten
-- thousand claims. Production passes ZombRand; the tests pass a script.
--
-- THE CONTRACT `rand` MUST MEET: rand(n) returns an integer in [0, n).
-- That is ZombRand's, verified: LuaManager.java:5780-5789 forwards to
-- RandLua.INSTANCE.Next((long)max). Note ZombRand(0) returns 0 rather than
-- erroring (:5782-5784) - harmless here because validate() refuses an empty
-- table, so a total of zero is unreachable.
--
-- WEIGHTS ARE POSITIVE INTEGERS. Two reasons, both load-bearing:
--   * the cumulative walk compares an integer draw against an integer running
--     total. Float weights make the comparison depend on accumulation order,
--     so the same table could pick differently after an unrelated edit.
--   * an author writing "10 and 90" means integers. Admitting 0.15 buys a
--     precision nobody asked for and a rounding bug nobody can see.
-- Zero is refused rather than treated as "never": an entry that can never be
-- drawn is a mistake, and the fix is to delete it, not to leave it looking
-- live. Negative and non-finite are refused for the same reason RDVars refuses
-- them - they survive the obvious guards and corrupt the total silently.
--
-- DRAWS ARE DISTINCT. "Pick 2 of these 5" means two different ones; a roulette
-- that can hand you the same prize twice is a bug report, not a feature. That
-- makes pick > #entries impossible, which validate() refuses up front rather
-- than letting roll() quietly return short.
--
-- ENGINE-FREE. Touches no global, which is what lets the fixture run it
-- directly.

DMRoll = DMRoll or {}

-- A roulette wider than this is not a design, it is a paste. The bound also
-- keeps one authored table off the wire in pieces.
DMRoll.ENTRIES_MAX = 64

-- Weights are relative, so the ceiling only has to stop a value that would
-- swamp every sibling into unreachability. A million-to-one is already past
-- the point where the long odds are indistinguishable from never.
DMRoll.WEIGHT_MAX = 1000000

-- ---------------------------------------------------------------------------
-- Validation
--
-- Returns (true) or (nil, reason). Reasons are shown to an admin verbatim, so
-- they name the entry position and the value - "entry 3" is findable in a form,
-- "invalid weight" is not.
-- ---------------------------------------------------------------------------

local function badWeight(w)
    if type(w) ~= "number" then
        return "must be a number, got " .. type(w) .. " (" .. tostring(w) .. ")"
    end
    -- NaN first: it compares false against every bound below, so a later test
    -- would let it through while appearing to have checked it.
    if w ~= w then return "cannot be NaN" end
    if w - w ~= 0 then return "cannot be infinite" end
    if w % 1 ~= 0 then
        return "must be a whole number, got " .. tostring(w)
    end
    if w <= 0 then
        return "must be greater than zero - an entry that can never be drawn "
            .. "should be deleted, not left at " .. tostring(w)
    end
    if w > DMRoll.WEIGHT_MAX then
        return "cannot exceed " .. DMRoll.WEIGHT_MAX
    end
    return nil
end

function DMRoll.validate(entries, pick)
    if type(entries) ~= "table" then
        return nil, "a roulette needs a list of entries, got " .. type(entries)
    end

    local n = #entries
    if n == 0 then
        return nil, "a roulette needs at least one entry"
    end
    if n > DMRoll.ENTRIES_MAX then
        return nil, "a roulette cannot hold more than " .. DMRoll.ENTRIES_MAX
            .. " entries, got " .. n
    end

    for i = 1, n do
        local e = entries[i]
        if type(e) ~= "table" then
            return nil, "entry " .. i .. " must be a table, got " .. type(e)
        end
        local why = badWeight(e.weight)
        if why then
            return nil, "entry " .. i .. "'s weight " .. why
        end
    end

    if type(pick) ~= "number" or pick ~= pick or pick % 1 ~= 0 or pick < 1 then
        return nil, "pick must be a whole number of at least 1, got "
            .. tostring(pick)
    end
    if pick > n then
        return nil, "cannot pick " .. pick .. " distinct entries from " .. n
            .. " - draws are never repeated"
    end

    return true
end

-- ---------------------------------------------------------------------------
-- The draw
--
-- Returns a list of INDICES into `entries`, in the order they were drawn, or
-- (nil, reason).
--
-- Indices rather than the entries themselves because the caller owns what an
-- entry means, and because a recorded result should be the smallest true thing
-- - a ledger storing whole grant tables would carry a stale copy of a
-- definition that has since been edited.
-- ---------------------------------------------------------------------------

function DMRoll.roll(entries, pick, rand)
    local ok, why = DMRoll.validate(entries, pick)
    if not ok then return nil, why end
    if type(rand) ~= "function" then
        return nil, "roll needs a random source, got " .. type(rand)
    end

    local taken, out = {}, {}

    for _ = 1, pick do
        -- Recomputed per draw because the drawn entry leaves the pool. Cheap:
        -- ENTRIES_MAX is 64 and pick is bounded by it.
        local total = 0
        for i = 1, #entries do
            if not taken[i] then total = total + entries[i].weight end
        end

        local r = rand(total)

        -- A rand that breaks its contract must fail here and say so. Left
        -- unchecked, the walk below simply finds no entry and roll() returns
        -- fewer picks than asked for - a short result that reads as "the kit
        -- had less in it" rather than as a broken random source.
        if type(r) ~= "number" or r ~= r or r < 0 or r >= total then
            return nil, "the random source returned " .. tostring(r)
                .. ", which is outside [0, " .. total .. ")"
        end

        local acc, chosen = 0, nil
        for i = 1, #entries do
            if not taken[i] then
                acc = acc + entries[i].weight
                if r < acc then chosen = i; break end
            end
        end

        -- Unreachable while the bound above holds; kept because "cannot happen"
        -- is how a silent short result gets shipped.
        if not chosen then
            return nil, "the draw fell through every entry at r=" .. tostring(r)
        end

        taken[chosen] = true
        out[#out + 1] = chosen
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Questions a caller asks without drawing
-- ---------------------------------------------------------------------------

-- The odds of one entry on the FIRST draw, as a fraction of 1. Later draws
-- depend on what left the pool, so this deliberately answers only about the
-- first - an authoring UI showing "10%" next to entry 3 is telling the truth
-- about a single-pick roulette and about the opening odds of any other.
function DMRoll.chanceOf(entries, index)
    local ok = DMRoll.validate(entries, 1)
    if not ok then return nil end
    local e = entries[index]
    if type(e) ~= "table" then return nil end
    local total = 0
    for i = 1, #entries do total = total + entries[i].weight end
    return e.weight / total
end

return DMRoll

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
