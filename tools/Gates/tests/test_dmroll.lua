-- DMRoll fixture - weighted selection, pinned exhaustively.
--
-- WHY THIS ONE IS WORTH WRITING PROPERLY: a random system cannot be checked by
-- looking at it. A roulette that quietly favours entry 1, or that can hand out
-- the same prize twice, produces results indistinguishable from luck until a
-- player has claimed it forty times and starts counting. The whole reason
-- DMRoll takes its random source as an argument is so this file can sweep the
-- ENTIRE draw domain and assert the exact boundary between one entry and the
-- next, rather than rolling a few times and hoping.
--
-- Engine-free by construction - the module touches no global.

local ROOT = arg[1] or "."
local SOURCE = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua/shared/DMRoll.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMRoll: " .. message) end
end

DMRoll = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local R = DMRoll

-- A scripted random source. Hands back the queued values in order, and
-- complains if the code under test asks for more draws than the test scripted -
-- an unasked-for draw is exactly the bug this file exists to catch.
--
-- It also RECORDS the pool size it was asked about, as the second return. That
-- is the only direct evidence that the pool shrinks between draws: the walk
-- skips drawn entries on its own, so a roll that keeps offering the full total
-- still SELECTS correctly and differs only in accepting draw values that then
-- fall off the end. Against a real ZombRand that is a roulette which errors
-- roughly one claim in ten; against an assertion on the return value alone it
-- is invisible, because both paths come back nil.
local function scripted(...)
    local queue = { ... }
    local asked = {}
    local i = 0
    local fn = function(total)
        i = i + 1
        asked[#asked + 1] = total
        if queue[i] == nil then error("rand called more times than scripted", 2) end
        return queue[i]
    end
    return fn, asked
end

local function accepts(entries, pick, why)
    local out, reason = R.validate(entries, pick)
    check(out ~= nil, (why or "table") .. " was refused: " .. tostring(reason))
end
local function refuses(entries, pick, why)
    local out, reason = R.validate(entries, pick)
    check(out == nil, "ACCEPTED " .. (why or "an invalid table"))
    check(out ~= nil or (type(reason) == "string" and reason ~= ""),
        "refused " .. (why or "") .. " with no reason given")
    return reason
end

-- ---- the shape of a table -------------------------------------------------

local TWO = { { weight = 10 }, { weight = 90 } }

accepts(TWO, 1, "a two-entry table")
accepts(TWO, 2, "picking both entries")
accepts({ { weight = 1 } }, 1, "a single-entry table")

refuses(nil, 1, "a nil table")
refuses("nope", 1, "a string table")
refuses({}, 1, "an empty table")
refuses({ { weight = 1 }, "loose" }, 1, "a non-table entry")

-- ---- weights --------------------------------------------------------------
-- Every one of these survives at least one of the obvious guards, which is why
-- each gets its own line rather than a single "bad weight" case.

refuses({ { weight = 0 } }, 1, "a zero weight")
refuses({ { weight = -5 } }, 1, "a negative weight")
refuses({ { weight = 0.5 } }, 1, "a fractional weight")
refuses({ { weight = "10" } }, 1, "a weight that is a string")
refuses({ { weight = nil } }, 1, "a missing weight")
refuses({ { weight = 0/0 } }, 1, "a NaN weight")
refuses({ { weight = 1/0 } }, 1, "an infinite weight")
refuses({ { weight = -1/0 } }, 1, "a negative infinite weight")
refuses({ { weight = R.WEIGHT_MAX + 1 } }, 1, "a weight over the ceiling")
accepts({ { weight = R.WEIGHT_MAX } }, 1, "a weight exactly at the ceiling")

-- The refusal has to say WHICH entry, or an admin with a twenty-row roulette
-- is hunting by hand.
local reason = refuses({ { weight = 1 }, { weight = 1 }, { weight = -3 } }, 1,
    "a bad weight in the third row")
check(type(reason) == "string" and reason:find("3", 1, true) ~= nil,
    "the refusal did not name the offending entry: " .. tostring(reason))

-- ---- how many to draw -----------------------------------------------------

refuses(TWO, 0, "picking zero")
refuses(TWO, -1, "picking a negative count")
refuses(TWO, 1.5, "picking a fractional count")
refuses(TWO, "1", "picking a count that is a string")
refuses(TWO, 3, "picking more entries than exist")
refuses(TWO, nil, "no pick count at all")

-- ---- the bound at the top -------------------------------------------------

local wide, tooWide = {}, {}
for i = 1, R.ENTRIES_MAX do wide[i] = { weight = 1 } end
for i = 1, R.ENTRIES_MAX + 1 do tooWide[i] = { weight = 1 } end
accepts(wide, 1, "a table exactly at the entry ceiling")
refuses(tooWide, 1, "a table one entry over the ceiling")

-- ---- the draw domain, swept exhaustively ----------------------------------
-- 10 and 90 out of 100. Every r in [0,100) must land on exactly one entry, and
-- the boundary must sit at 10 - not 9, not 11. An off-by-one here shifts the
-- odds of every roulette on the server by one part in the total.

local firstCount, secondCount = 0, 0
for r = 0, 99 do
    local out = R.roll(TWO, 1, scripted(r))
    check(out ~= nil and #out == 1, "r=" .. r .. " drew nothing")
    if out and out[1] == 1 then firstCount = firstCount + 1
    elseif out and out[1] == 2 then secondCount = secondCount + 1 end
end
check(firstCount == 10,
    "entry 1 (weight 10) won " .. firstCount .. " of 100 draws, expected 10")
check(secondCount == 90,
    "entry 2 (weight 90) won " .. secondCount .. " of 100 draws, expected 90")

-- The boundary itself, stated as its own assertion so a failure names it.
check(R.roll(TWO, 1, scripted(9))[1] == 1, "r=9 should be the last draw of entry 1")
check(R.roll(TWO, 1, scripted(10))[1] == 2, "r=10 should be the first draw of entry 2")

-- ---- draws are distinct, and the pool really shrinks -----------------------
-- Second draw sees a total of 90, not 100. If the drawn entry were left in the
-- pool the same r would be interpreted against the wrong total and could return
-- entry 1 twice - the failure that reads as "the roulette gave me two crowbars".

local both = R.roll(TWO, 2, scripted(0, 0))
check(both ~= nil and #both == 2, "picking 2 did not return 2 indices")
check(both and both[1] == 1 and both[2] == 2, "picking 2 repeated an entry")

-- The pool size offered to the random source, asserted directly. Entry 1
-- (weight 10) leaves after the first draw, so the second must be drawn against
-- 90. Asserting the RESULT cannot see this - the walk skips drawn entries by
-- itself, so an unshrunk total selects identically and merely accepts draws
-- that then fall off the end.
local rand2, asked = scripted(0, 0)
R.roll(TWO, 2, rand2)
check(#asked == 2, "expected exactly 2 draws, saw " .. #asked)
check(asked[1] == 100, "the first draw was offered " .. tostring(asked[1])
    .. ", expected the full 100")
check(asked[2] == 90, "the second draw was offered " .. tostring(asked[2])
    .. ", expected 90 once the weight-10 entry left the pool")

-- Scripted at 89: legal only if the second draw's domain is [0,90).
local shrunk = R.roll(TWO, 2, scripted(0, 89))
check(shrunk ~= nil and shrunk[2] == 2,
    "the second draw did not use the reduced total")

-- And the same value one higher must be refused, which proves the bound is 90
-- rather than still 100.
local over = R.roll(TWO, 2, scripted(0, 90))
check(over == nil, "the second draw accepted r=90 against a 90-weight pool")

-- Order is the order drawn, not sorted - a caller reporting "you won X, then Y"
-- depends on it.
local ordered = R.roll({ { weight = 1 }, { weight = 1 }, { weight = 1 } }, 3,
    scripted(2, 0, 0))
check(ordered ~= nil and ordered[1] == 3 and ordered[2] == 1 and ordered[3] == 2,
    "draw order was not preserved")

-- Drawing the whole table returns every index exactly once.
local all = R.roll(wide, R.ENTRIES_MAX, (function()
    local n = 0
    return function(total) n = n + 1; return 0 end
end)())
check(all ~= nil and #all == R.ENTRIES_MAX, "drawing the full table came up short")
local seen = {}
local dupe = false
for _, idx in ipairs(all or {}) do
    if seen[idx] then dupe = true end
    seen[idx] = true
end
check(not dupe, "drawing the full table repeated an index")

-- ---- a random source that breaks its contract fails LOUDLY ----------------
-- Left unchecked each of these returns fewer picks than asked for, which reads
-- as "the kit had less in it" rather than as a broken roll.

check(R.roll(TWO, 1, scripted(100)) == nil, "accepted r equal to the total")
check(R.roll(TWO, 1, scripted(101)) == nil, "accepted r above the total")
check(R.roll(TWO, 1, scripted(-1)) == nil, "accepted a negative r")
check(R.roll(TWO, 1, scripted(0/0)) == nil, "accepted a NaN r")
check(R.roll(TWO, 1, scripted("0")) == nil, "accepted a string r")
check(R.roll(TWO, 1, nil) == nil, "accepted a nil random source")
check(R.roll(TWO, 1, "ZombRand") == nil, "accepted a non-function random source")

local _, badReason = R.roll(TWO, 1, scripted(100))
check(type(badReason) == "string" and badReason ~= "",
    "a broken random source was refused with no reason")

-- roll re-validates, so a bad table cannot reach the walk by going in the
-- back door.
check(R.roll({}, 1, scripted(0)) == nil, "roll accepted an empty table")
check(R.roll(TWO, 3, scripted(0)) == nil, "roll accepted an impossible pick")

-- ---- odds, for an authoring surface to display ----------------------------

check(R.chanceOf(TWO, 1) == 0.10, "chanceOf misreported a weight-10 of 100")
check(R.chanceOf(TWO, 2) == 0.90, "chanceOf misreported a weight-90 of 100")
check(R.chanceOf(TWO, 3) == nil, "chanceOf answered for an index off the end")
check(R.chanceOf({}, 1) == nil, "chanceOf answered for an invalid table")

print(string.format("DMRoll: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
