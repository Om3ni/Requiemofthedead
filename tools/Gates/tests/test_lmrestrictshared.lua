-- LMRestrictShared fixture - owned Limes lookup results retain the normal
-- no-zone path while a configured field names the denying zone.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMRestrictShared.lua"
local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL LMRestrictShared: " .. message) end
end

local calls = {}
Limes = {
    getLocation = function(x, y)
        calls[#calls + 1] = { x = x, y = y }
        if x == 10 and y == 20 then return { name = "Sunstar", fields = { nobuilding = true } } end
        return nil
    end,
}
package.preload.LMCore = function() return {} end
LMRestrictShared = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
local denied, zone = LMRestrictShared.denied(10.9, 20.1, "nobuilding")
check(denied and zone == "Sunstar", "configured zone denies and names itself")
check(#calls == 1 and calls[1].x == 10 and calls[1].y == 20, "owned lookup receives floored coordinates directly")
denied, zone = LMRestrictShared.denied(30, 40, "nobuilding")
check(not denied and zone == nil, "no zone remains an ordinary allow result")

print(string.format("LMRestrictShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
