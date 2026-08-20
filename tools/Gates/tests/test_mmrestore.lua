-- test_mmrestore.lua - recovery archive selection and isolation.
--
-- A player may have four compatible recovery points: current/legacy names in
-- canonical nested or historical flat layouts. Restore must choose the newest
-- valid record owned by the requested player. One unreadable or colliding file
-- cannot mask another candidate, and no invalid selection may reach the codec.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/server/Memoirs/MMRestore.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

function isServer() return true end
function isClient() return false end
require = function() end
Events = { OnServerStarted = { Add = function() end } }
Capability = { CanModifyPlayerStatsInThePlayerStatsUI = "cap" }
RDShared = { EXT_DOC = ".json.txt", EXT_DOC_LEGACY = ".json" }
MMShared = { MODULE = "RFTDMemoir", CMD = { RESULT = "result" } }

local files, readFaults, warnings = {}, {}, {}
function cacheFileExists(path) return files[path] ~= nil end
function getFileReader(path)
    local content = files[path]
    if content == nil then return nil end
    local done = false
    return {
        readLine = function()
            -- Engine truth (MethodCaller.java:33-56): BufferedReader is an
            -- exposed class, so an IOException in readLine is swallowed and
            -- Lua receives nil - a read fault reads as early EOF, never as a
            -- catchable error. A throwing stub here would manufacture a
            -- justification for a pcall the engine cannot deliver on.
            if readFaults[path] then return nil end
            if done then return nil end
            done = true
            return content
        end,
        close = function() end,
    }
end
function MMwarn(message) warnings[#warnings + 1] = tostring(message) end

local applied, activePlayer, applyOutcome, pushes, commands, auditRecords
MMSnapshotCodec = {
    applyToCharacter = function(_player, snap)
        applied[#applied + 1] = snap.marker
        return applyOutcome
    end,
}
function getOnlinePlayers()
    return {
        size = function() return activePlayer and 1 or 0 end,
        get = function(_, i) if i == 0 then return activePlayer end end,
    }
end
MMRoster = {
    findOnline = function(username)
        if activePlayer and activePlayer:getUsername() == username then return activePlayer end
        return nil
    end,
}
function sendServerCommand() commands = commands + 1 end

local function player(name)
    local md = {}
    return {
        getUsername = function() return name end,
        isDead = function() return false end,
        getModData = function() return md end,
    }
end

local function record(user, stamp, marker, omitEnvelopeStamp)
    local t = omitEnvelopeStamp and "" or ('"t":' .. tostring(stamp) .. ",")
    return "{" .. t .. '"user":"' .. user .. '","snap":{'
        .. '"profession":"unemployed","traits":[],"recipes":[],'
        .. '"writtenAt":' .. tostring(stamp) .. ',"marker":"' .. marker .. '"}}'
end

local function reset()
    files, readFaults, warnings, applied = {}, {}, {}, {}
    applyOutcome = { ok = true, partial = false, phase = "complete" }
    pushes, commands, auditRecords = 0, 0, {}
    activePlayer = player("alice")
    MMAudit, MMServer = nil, nil
end

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local CURRENT_NESTED = "Memoirs/alice/latest.json.txt"
local CURRENT_FLAT   = "Memoirs/alice.latest.json.txt"
local LEGACY_NESTED  = "Memoirs/alice/latest.json"
local LEGACY_FLAT    = "Memoirs/alice.latest.json"

-- Canonical current file remains the ordinary path.
reset()
files[CURRENT_NESTED] = record("alice", 100, "canonical")
local result = MMRestore.run(nil, "alice")
eq("canonical archive restores", result.ok, true)
eq("canonical archive reaches the codec", applied[1], "canonical")

-- Freshness, not layout order, decides when old fallback files coexist.
reset()
files[CURRENT_NESTED] = record("alice", 100, "older-nested")
files[CURRENT_FLAT] = record("alice", 200, "newer-flat")
result = MMRestore.run(nil, "alice")
eq("newer flat history beats older nested history", applied[1], "newer-flat")

-- A corrupt first candidate cannot mask a valid legacy recovery point.
reset()
files[CURRENT_NESTED] = "{broken"
files[LEGACY_FLAT] = record("alice", 150, "legacy-valid")
result = MMRestore.run(nil, "alice")
eq("valid fallback survives corrupt preferred candidate", result.ok, true)
eq("valid fallback is applied", applied[1], "legacy-valid")
eq("skipped corruption is observable", #warnings, 1)

-- A real BufferedReader failure reads as early EOF (the engine swallows the
-- IOException and hands Lua nil), so the faulted candidate surfaces as empty
-- and the search falls through - the same isolation, via the path the engine
-- actually takes.
reset()
files[CURRENT_NESTED] = record("alice", 300, "unreadable")
readFaults[CURRENT_NESTED] = true
files[LEGACY_NESTED] = record("alice", 140, "readable")
result = MMRestore.run(nil, "alice")
eq("reader failure does not abort candidate search", result.ok, true)
eq("reader failure falls through to readable archive", applied[1], "readable")

-- Ownership is filtered before freshness so a safeName collision cannot mask
-- a valid record belonging to the requested player.
reset()
files[CURRENT_NESTED] = record("bob", 500, "foreign")
files[LEGACY_FLAT] = record("alice", 120, "owned")
result = MMRestore.run(nil, "alice")
eq("newer foreign record cannot mask owned archive", result.ok, true)
eq("owned archive reaches the codec", applied[1], "owned")

reset()
files[CURRENT_NESTED] = record("bob", 500, "foreign")
result = MMRestore.run(nil, "alice")
eq("only foreign archives are refused", result.ok, false)
eq("foreign refusal names the owner", result.reason,
    "Archive belongs to 'bob', not alice.")
eq("foreign archive never reaches the codec", #applied, 0)

-- Missing, corrupt, and legacy timestamp behavior stay distinct.
reset()
result = MMRestore.run(nil, "alice")
eq("no candidates reports missing", result.reason, "No memoir archive found for alice.")
eq("missing archive never reaches the codec", #applied, 0)

reset()
files[CURRENT_NESTED] = "{broken"
result = MMRestore.run(nil, "alice")
eq("only corrupt candidates report unreadable", result.reason,
    "Archive for alice is unreadable - check server console.")
eq("corrupt archive never reaches the codec", #applied, 0)
eq("corrupt archive emits a diagnostic", #warnings, 1)

reset()
files[CURRENT_NESTED] = record("alice", 90, "tie-canonical")
files[CURRENT_FLAT] = record("alice", 90, "tie-flat")
result = MMRestore.run(nil, "alice")
eq("timestamp ties preserve canonical preference", applied[1], "tie-canonical")

reset()
files[CURRENT_NESTED] = record("alice", 100, "envelope-time")
files[LEGACY_FLAT] = record("alice", 200, "snapshot-time", true)
result = MMRestore.run(nil, "alice")
eq("legacy record can fall back to snapshot writtenAt", applied[1], "snapshot-time")

-- Application failures carry a safety classification. A preflight refusal did
-- not touch the player and remains retryable; a post-mutation failure closes the
-- once-per-life gate because replaying additive earnables could duplicate them.
reset()
files[CURRENT_NESTED] = record("alice", 100, "preflight-fail")
applyOutcome = { ok = false, partial = false, phase = "preflight", error = "bad archive" }
result = MMRestore.run(nil, "alice")
eq("preflight failure is refused", result.ok, false)
eq("preflight failure says nothing changed", result.reason,
    "Restore preflight failed for alice; nothing changed. Check server console.")
eq("preflight failure leaves the life retryable", activePlayer:getModData().MMRecalled, nil)
eq("preflight failure sends no success mirror", commands, 0)

reset()
files[CURRENT_NESTED] = record("alice", 100, "partial-fail")
applyOutcome = { ok = false, partial = true, phase = "earnables", error = "XP setter failed" }
MMServer = { pushFields = function() pushes = pushes + 1 end }
MMAudit = {
    sampleProgression = function()
        return { ok = true, levels = {}, xp = {} }
    end,
    attachProgression = function(fields, before, after)
        if before and before.ok then fields.lvlsBefore = before.levels end
        if after and after.ok then
            fields.lvlsAfter = after.levels
            fields.postXP = after.xp
        end
        return fields
    end,
    log = function(_, event, fields)
        auditRecords[#auditRecords + 1] = { event = event, fields = fields }
    end,
}
result = MMRestore.run(nil, "alice")
eq("partial failure is refused", result.ok, false)
eq("partial failure closes the life gate", activePlayer:getModData().MMRecalled, true)
eq("partial failure pushes the safety gate", pushes, 1)
eq("partial failure sends no success mirror", commands, 0)
eq("partial failure is classified in audit", auditRecords[1].fields.partial, true)
eq("partial failure records its phase", auditRecords[1].fields.phase, "earnables")

print(string.format("MMRestore archive selection: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
