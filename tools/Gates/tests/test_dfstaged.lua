-- DFStaged fixture - edits held back from a live registry.
--
-- WHY IT HAS ITS OWN FILE. This was written twice, once per Admin sub-tab, and
-- check-helpers caught the second copy the hour it appeared. Now that it is one
-- module it is also one place to get the central rule wrong, and that rule is
-- not obvious:
--
--   AN EDIT BACK TO THE CURRENT VALUE IS NOT AN EDIT.
--
-- Get it wrong and "3 changes staged" counts changes that change nothing. On
-- the sandbox side that is a wasted whole-set push; on the server side it is a
-- line in the admin log attributing a change to an admin who made none. Neither
-- looks like a bug from the outside.

local ROOT = arg[1] or "."
local SRC = ROOT
    .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin/DFStaged.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFStaged: " .. message) end
end

function isServer() return false end

DFStaged = nil
local ok, err = pcall(dofile, SRC)
check(ok, "module loads: " .. tostring(err))

-- A registry that can move under us, which is the whole point: the sandbox side
-- re-reads the engine every call so another admin's change is picked up.
local registry = { PVP = true, Rate = 1, Name = "old", Mode = 2 }
local reads = 0
local function live(name) reads = reads + 1; return registry[name] end

local s = DFStaged.new(live)

check(s:count() == 0, "a new store is not empty")
check(s:get("PVP") == true, "get did not fall through to the registry")
check(s:has("PVP") == false, "an untouched name reads as staged")

s:set("PVP", false)
check(s:has("PVP") == true, "a real edit was not staged")
check(s:get("PVP") == false, "get did not prefer the staged value")
check(s:count() == 1, "count did not see the edit")

-- The rule.
s:set("PVP", true)
check(s:count() == 0,
    "an edit back to the CURRENT value stayed staged - Apply would then write "
    .. "an option the admin never decided to write, and the count would report "
    .. "changes that change nothing")
check(s:get("PVP") == true, "clearing the edit did not fall back to the registry")

-- Compared as STRINGS, because a dial hands back whatever its kind stores and
-- the registry hands back its own shape for the same option. 2 and "2" are
-- routinely the same value arriving by two routes.
s:set("Mode", "2")
check(s:count() == 0,
    "'2' and 2 were treated as different values - every enum and number dial "
    .. "would stage a spurious edit the moment it was touched")
s:set("Rate", 1.5)
check(s:has("Rate") == true, "a genuine numeric change was dropped")

-- The registry moving under a staged edit does NOT retroactively clear it: the
-- comparison happens at set() time, which is when the admin made the decision.
registry.Rate = 1.5
check(s:has("Rate") == true, "a staged edit vanished because the registry caught up")

-- countIn: the nav needs per-page counts so an edit on a page the admin is not
-- looking at is still visible.
s:set("Name", "new")
check(s:countIn({ "Rate", "Name" }) == 2, "countIn miscounted")
check(s:countIn({ "PVP" }) == 0, "countIn counted an unstaged name")
check(s:countIn({}) == 0, "countIn of nothing was not zero")
check(s:countIn(nil) == 0, "countIn(nil) faulted or miscounted")

-- names() is sorted: both callers walk it to act on a live server, and two
-- applies of the same edits should hit the wire and the admin log in the same
-- order.
local names = s:names()
check(#names == 2, "names() returned " .. #names .. " entries")
check(names[1] == "Name" and names[2] == "Rate",
    "names() is not sorted: " .. table.concat(names, ", "))

s:clear()
check(s:count() == 0, "clear left edits behind")
check(s:get("Name") == "new" or s:get("Name") == registry.Name,
    "get after clear did not read the registry")

-- Reads go to the registry every time rather than being cached at construction,
-- which is what lets another admin's change appear on the panel.
local before = reads
s:get("PVP"); s:get("PVP")
check(reads == before + 2,
    "the live value was cached - a change made elsewhere would never appear")

print(string.format("DFStaged: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
