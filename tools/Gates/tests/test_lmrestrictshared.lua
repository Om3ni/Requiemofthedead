-- LMRestrictShared fixture - owned Limes lookup results retain the normal
-- no-zone path while a configured field names the denying zone.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMRestrictShared.lua"
local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL LMRestrictShared: " .. message) end
end

local calls = {}
local ZONES = {
    Sunstar = { name = "Sunstar", fields = { nobuilding = true } },
    Vault   = { name = "Vault",
                fields = { noplayers = true, noplayersPass = "Warden, teleport" } },
    Sealed  = { name = "Sealed", fields = { noplayers = true } },
}
Limes = {
    getLocation = function(x, y)
        calls[#calls + 1] = { x = x, y = y }
        if x == 10 and y == 20 then return ZONES.Sunstar end
        if x == 50 and y == 50 then return ZONES.Vault end
        if x == 70 and y == 70 then return ZONES.Sealed end
        return nil
    end,
    getZone = function(name) return ZONES[name] end,
}
-- RDAccess stub: the capability half of the pass check. The real one resolves
-- a Capability enum; here "teleport" is the one capability our fixture player
-- with a role carries.
RDAccess = { roleHas = function(player, cap)
    return player and player.caps and player.caps[cap] == true or false
end }
package.preload.LMCore   = function() return {} end
package.preload.RDAccess = function() return RDAccess end
LMRestrictShared = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
local denied, zone = LMRestrictShared.denied(10.9, 20.1, "nobuilding")
check(denied and zone == "Sunstar", "configured zone denies and names itself")
check(#calls == 1 and calls[1].x == 10 and calls[1].y == 20, "owned lookup receives floored coordinates directly")
denied, zone = LMRestrictShared.denied(30, 40, "nobuilding")
check(not denied and zone == nil, "no zone remains an ordinary allow result")

-- The pass list: role name (case-insensitive), capability via RDAccess,
-- default deny on everything else.
local warden   = { getRole = function() return { getName = function() return "WARDEN" end } end }
local capman   = { getRole = function() return { getName = function() return "Helper" end } end,
                   caps = { teleport = true } }
local nobody   = { getRole = function() return { getName = function() return "Player" end } end }
local roleless = {}

check(LMRestrictShared.passes(warden, "Warden, teleport"),
    "a role name matches case-insensitively")
check(LMRestrictShared.passes(capman, "Warden, teleport"),
    "a role capability matches through RDAccess")
check(not LMRestrictShared.passes(nobody, "Warden, teleport"),
    "no matching token is a deny")
check(not LMRestrictShared.passes(roleless, "Warden, teleport"),
    "a roleless player is a deny")
check(not LMRestrictShared.passes(warden, ""),
    "an empty list passes nobody")
check(not LMRestrictShared.passes(nil, "Warden"),
    "no player is a deny")

denied = LMRestrictShared.deniedFor(warden, 50, 50, "noplayers")
check(not denied, "a pass-holder walks through noplayers")
denied, zone = LMRestrictShared.deniedFor(nobody, 50, 50, "noplayers")
check(denied and zone == "Vault", "everyone else is still turned back, by name")
denied, zone = LMRestrictShared.deniedFor(warden, 70, 70, "noplayers")
check(denied and zone == "Sealed", "a zone with no pass list admits nobody")
denied = LMRestrictShared.deniedFor(warden, 10, 20, "nobuilding")
check(denied, "action flags carry no exemption - passing the fence is not sledging rights")

print(string.format("LMRestrictShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
