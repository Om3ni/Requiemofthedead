-- RQCastBar fixture - external lifecycle callbacks cannot strand bar cleanup.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQCastBar.lua"
local OVERLAY = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/RDWorldOverlay.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL RQCastBar: " .. message) end
end

local callbacks = { tick = nil, gameStart = nil }
Events = {
    OnTick = { Add = function(fn) callbacks.tick = fn end },
    OnGameStart = { Add = function(fn) callbacks.gameStart = fn end },
}
-- derive implements the REAL vanilla semantics (ISBaseObject.lua:9-16) rather
-- than returning a bare table, because RQCastBar's element is now two links
-- down a chain - RQCastBarHUD -> RDWorldOverlay -> ISUIElement - and a stub
-- that flattened it would stop proving the chain resolves at all.
ISUIElement = {
    derive = function(self, type_)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o.Type = type_
        o.SuperType = self
        return o
    end,
    new = function(_, x, y, w, h)
        return {
            initialise = function() end,
            setWantKeyEvents = function() end,
            addToUIManager = function() end,
            setVisible = function() end,
            removeFromUIManager = function() end,
        }
    end,
}

-- The engine resolves `require` against every mod's lua tree; stock Lua 5.1
-- cannot, and the paths here are absolute anyway. Both requires RQCastBar makes
-- are satisfied before it loads: ISUI/ISUIElement by the stub above, and
-- RDWorldOverlay by loading the real Core file below.
local required = {}
require = function(name) required[name] = true end

function isServer() return false end
dofile(OVERLAY)
RQConfig = { get = function() return { showCastBarText = false } end }
function getTimestampMs() return 1000 end

RQCastBar = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))
check(type(callbacks.tick) == "function", "registers its tick lifecycle")
check(required["RDWorldOverlay"] == true,
    "RQCastBar no longer requires RDWorldOverlay - it dereferences it at file "
    .. "scope, and the client walk loads LR* and RQ* files on either side of "
    .. "RD*, so the require is what makes the order a contract rather than luck")
check(type(RDWorldOverlay) == "table", "RDWorldOverlay did not load")

local realPrint = print
local warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
local cancelled = RQCastBar.create({ duration = 1000, color = {}, onCancel = function() error("cancel fault") end })
RQCastBar.cancel(cancelled)
print = realPrint
check(not RQCastBar.isActive(cancelled), "failed cancellation callback cannot strand its bar")
check(#warnings == 1 and warnings[1]:find("cancel callback failed", 1, true)
    and warnings[1]:find("cancel fault", 1, true), "failed cancellation is reported once")

local completed = 0
local bad = RQCastBar.create({ startTime = 0, duration = 1, color = {}, onComplete = function() error("complete fault") end })
local good = RQCastBar.create({ startTime = 0, duration = 1, color = {}, onComplete = function() completed = completed + 1 end })
warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end
callbacks.tick()
print = realPrint
check(not RQCastBar.isActive(bad) and not RQCastBar.isActive(good),
    "a failed completion callback cannot strand any completed bar")
check(completed == 1, "a failed bar callback does not block an independent bar")
check(#warnings == 1 and warnings[1]:find("complete callback failed", 1, true),
    "failed completion is reported once")

print(string.format("RQCastBar: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

