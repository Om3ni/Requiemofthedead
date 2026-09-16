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

-- The REAL RDJson, not a stub. MMRestore's JSON decoder was promoted to Core on
-- 2026-08-22 (RDConfigStore needed the same parser and a second copy would have
-- been a pasted helper), so this file's archive-read path now runs Core's code.
-- Stubbing it would test a fake parser and prove nothing about what ships - and
-- the decoder's failure mode, returning (nil, message) on a truncated file, is
-- exactly what the archive tests below depend on.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDJson.lua")
Events = { OnServerStarted = { Add = function() end } }
Capability = { CanModifyPlayerStatsInThePlayerStatsUI = "cap" }
-- The REAL RDShared, not a hand-rolled stub - anything Core adds to it
-- otherwise silently under-serves this fixture (the 2026-08-23 username()
-- promotion proved it). Its only file-scope call is registerMod.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")
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

local applied, applyCalls, identityMatch, activePlayer, applyOutcome
local pushes, commands, mirror, auditRecords
MMSnapshotCodec = {
    applyToCharacter = function(_player, snap, chosen, xpMode, fullRestore, xpFraction)
        applied[#applied + 1] = snap.marker
        applyCalls[#applyCalls + 1] = { marker = snap.marker, chosen = chosen, xpMode = xpMode,
                                        fullRestore = fullRestore, xpFraction = xpFraction }
        return applyOutcome
    end,
    -- The legacy bridge for a pre-v4 archive (no lifeId): the fixture decides
    -- the answer, the restore decides what to do with it.
    identityMatches = function() return identityMatch end,
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
function sendServerCommand(_player, _module, _command, args)
    commands = commands + 1
    mirror = args
end

local function player(name)
    local md = {}
    return {
        getUsername = function() return name end,
        isDead = function() return false end,
        getModData = function() return md end,
    }
end

-- lifeId (optional) stamps the snapshot the way a v4+ WRITE does; omitted, the
-- record is a pre-v4 archive and exercises the legacy bridge.
local function record(user, stamp, marker, omitEnvelopeStamp, lifeId)
    local t = omitEnvelopeStamp and "" or ('"t":' .. tostring(stamp) .. ",")
    local life = lifeId and ('"lifeId":"' .. lifeId .. '",') or ""
    return "{" .. t .. '"user":"' .. user .. '","snap":{' .. life
        .. '"profession":"unemployed","traits":[],"recipes":[],'
        .. '"writtenAt":' .. tostring(stamp) .. ',"marker":"' .. marker .. '"}}'
end

-- The audit sink, installed by the cases that assert on the forensic record.
-- Records `who` as well: a refusal for an OFFLINE target must be logged
-- against the username string, since there is no player object to hand over.
local function installAudit()
    MMAudit = {
        sampleProgression = function() return { ok = true, levels = {}, xp = {} } end,
        attachProgression = function(fields, before, after)
            if before and before.ok then fields.lvlsBefore = before.levels end
            if after and after.ok then
                fields.lvlsAfter = after.levels
                fields.postXP = after.xp
            end
            return fields
        end,
        log = function(who, event, fields)
            auditRecords[#auditRecords + 1] = { who = who, event = event, fields = fields }
        end,
        scheduleRecheck = function() end,
    }
end

local function reset()
    files, readFaults, warnings, applied, applyCalls = {}, {}, {}, {}, {}
    applyOutcome = { ok = true, partial = false, phase = "complete" }
    pushes, commands, mirror, auditRecords = 0, 0, nil, {}
    identityMatch = false
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
installAudit()
result = MMRestore.run(nil, "alice")
eq("partial failure is refused", result.ok, false)
eq("partial failure closes the life gate", activePlayer:getModData().MMRecalled, true)
eq("partial failure pushes the safety gate", pushes, 1)
eq("partial failure sends no success mirror", commands, 0)
eq("partial failure is classified in audit", auditRecords[1].fields.partial, true)
eq("partial failure records its phase", auditRecords[1].fields.phase, "earnables")

-- ─────────────────────────────────────────────────────────────────────────
-- Apply shape follows the life id (2026-09-05). The additive overwrite is
-- only sound across two different lives; an archive the current life wrote
-- must come back as the non-additive top-up, or every earned point lands
-- twice - which is what a live restore did that day.
-- ─────────────────────────────────────────────────────────────────────────

-- Same life: top-up, identity kept, the life's one recall NOT spent, and the
-- shape travels to the client's mirror so both sides run the same arithmetic.
reset()
installAudit()
files[CURRENT_NESTED] = record("alice", 100, "same-life", false, "L1")
activePlayer:getModData().MMLifeId = "L1"
result = MMRestore.run(nil, "alice")
eq("same-life archive restores", result.ok, true)
eq("same-life archive applies as a top-up", applyCalls[1].xpMode, "max")
eq("same-life top-up keeps identity", applyCalls[1].chosen, nil)
eq("same-life top-up still bypasses the death tax", applyCalls[1].fullRestore, true)
eq("same-life top-up does not spend the life's recall", activePlayer:getModData().MMRecalled, nil)
eq("mirror carries the top-up shape", mirror.applyData.xpMode, "max")
eq("mirror carries no identity for a top-up", mirror.applyData.chosen, nil)
eq("record names the shape", auditRecords[1].fields.xpMode, "max")
eq("record names why", auditRecords[1].fields.lifeCheck, "samelife")
eq("admin is told it was a top-up", result.message,
    "Restored alice (top-up: this life wrote the archive, nothing counted twice) from archive (snapshot t=100).")

-- Same life is replay-safe, so the once-per-life gate does not apply to it.
reset()
files[CURRENT_NESTED] = record("alice", 100, "same-life-again", false, "L1")
activePlayer:getModData().MMLifeId = "L1"
activePlayer:getModData().MMRecalled = true
result = MMRestore.run(nil, "alice")
eq("recalled life still accepts a top-up of its own archive", result.ok, true)
eq("recalled life's top-up is the non-additive shape", applyCalls[1].xpMode, "max")

-- A different life: the memoir-read shape, identity from the archive, gate spent.
reset()
files[CURRENT_NESTED] = record("alice", 100, "other-life", false, "L1")
activePlayer:getModData().MMLifeId = "L2"
result = MMRestore.run(nil, "alice")
eq("other-life archive applies as the additive overwrite", applyCalls[1].xpMode, "overwrite")
eq("other-life overwrite restores identity", applyCalls[1].chosen.profession, "unemployed")
eq("other-life overwrite spends the life's recall", activePlayer:getModData().MMRecalled, true)
eq("mirror carries the overwrite shape", mirror.applyData.xpMode, "overwrite")
eq("plain message for the additive shape", result.message,
    "Restored alice from archive (snapshot t=100).")

-- A fresh respawn (or a wiped players.db) has no MMLifeId yet: the disaster
-- case, and a different life.
reset()
files[CURRENT_NESTED] = record("alice", 100, "fresh-respawn", false, "L1")
result = MMRestore.run(nil, "alice")
eq("target without a life id is another life", applyCalls[1].xpMode, "overwrite")

-- The gate still holds for the additive shape.
reset()
installAudit()
files[CURRENT_NESTED] = record("alice", 100, "gated", false, "L1")
activePlayer:getModData().MMLifeId = "L2"
activePlayer:getModData().MMRecalled = true
result = MMRestore.run(nil, "alice")
eq("recalled life refuses a second additive apply", result.ok, false)
eq("gate refusal never reaches the codec", #applied, 0)
eq("gate refusal is on the record", auditRecords[1].event, "RESTORE_SKIPPED")
eq("gate refusal says why", auditRecords[1].fields.why, "recalled")

-- A pre-v4 archive carries no lifeId and cannot be proven either way; the
-- read path's legacy bridge decides: identity match -> top-up, else overwrite.
reset()
files[CURRENT_NESTED] = record("alice", 100, "legacy-match")
identityMatch = true
result = MMRestore.run(nil, "alice")
eq("legacy archive with matching identity is a top-up", applyCalls[1].xpMode, "max")
eq("legacy top-up keeps identity", applyCalls[1].chosen, nil)

reset()
files[CURRENT_NESTED] = record("alice", 100, "legacy-mismatch")
identityMatch = false
result = MMRestore.run(nil, "alice")
eq("legacy archive with differing identity is an overwrite", applyCalls[1].xpMode, "overwrite")

-- A partial TOP-UP does not close the gate: "max" never adds, so a replay
-- cannot duplicate anything, and the life keeps its one recall.
reset()
installAudit()
files[CURRENT_NESTED] = record("alice", 100, "partial-topup", false, "L1")
activePlayer:getModData().MMLifeId = "L1"
applyOutcome = { ok = false, partial = true, phase = "earnables", error = "XP setter failed" }
MMServer = { pushFields = function() pushes = pushes + 1 end }
result = MMRestore.run(nil, "alice")
eq("partial top-up is refused", result.ok, false)
eq("partial top-up leaves the life's recall", activePlayer:getModData().MMRecalled, nil)
eq("partial top-up does not tell the admin never to retry", result.reason,
    "Restore partially changed alice. Have them relog and check the forensic record.")
eq("partial top-up names its shape in the record", auditRecords[1].fields.xpMode, "max")

-- ─────────────────────────────────────────────────────────────────────────
-- Every refusal before the apply is on the target's record (RESTORE_SKIPPED).
-- Dragonfly's audit line is written before the handler runs and carries no
-- outcome, so without these a refused restore was invisible in Memoirs/.
-- ─────────────────────────────────────────────────────────────────────────
local function skipped()
    local r = auditRecords[1]
    return r and r.event == "RESTORE_SKIPPED" and r.fields.why or nil
end

reset()
installAudit()
activePlayer = nil
result = MMRestore.run(nil, "alice")
eq("offline refusal is on the record", skipped(), "offline")
eq("offline refusal is logged against the username", auditRecords[1].who, "alice")

reset()
installAudit()
activePlayer.isDead = function() return true end
result = MMRestore.run(nil, "alice")
eq("dead refusal is on the record", skipped(), "dead")
eq("online refusals log against the player", auditRecords[1].who, activePlayer)

reset()
installAudit()
result = MMRestore.run(nil, "alice")
eq("missing archive is on the record", skipped(), "noarchive")

reset()
installAudit()
files[CURRENT_NESTED] = "{broken"
result = MMRestore.run(nil, "alice")
eq("unreadable archive is on the record", skipped(), "unreadable")
eq("unreadable refusal carries the detail", type(auditRecords[1].fields.detail), "string")

reset()
installAudit()
files[CURRENT_NESTED] = record("bob", 500, "foreign")
result = MMRestore.run(nil, "alice")
eq("foreign archive is on the record", skipped(), "owner")
eq("foreign refusal names the owner", auditRecords[1].fields.archiveOwner, "bob")

reset()
installAudit()
result = MMRestore.run(player("root"), "alice")
eq("refusal record names the admin", auditRecords[1].fields.admin, "root")

-- Refusals stay refusals when auditing is off (MMAudit nil).
reset()
result = MMRestore.run(nil, "alice")
eq("refusal without an audit sink still refuses", result.ok, false)

print(string.format("MMRestore archive selection: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
