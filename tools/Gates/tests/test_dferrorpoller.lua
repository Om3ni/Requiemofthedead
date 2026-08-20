-- DFErrorPoller fixture - stable debugger snapshots are read directly, while
-- attribution, server-folder detection, deduplication, and new-event discovery
-- retain their observable contracts.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFErrorPoller.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL DFErrorPoller: " .. message)
    end
end

function isServer() return false end
function isClient() return true end

local tickListener
Events = { OnTickEvenPaused = { Add = function(fn) tickListener = fn end } }

local loaded = {
    "C:/mods/Test/media/lua/server/Boom.lua",
    "C:/mods/Test/media/lua/client/ClientOnly.lua",
}
function getLoadedLuaCount() return #loaded end
function getLoadedLua(index) return loaded[index + 1] end

local entries = { "ERROR (MOD:Test Mod) Boom.lua:42 bad thing" }
local errors = {
    size = function() return #entries end,
    get = function(_, index) return entries[index + 1] end,
}
function getLuaDebuggerErrors() return errors end

local pushed = {}
DFLog = { push = function(entry) pushed[#pushed + 1] = entry end }

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(tickListener) == "function", "registers its paused-tick listener")

DFErrorPoller.pollNow()
check(#pushed == 1 and pushed[1].source == "Mod:Test Mod",
    "a direct snapshot read preserves MOD attribution")
check(pushed[1] and pushed[1].text:find("[SERVER-FOLDER]", 1, true) == 1,
    "a server-only loaded basename is visibly tagged")

DFErrorPoller.pollNow()
check(#pushed == 1, "the unchanged tail is not pushed twice")

entries[2] = "WARN ClientOnly.lua:7 another thing"
DFErrorPoller.pollNow()
check(#pushed == 2 and pushed[2].level == "warn" and pushed[2].source == "Error",
    "a later direct snapshot read discovers and classifies a new event")

print(string.format("DFErrorPoller: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
