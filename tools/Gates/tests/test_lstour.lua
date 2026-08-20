-- LSTour fixture - the teardown-ordering contract in finish().
--
-- WHY THIS EXISTS: finish() used to do best-effort work FIRST (teleport back,
-- audit) and tear down LAST, with two pcalls whose only job was to make sure a
-- failure above could not skip the teardown. The failure mode was serious - an
-- admin left in god/invisible with a live OnTick handler - but it is an
-- ORDERING problem, and pcall was standing in for a `finally` Lua does not
-- have. Teardown now runs first and unconditionally, so the property is
-- structural. These assertions pin that: however badly the restoration work
-- fails, the handler is gone and the tour is idle.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTour.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL LSTour: " .. message) end
end

function isServer() return false end

local tickHandlers = {}
Events = { OnTick = {
    Add    = function(fn) tickHandlers[fn] = true end,
    Remove = function(fn) tickHandlers[fn] = nil end,
} }

local flags   -- declared before the teleport stub, which snapshots it
local teleportMode, teleports = "ok", {}
RDTeleport = { toCoords = function(x, y, z)
    if teleportMode == "throw" then error("RDTeleport exploded") end
    -- Snapshot the protection flags AT CALL TIME: the order contract is that
    -- the admin is still god/invisible when the teleport-back fires.
    teleports[#teleports + 1] = { x, y, z,
        protected = flags.god and flags.invis and flags.ghost }
    return true
end }
Capability = { TeleportToCoordinates = "tp" }
RDAccess = { roleHas = function() return true end }

local auditMode, audits = "ok", {}
DFCore = { audit = function(action, player, extra)
    if auditMode == "throw" then error("audit exploded") end
    audits[#audits + 1] = { action = action, extra = extra }
end }

local function mkPlayer()
    flags = { god = false, invis = false, ghost = false }
    return {
        isGodMod = function() return flags.god end,
        isInvisible = function() return flags.invis end,
        isGhostMode = function() return flags.ghost end,
        setGodMod = function(_, v) flags.god = v end,
        setInvisible = function(_, v) flags.invis = v end,
        setGhostMode = function(_, v) flags.ghost = v end,
        getX = function() return 10 end,
        getY = function() return 20 end,
        getZ = function() return 0 end,
        getUsername = function() return "Moth" end,
    }
end
function getPlayer() return mkPlayer() end

require = function() return true end
LSTour = nil
local capturedLog = {}
print = function(x) capturedLog[#capturedLog + 1] = tostring(x) end
local ok, err = pcall(dofile, SOURCE)
print = realPrint
check(ok, "module loads: " .. tostring(err))

-- Drive a tour into the running state, then finish it under each fault.
local function runTour()
    teleports, audits, capturedLog = {}, {}, {}
    local player = mkPlayer()
    getPlayer = function() return player end
    print = function(x) capturedLog[#capturedLog + 1] = tostring(x) end
    local started = LSTour.start({ { region = { 0, 0, 30, 30 } } }, 10, { dwellMs = 250 })
    print = realPrint
    return started, player
end

local started = runTour()
check(started == true, "a tour starts")
check(LSTour.state.running == true, "and is marked running")
check(next(tickHandlers) ~= nil, "with a live OnTick handler")
check(flags.god and flags.invis and flags.ghost, "and the admin protected")
check(#audits == 1, "the start audit runs bare and is recorded")

-- ---- the property, under each fault ------------------------------------
local function finishUnder(mode)
    -- Each case needs its OWN started tour: LSTour.start refuses while a tour
    -- is already running, and the first version of this helper silently
    -- aborted the PREVIOUS case's tour with the new case's flags table -
    -- which is why its assertions proved nothing about ordering.
    LSTour.abort()
    local started = runTour()
    check(started == true, "a fresh tour starts for the '" .. mode .. "' case")
    teleportMode = (mode == "teleport") and "throw" or "ok"
    auditMode    = (mode == "audit") and "throw" or "ok"
    -- start() teleports to the first cell, so count the teleport-BACK as the
    -- delta across abort rather than an absolute.
    local before = #teleports
    print = function(x) capturedLog[#capturedLog + 1] = tostring(x) end
    local aborted = pcall(LSTour.abort)
    print = realPrint
    teleportMode, auditMode = "ok", "ok"
    return aborted, #teleports - before
end

local _, cleanDelta = finishUnder("none")
check(LSTour.state.running == false and next(tickHandlers) == nil,
      "a clean finish tears down")
check(not flags.god and not flags.invis and not flags.ghost,
      "and restores the admin's protection flags")
check(cleanDelta == 1, "and teleports back to the start exactly once")
check(teleports[#teleports].protected == true,
      "the admin is STILL PROTECTED when the teleport-back fires - review "
      .. "finding 2026-08-18: restoring flags first left them mortal in the "
      .. "freshly populated cell while /teleportto round-tripped")

finishUnder("teleport")
check(LSTour.state.running == false,
      "a THROWING teleport still leaves the tour not running")
check(next(tickHandlers) == nil,
      "and the OnTick handler is still removed - the whole point of the reorder")
check(LSTour.state.phase == "idle", "and the phase is idle, ready for a clean restart")
check(flags.god and flags.invis and flags.ghost,
      "protection is NOT restored on that path - restoration follows the "
      .. "teleport by design, and a throwing toCoords is a broken contract "
      .. "surfacing after teardown, not a case to absorb")

local _, auditDelta = finishUnder("audit")
check(LSTour.state.running == false and next(tickHandlers) == nil,
      "a THROWING audit cannot strand the tour either")
check(auditDelta == 1, "and the teleport-back still happened, because it runs before the audit")

-- A second abort on an already-finished tour is a no-op.
local idleBefore = #teleports
LSTour.abort()
check(#teleports == idleBefore, "abort on an idle tour does nothing")

realPrint(string.format("LSTour: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
