-- test_mmroster.lua - deterministic Memoir online-player resolution.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/shared/MMRoster.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local alice = { getUsername = function() return "alice" end }
local bob = { getUsername = function() return "Bob" end }
local rows = { alice, false, bob }
local listCalls = 0
function getOnlinePlayers()
    listCalls = listCalls + 1
    return {
        size = function() return #rows end,
        get = function(_, index) return rows[index + 1] end,
    }
end

dofile(TARGET)

eq("finds an exact username", MMRoster.findOnline("alice"), alice)
eq("walk skips an empty player slot", MMRoster.findOnline("Bob"), bob)
eq("username matching remains case-sensitive", MMRoster.findOnline("bob"), nil)
eq("offline player returns nil", MMRoster.findOnline("carl"), nil)

local before = listCalls
eq("empty username is rejected", MMRoster.findOnline(""), nil)
eq("non-string username is rejected", MMRoster.findOnline(42), nil)
eq("invalid names do not scan the roster", listCalls, before)

rows = {}
eq("empty online roster returns nil", MMRoster.findOnline("alice"), nil)

print(string.format("MMRoster: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
