-- RDLedger fixture - keyed rows with an explicit lifetime.
--
-- WHY THIS FILE EXISTS. RDLedger replaces the weak-table idiom, which does not
-- work in Kahlua at all (J2SEPlatform.java:41-43 hands back a LinkedHashMap and
-- nothing reads `__mode`). That means this file is now the ONLY thing standing
-- between the suite and a silent leak - and it runs under real Lua 5.1, where
-- the broken idiom would have looked fine. So the assertions below are
-- deliberately about lifetime, not about storage.
--
-- The three that would actually bite in game:
--   1. SWAP-REMOVE CORRECTNESS. Removal is swap-with-last; a bug there loses
--      an unrelated row silently and nothing ever reports it.
--   2. MUTATION DURING ITERATION. "Visit each row, drop the dead" is the most
--      common caller shape. forEach walks backwards precisely so that is safe.
--   3. THE SWEEP CURSOR. It must eventually visit every row and must not skip
--      the row that a swap just moved under it.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLedger.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RDLedger: " .. message)
    end
end

-- No Events: the heartbeat must be optional, because fixtures and any
-- non-game consumer load this file without one. If the file starts REQUIRING
-- Events, this fixture fails at load rather than in game.
local nowMs = 1000
function getTimestampMs() return nowMs end

RDLedger = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads without an Events global: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- Naming is mandatory
-- ---------------------------------------------------------------------------
-- A ledger that cannot say what it holds is useless in a report, which is the
-- only place a lifetime bug becomes visible.
check(not pcall(RDLedger.new, {}), "an unnamed ledger is refused")
check(not pcall(RDLedger.new, nil), "so is no options table at all")

-- ---------------------------------------------------------------------------
-- Basic storage
-- ---------------------------------------------------------------------------
local plain = RDLedger.new({ name = "plain" })
check(plain.count() == 0, "a new ledger is empty")
plain.set("a", 1)
plain.set("b", 2)
check(plain.get("a") == 1 and plain.get("b") == 2, "rows read back")
check(plain.count() == 2, "and are counted")

plain.set("a", 10)
check(plain.get("a") == 10, "overwriting updates in place")
check(plain.count() == 2, "without adding a second row for the same key")

check(plain.get("nope") == nil, "a missing key is nil, not an error")
check(plain.get(nil) == nil, "a nil key is nil, not an error")
check(plain.set(nil, 1) == false, "and cannot be written")

-- Writing nil removes, so callers can mirror plain table assignment.
plain.set("b", nil)
check(plain.get("b") == nil and plain.count() == 1, "writing nil removes the row")

-- has() reports presence without consulting liveness or evicting.
check(plain.has("a") == true and plain.has("b") == false, "has reports presence")

-- ---------------------------------------------------------------------------
-- SWAP-REMOVE CORRECTNESS
-- ---------------------------------------------------------------------------
-- Removal moves the last key into the hole. Removing the FIRST, MIDDLE and
-- LAST positions must each leave every other row intact - a mistake here
-- silently loses a row that nobody asked to remove.
local swap = RDLedger.new({ name = "swap" })
for i = 1, 5 do swap.set(i, i * 100) end

swap.remove(1)                      -- first
check(swap.count() == 4, "removing the first row leaves four")
swap.remove(3)                      -- middle
check(swap.count() == 3, "removing a middle row leaves three")
local survivors = {}
swap.forEach(function(k, v) survivors[k] = v end)
check(survivors[2] == 200 and survivors[4] == 400 and survivors[5] == 500,
    "exactly the untouched rows survive")
check(survivors[1] == nil and survivors[3] == nil, "and the removed ones are gone")

-- Removing the last remaining row must empty cleanly rather than corrupt.
swap.remove(2); swap.remove(4); swap.remove(5)
check(swap.count() == 0, "removing every row empties the ledger")
check(swap.forEach(function() end) == 0, "and iteration then visits nothing")
swap.set("fresh", 1)
check(swap.count() == 1 and swap.get("fresh") == 1,
    "an emptied ledger still accepts new rows - the arrays were not corrupted")

check(swap.remove("absent") == false, "removing an absent key reports false")

-- ---------------------------------------------------------------------------
-- Liveness
-- ---------------------------------------------------------------------------
local alive = {}
local evictions = {}
local lived = RDLedger.new({
    name = "lived",
    live = function(_, v) return alive[v] == true end,
    onEvict = function(k, v, reason) evictions[#evictions + 1] = { k, v, reason } end,
})

alive["x"] = true
lived.set(1, "x")
check(lived.get(1) == "x", "a live row reads back")

-- The rule is consulted ON READ, not only by the sweep: the sweep is budgeted
-- and may not have reached this row, and a read must never hand back a corpse.
alive["x"] = false
check(lived.get(1) == nil, "a row that has died is not returned")
check(lived.count() == 0, "and is evicted immediately")
check(#evictions == 1 and evictions[1][3] == "dead-on-read",
    "onEvict fires with the reason")

-- ---------------------------------------------------------------------------
-- MUTATION DURING ITERATION
-- ---------------------------------------------------------------------------
-- forEach walks backwards so a callback may safely remove rows. If this
-- regresses, iteration silently skips rows - the failure mode that would look
-- like "the feature just doesn't fire sometimes".
local iter = RDLedger.new({ name = "iter" })
for i = 1, 6 do iter.set(i, i) end
local visited = {}
iter.forEach(function(k)
    visited[#visited + 1] = k
    if k % 2 == 0 then iter.remove(k) end
end)
check(#visited == 6, "every row is visited exactly once despite removals: " .. #visited)
check(iter.count() == 3, "and the removals took effect: " .. iter.count())

-- Dead rows are dropped BY forEach, so a caller never sees one.
local liveSet = { a = true, b = false, c = true }
local mixed = RDLedger.new({ name = "mixed", live = function(k) return liveSet[k] end })
mixed.set("a", 1); mixed.set("b", 2); mixed.set("c", 3)
local seen = {}
local count = mixed.forEach(function(k) seen[k] = true end)
check(count == 2, "forEach visits only live rows: " .. count)
check(seen["b"] == nil, "the dead row is not handed to the caller")
check(mixed.count() == 2, "and is evicted on the way past")

-- ---------------------------------------------------------------------------
-- THE SWEEP CURSOR
-- ---------------------------------------------------------------------------
-- The sweep is the only thing that catches rows nobody reads - a zombie whose
-- chunk unloaded fires no death event. It must therefore eventually reach
-- EVERY row, not just the ones near the start.
local sweepLive = {}
local swept = RDLedger.new({
    name = "swept",
    live = function(k) return sweepLive[k] == true end,
    sweepBudget = 2,
})
for i = 1, 10 do sweepLive[i] = true; swept.set(i, i) end
check(swept.sweep() == 0, "a fully live ledger sweeps nothing")

-- Kill the LAST row specifically: a cursor that never wraps would never see it.
sweepLive[10] = false
local rounds, removed = 0, 0
while removed == 0 and rounds < 40 do
    removed = removed + swept.sweep()
    rounds = rounds + 1
end
check(removed == 1, "the sweep eventually reaches a row far from the cursor")
check(swept.count() == 9, "and evicts it")

-- Kill everything: the sweep must converge rather than stall on the swap.
for i = 1, 10 do sweepLive[i] = false end
rounds = 0
while swept.count() > 0 and rounds < 200 do
    swept.sweep()
    rounds = rounds + 1
end
check(swept.count() == 0, "the sweep converges to empty: " .. swept.count() .. " left")
check(rounds < 200, "and does so without stalling on the swap-remove")

-- A ledger with no liveness rule is a pure cache; sweeping must not drop rows.
local cacheOnly = RDLedger.new({ name = "cacheOnly" })
cacheOnly.set("k", "v")
check(cacheOnly.sweep() == 0 and cacheOnly.count() == 1,
    "a ledger with no rule keeps its rows through a sweep")

-- ---------------------------------------------------------------------------
-- Registry and reporting
-- ---------------------------------------------------------------------------
check(#RDLedger.ledgers >= 6, "every created ledger is registered for housekeeping")
local before = swept.count()
RDLedger.sweepAll()
check(swept.count() <= before, "sweepAll runs across the suite without raising")

local report = RDLedger.report()
check(#report == #RDLedger.ledgers, "report emits one line per ledger")
check(report[1]:find("rows=", 1, true) ~= nil, "and the line carries the row count")

-- clear() is a session reset, not a lifecycle event: firing per-row cleanup
-- for a world that no longer exists is how stale handles get touched.
local cleared = {}
local resettable = RDLedger.new({
    name = "resettable",
    onEvict = function(k) cleared[#cleared + 1] = k end,
})
resettable.set("a", 1); resettable.set("b", 2)
resettable.clear()
check(resettable.count() == 0, "clear empties the ledger")
check(#cleared == 0, "WITHOUT firing onEvict - clear is a reset, not an eviction")
resettable.set("c", 3)
check(resettable.count() == 1 and resettable.get("c") == 3,
    "and the ledger is usable again afterwards")

print(string.format("RDLedger: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
