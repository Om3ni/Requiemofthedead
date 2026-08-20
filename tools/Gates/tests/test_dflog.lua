-- DFLog fixture - report context reads its stable engine singletons directly,
-- preserving operator-facing build, mode, checksum, clock, and error-owner data.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFLog.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL DFLog: " .. message)
    end
end

function isServer() return false end
function isClient() return true end
function getSteamModeActive() return true end
function getCore() return { getVersion = function() return "42.20.2 test" end } end
function getServerOptions()
    return { getBoolean = function(_, key) if key == "DoLuaChecksum" then return true end end }
end

Calendar = {
    YEAR = 1, MONTH = 2, DAY_OF_MONTH = 3,
    HOUR_OF_DAY = 4, MINUTE = 5, SECOND = 6,
}
local fields = { [1] = 2026, [2] = 7, [3] = 18, [4] = 9, [5] = 4, [6] = 5 }
function Calendar.getInstance()
    return { get = function(_, field) return fields[field] end }
end

PauseBuggedModList = { Zeta = true, Alpha = true }
Events = { OnServerCommand = { Add = function() end } }

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local header = DFLog.contextHeader()
check(header:find("Version: 42.20.2 test %(Steam%)") ~= nil,
    "context includes the direct Core version and Steam state")
check(header:find("Mode: MULTIPLAYER", 1, true) ~= nil
    and header:find("Lua Checksum: true", 1, true) ~= nil,
    "context includes direct client mode and checksum reads")
check(header:find("Captured: 2026%-08%-18 09:04:05") ~= nil,
    "context formats the direct Calendar fields")
check(header:find("Alpha, Zeta", 1, true) ~= nil,
    "context preserves sorted engine error-owner names")

local entry = DFLog.push{ source = "Test", text = "normal push" }
check(entry.time == "09:04:05" and entry.stamp == "2026-08-18 09:04:05",
    "normal log pushes use the same direct clock contract")

print(string.format("DFLog: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
