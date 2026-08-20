-- LSRoute fixture - the pasted-CSV waypoint route: parse honesty and the
-- lifecycle contracts it inherits from LSTour.
--
-- WHY THIS EXISTS, in two halves. The PARSE half pins skip-and-name: a pasted
-- spreadsheet column with a header row must cost the header its row and
-- nothing else, and every skip must carry the line number the admin can see in
-- their own paste. It also pins the 5.1 comma-split - the naive
-- `gmatch("([^,]*)")` yields interleaved empty fields ("3,4" becomes FOUR),
-- which would have skipped every valid row; the append-a-comma form is
-- load-bearing and a regression here fails loudly. The RUNNER half pins the
-- two ordering properties the LSTour review established, because this module
-- CLAIMS to inherit them: teardown-first (state is idle before restoration can
-- fail) and teleport-home-while-protected (the flags are still up when the
-- ride home fires).
--
-- STUBS MODEL THE VERIFIED SURFACE, same shapes as test_lstour: RDTeleport
-- returns rather than throwing (RDTeleport.lua:31-49) and snapshots the
-- protection flags AT CALL TIME, which is what makes the order assertable.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSRoute.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL LSRoute: " .. message) end
end

-- ---- stubs --------------------------------------------------------------
function isServer() return false end
require = function() return true end

local flags
local teleports = {}
RDTeleport = { toCoords = function(x, y, z)
    teleports[#teleports + 1] = { x = x, y = y, z = z,
        protected = flags.god and flags.invis and flags.ghost }
    return true
end }

local audits = {}
DFCore = { audit = function(action, player, extra)
    audits[#audits + 1] = { action = action, extra = extra }
end }

-- The real LSTour exports these; the stub keeps their exact semantics (snapshot
-- prior flags, force all three on; restore nil-checks) so the order assertions
-- exercise the same state machine production runs.
LSTour = {
    state = { running = false },
    applyProtection = function(player)
        local snap = { god = flags.god, invis = flags.invis, ghost = flags.ghost }
        flags.god, flags.invis, flags.ghost = true, true, true
        return snap
    end,
    restoreProtection = function(player, snap)
        if not player or not snap then return end
        flags.god   = snap.god == true
        flags.invis = snap.invis == true
        flags.ghost = snap.ghost == true
    end,
}

local function mkPlayer()
    flags = { god = false, invis = false, ghost = false }
    return {
        getX = function() return 100 end,
        getY = function() return 200 end,
        getZ = function() return 0 end,
        getUsername = function() return "Moth" end,
    }
end
local player = mkPlayer()
function getPlayer() return player end

LSRoute = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---- parse: the valid shapes --------------------------------------------
local wps, skipped = LSRoute.parse("100,200\n300,400,1\n  500 , 600 \n")
check(#wps == 3 and #skipped == 0, "three valid rows parsed (got "
    .. #wps .. " + " .. #skipped .. " skipped) - if all three skipped, the "
    .. "5.1 comma-split regression is back")
check(wps[1].x == 100 and wps[1].y == 200 and wps[1].z == 0, "x,y row with z defaulted to 0")
check(wps[2].z == 1, "explicit z kept")
check(wps[3].x == 500 and wps[3].y == 600, "spaces around numbers tolerated")

wps = LSRoute.parse("10.9,20.7\n-5,-8\n")
check(wps[1].x == 10 and wps[1].y == 20, "floats floored")
check(wps[2].x == -5 and wps[2].y == -8, "negative coordinates accepted")

-- ---- parse: skip-and-name -----------------------------------------------
wps, skipped = LSRoute.parse("x,y,z\n100,200\n\nbanana\n300,400\n1,2,3,4\n5,\n")
check(#wps == 2, "valid rows survive their bad neighbours (got " .. #wps .. ")")
check(#skipped == 4, "bad rows each skipped once (got " .. #skipped .. ")")
check(skipped[1] and skipped[1].line == 1 and skipped[1].reason:find("not a number"),
    "header row skipped BY NAME at line 1 - the admin's own paste numbering")
check(skipped[2] and skipped[2].line == 4, "blank lines still count for numbering "
    .. "(banana is line 4, not line 3)")
check(skipped[3] and skipped[3].reason:find("too many fields"),
    "a 4-field row refused, not truncated")
check(skipped[4] and skipped[4].reason:find("y is not a number"),
    "a trailing comma is an explicit empty field with a named reason")

wps, skipped = LSRoute.parse("")
check(#wps == 0 and #skipped == 0, "empty paste is empty, not an error")
wps, skipped = LSRoute.parse(nil)
check(#wps == 0 and #skipped == 0, "nil paste is empty, not an error")
wps, skipped = LSRoute.parse("100,200\r\n300,400\r\n")
check(#wps == 2, "CRLF line endings parse (a Windows paste is the normal case)")

-- ---- runner: start ------------------------------------------------------
local route = LSRoute.parse("10,20\n30,40\n50,60,1\n")
teleports, audits = {}, {}
local started, why = LSRoute.start(route)
check(started == true, "route starts: " .. tostring(why))
check(flags.god and flags.invis and flags.ghost, "protection applied on start")
check(#teleports == 1 and teleports[1].x == 10 and teleports[1].y == 20,
    "start teleports to waypoint 1, not waypoint 0")
check(LSRoute.status().active and LSRoute.status().idx == 1
    and LSRoute.status().total == 3, "status reads 1/3")

local again, whyNot = LSRoute.start(route)
check(again == false and tostring(whyNot):find("already"),
    "a second start is refused while active")

-- ---- runner: manual advance ---------------------------------------------
LSRoute.next()
check(#teleports == 2 and teleports[2].x == 30, "Next advances to waypoint 2")
LSRoute.next()
check(#teleports == 3 and teleports[3].x == 50 and teleports[3].z == 1,
    "Next advances to waypoint 3 with its z")
check(LSRoute.status().idx == 3, "status reads 3/3")

-- ---- runner: finishing well ---------------------------------------------
-- Next past the end IS the finish - one gesture, not two.
LSRoute.next()
check(LSRoute.status().active == false, "Next past the last waypoint finishes")
check(#teleports == 4 and teleports[4].x == 100 and teleports[4].y == 200,
    "finish teleports HOME (the recorded start position)")
check(teleports[4].protected == true,
    "the ride home fires WHILE PROTECTED - restoring flags first is the exact "
    .. "regression the 2026-08-18 LSTour review caught")
check(flags.god == false and flags.invis == false and flags.ghost == false,
    "protection restored to the pre-route flags after the ride home")
check(#audits == 2 and audits[2].action:find("completed"),
    "completion audited with the started/completed pair")
check(audits[2].extra:find("3/3"), "audit reports 3/3 waypoints")

-- Next when idle is inert, not an error.
local before = #teleports
LSRoute.next()
check(#teleports == before, "Next while idle does nothing")

-- ---- runner: abort ------------------------------------------------------
teleports, audits = {}, {}
LSRoute.start(LSRoute.parse("10,20\n30,40\n"))
LSRoute.abort()
check(LSRoute.status().active == false, "abort ends the route")
check(#teleports == 2 and teleports[2].x == 100 and teleports[2].protected == true,
    "abort also rides home protected")
check(audits[2] and audits[2].action:find("aborted") and audits[2].extra:find("1/2"),
    "abort audits how far it got")
LSRoute.abort()
check(#audits == 2, "abort while idle is inert")

-- ---- runner: mutual exclusion with the tour ------------------------------
LSTour.state.running = true
local blocked, reason = LSRoute.start(LSRoute.parse("10,20\n"))
check(blocked == false and tostring(reason):find("tour"),
    "a route refuses to start under a running tour - two protection snapshots "
    .. "would restore each other's flags")
LSTour.state.running = false

-- ---- runner: empty and playerless ---------------------------------------
check(LSRoute.start({}) == false, "empty waypoint list refused")
check(LSRoute.start(nil) == false, "nil waypoint list refused")
getPlayer = function() return nil end
check(LSRoute.start(LSRoute.parse("10,20\n")) == false, "no player refused")
getPlayer = function() return player end

realPrint(string.format("LSRoute: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
