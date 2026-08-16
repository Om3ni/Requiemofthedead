-- test_lrdanger.lua - healthy danger-poll contract.
--
-- The controller runs inside OnTick, whose event dispatcher already protects
-- and logs each listener (Event.java:53-63). This pins the normal direct update
-- path rather than adding a second, error-swallowing boundary around it.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLastRites"
             .. "/42/media/lua/client/LRDanger.lua"

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

local tick
Events = {
    OnTick = { Add = function(fn) tick = fn end },
    OnGameStart = { Add = function() end },
}

local now = 500
getTimestampMs = function() return now end

local clears, ensures = 0, 0
LRDangerHUD = {
    badges = {},
    ensure = function() ensures = ensures + 1 end,
}
LRDangerMoodle = { clear = function() clears = clears + 1 end }
LRPrefs = { get = function(_, fallback) return fallback end }
LRDangerQuips = { pick = function() end }
MoodleType = { HYPOTHERMIA = 1, HYPERTHERMIA = 2, BLEEDING = 3 }

local player = {
    getMoodles = function()
        return { getMoodleLevel = function() return 0 end }
    end,
}
getPlayer = function() return player end

dofile(SRC)
eq("registers an OnTick listener", type(tick), "function")

tick()
eq("ensures the HUD before its direct update", ensures, 1)
eq("clears all inactive signals", clears, 3)
eq("leaves no badges when every moodle is inactive", #LRDangerHUD.badges, 0)

now = 600
tick()
eq("honors the poll interval", ensures, 1)

print(string.format("Last Rites danger: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
