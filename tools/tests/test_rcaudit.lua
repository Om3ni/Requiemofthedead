-- test_rcaudit.lua - chronicle subject attribution for Reclaimation's ledger.
--
-- WHY THIS IS TESTABLE AT ALL: RCAudit.lua touches exactly one engine global at
-- file scope, the isServer() guard on line 8. RDLog, getFileWriter and os.date
-- are all reached from inside function bodies, so stubbing isServer is the
-- entire harness. Anything needing more than that belongs in the load-order
-- work, not here.
--
-- WHAT IT PINS: the subject handed to RDLog.chronicle decides two things that
-- fail silently when wrong - whether the record carries a life id (only an
-- object yields one) and whether RDIdentity mints a SteamID-bearing directory
-- (only an object yields one). A live RC.VEHICLE_CLAIM/RELEASE pair was
-- observed with the lifeId present on the claim and missing on the release.
-- The rule is: file under the claim HOLDER, but hand back the OBJECT whenever
-- the holder is the one standing there.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rcaudit.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCAudit.lua"

isServer = function() return true end   -- the only engine global RCAudit needs at load

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

-- Guarded rather than assumed: before the fix this was a file-local, so an
-- unguarded call would blow up with a stack trace instead of a readable verdict
-- when the suite is pointed at an older revision to confirm it catches anything.
if type(RCAudit) ~= "table" or type(RCAudit.chronicleSubject) ~= "function" then
    print("FAIL RCAudit.chronicleSubject is not exposed - subject attribution is untestable")
    print("RCAudit: 0 passed, 1 failed")
    os.exit(1)
end

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

-- Duck-typed stand-in: chronicleSubject only ever calls :getUsername(), which is
-- exactly why it can be exercised without the engine.
local function fakePlayer(name)
    return { getUsername = function() return name end }
end

local omen  = fakePlayer("Omen")
local staff = fakePlayer("StaffMember")

-- ---------------------------------------------------------------------------
-- The regression: holder releases their own claim
-- ---------------------------------------------------------------------------

-- This is the exact shape of the live RC.VEHICLE_RELEASE that dropped its lifeId.
eq("holder releasing own claim returns the OBJECT",
    RCAudit.chronicleSubject(omen, { owner = "Omen", vehicle = "Base.PickUpTruck" }), omen)

eq("holder under kv.user also returns the OBJECT",
    RCAudit.chronicleSubject(omen, { user = "Omen" }), omen)

-- ---------------------------------------------------------------------------
-- The cases that must KEEP the string - the subject is the holder, not the actor
-- ---------------------------------------------------------------------------

eq("staff releasing someone else's claim files under the owner",
    RCAudit.chronicleSubject(staff, { owner = "Omen" }), "Omen")

eq("EXPIRE has no player object at all",
    RCAudit.chronicleSubject(nil, { user = "Omen" }), "Omen")

eq("owner wins over user when both are present",
    RCAudit.chronicleSubject(staff, { owner = "Alice", user = "Bob" }), "Alice")

-- ---------------------------------------------------------------------------
-- Sentinels and degenerate input: "-" is the ledger's absent-value marker
-- ---------------------------------------------------------------------------

eq("owner sentinel falls through to user",
    RCAudit.chronicleSubject(staff, { owner = "-", user = "Omen" }), "Omen")

eq("both sentinels fall back to the actor",
    RCAudit.chronicleSubject(omen, { owner = "-", user = "-" }), omen)

eq("empty kv falls back to the actor",  RCAudit.chronicleSubject(omen, {}),  omen)
eq("nil kv falls back to the actor",    RCAudit.chronicleSubject(omen, nil), omen)
eq("string kv falls back to the actor", RCAudit.chronicleSubject(omen, "note"), omen)
eq("no actor and no kv yields nil",     RCAudit.chronicleSubject(nil, nil), nil)

-- A non-string owner must not blow up the comparison; it is coerced, not trusted.
eq("non-string owner is coerced", RCAudit.chronicleSubject(staff, { owner = 1234 }), "1234")

-- A player object whose getUsername throws must not take the ledger down with
-- it - the write still files under the holder rather than erroring.
local hostile = { getUsername = function() error("engine says no") end }
eq("throwing getUsername degrades to the holder string",
    RCAudit.chronicleSubject(hostile, { owner = "Omen" }), "Omen")

print(string.format("RCAudit: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
