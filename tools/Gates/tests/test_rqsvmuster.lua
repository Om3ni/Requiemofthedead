-- RQSvMuster fixture - who musters, the payload, and the once-a-second gate
-- per special.
--
-- The near-players send is RQSvShared's and has its own assertions there;
-- this fixture records the call and answers with a recipient count.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvMuster.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQSvMuster: " .. message) end
end

function isServer() return true end

-- ---------------------------------------------------------------------------
-- Engine and sibling surface
-- ---------------------------------------------------------------------------
local sent, logged = {}, {}
local nearCount = 2
RQSvShared = {
    getSvConfig = function() return { juggernautBuffRadius = 8 } end,
    sendNear = function(zombie, cmd, args)
        sent[#sent + 1] = { zombie = zombie, cmd = cmd, args = args }
        return nearCount
    end,
    -- The real cadence gate, byte for byte (RQSvShared.lua): a first call is
    -- due, a call inside the interval is not and does not restamp.
    due = function(state, key, intervalMs, now)
        if not state then return true end
        local last = state[key]
        if last and (now - last) < intervalMs then return false end
        state[key] = now
        return true
    end,
}
RQDirgeLog = { write = function(zType, msg) logged[#logged + 1] = { zType = zType, msg = msg } end }
RQCommon = { MODULE = "RFTDDirge" }

function require(name)
    if name == "RQCommon" or name == "RQDirgeLog" or name == "RQSvShared" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvMuster = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(RQSvMuster.COMMAND == "escortMuster", "the wire command is named once, here")

local function zombie(oid)
    return { getOnlineID = function() return oid end }
end
local attacker = { getOnlineID = function() return 5 end }
local function hit(z, zType, now)
    return RQSvMuster.onAttacked({ zombie = z, attacker = attacker, zType = zType, now = now })
end

-- ---------------------------------------------------------------------------
-- Who musters
-- ---------------------------------------------------------------------------
local jugg = zombie(10)
check(hit(jugg, "Juggernaut", 1000) == true, "a Juggernaut hit musters")
check(#sent == 1 and sent[1].zombie == jugg and sent[1].cmd == "escortMuster",
    "one targeted send, around the special that was hit, on the muster command")
check(sent[1].args.onlineID == 10 and sent[1].args.attackerID == 5 and sent[1].args.radius == 8,
    "the payload names the special, the attacker and the configured aura radius")
check(RQSvMuster.stats.mustered == 1 and RQSvMuster.stats.recipients == 2,
    "counters record the muster and how many were told")
check(#logged == 1 and logged[1].zType == "Juggernaut", "one diagnostic line, attributed to the type")

local boss = zombie(11)
check(hit(boss, "Boss", 1000) == true and #sent == 2, "a Boss hit musters")

for _, zType in ipairs({ "Scavenger", "Screamer", "EMP", "Glutton" }) do
    check(hit(zombie(20), zType, 1000) == false, zType .. " does not muster")
end
check(#sent == 2 and RQSvMuster.stats.refused.type == 4, "the four are refused by name and send nothing")

check(hit(zombie(-1), "Juggernaut", 1000) == false and RQSvMuster.stats.refused["no-id"] == 1,
    "a special with no online id cannot be named to a client and is refused")

-- ---------------------------------------------------------------------------
-- Once a second, per special
-- ---------------------------------------------------------------------------
check(hit(jugg, "Juggernaut", 1500) == false, "a second hit inside the second is throttled")
check(RQSvMuster.stats.throttled == 1 and #sent == 2, "and counted, and sends nothing")
check(hit(jugg, "Juggernaut", 1999) == false, "the throttle does not slide - the stamp is the first muster")
check(hit(jugg, "Juggernaut", 2000) == true and #sent == 3, "at the interval it musters again")

-- Independent per special: the Boss's gate is its own.
check(hit(boss, "Boss", 1500) == false, "the Boss is still inside its own second")
check(hit(zombie(12), "Boss", 1500) == true, "a different Boss hit for the first time musters at once")

-- A stamp a minute old is dropped, and the next hit is a first hit again.
check(hit(jugg, "Juggernaut", 2000 + 60000 + 1) == true, "after the prune window a hit musters")

-- No one near: the muster still counts, with nothing to say.
nearCount = 0
check(hit(boss, "Boss", 100000) == true and RQSvMuster.stats.recipients == 2 * 5,
    "with no player near the muster goes out to nobody and the counters say so")

print(string.format("RQSvMuster: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
