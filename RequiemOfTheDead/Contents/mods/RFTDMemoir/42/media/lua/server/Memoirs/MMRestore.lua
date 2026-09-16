-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMRestore.lua - disaster-recovery character restore from the memoir archive.
-- Why: a mid-season wipe or corrupted players.db should cost players THINGS, not
-- PROGRESSION. MMAudit's per-player archive (latest.json) carries the full
-- MMSnapshotCodec snapshot; this feeds it back through the same battle-verified
-- apply path the memoir read uses. Admin-triggered ONLY (a Players-tab row
-- action -> DFServer handler), never automatic.
--
-- Design decisions (locked with the user):
--   * 100% restore - fullRestore=true bypasses the MemoirXPRestore knob. The
--     knob is a DEATH tax; a wipe is the server's fault, players are made whole.
--   * Two apply shapes, chosen by life id exactly as a memoir read chooses them
--     (chooseShape below). The additive overwrite is once per life, same gate
--     as reads (modData.MMRecalled): applied twice to one life it double-counts
--     (the second apply reads the first restore as "this life's earnings").
--     Death re-arms. The same-life top-up is non-additive and neither needs
--     nor spends that gate. Until 2026-09-05 every restore ran the additive
--     shape, and one run against an archive the current life had written
--     doubled every earned skill and the kill tally.
--   * Target must be online and alive: the apply needs the live player object,
--     and the owning client must mirror-apply (no reliable Lua server->client XP
--     push) - delivered over the EXISTING MMShared RESULT channel, so MMClient
--     needs no new command handling.
--
-- JSON decoder: parses OUR OWN encoder's output only (MMAudit.jsonEncode -
-- objects, arrays, strings with \\ \" \r \n \t escapes, plain numbers,
-- true/false/null). Not a general JSON library; don't feed it foreign files.

if not isServer() then return end

require "MMSvShared"
require "MMSnapshotCodec"
require "RDJson"     -- decode: promoted out of this file 2026-08-22
require "RDShared"   -- EXT_DOC / EXT_DOC_LEGACY, read at file scope below
require "MMRoster"

MMRestore = MMRestore or {}

local DIR = "Memoirs/"

-- must mirror MMAudit's safeName so we find the same files
local function safeName(name)
    name = tostring(name or "unknown")
    return (name:gsub("[^%w%-_]", "_"))
end

-- The Players tab's XP% dial, normalised. Returns (fraction 0..1, integer 0..100).
--
-- The clamp is NOT optional and NOT a duplicate of the codec's own: the dial is a
-- free-text client field, so the wire value is attacker-controlled - 500, -1 and
-- "abc" all have to become something sane before they reach the apply. Absent
-- means 100, which is what every pre-dial caller and any older client sends, so
-- the single-click behaviour that shipped before this field is unchanged.
--
-- Reminder on what the number means, since it is reported to admins: it scales
-- EARNED xp only. The saved build's grant floor always restores in full, so 0%
-- still returns a character equivalent to a fresh spawn of their own build.
local function restoreFraction(xpPercent)
    local p = tonumber(xpPercent)
    if p == nil then p = 100 end
    if p < 0 then p = 0 elseif p > 100 then p = 100 end
    p = math.floor(p + 0.5)
    return p / 100.0, p
end
MMRestore.restoreFraction = restoreFraction   -- exposed for the test suite

-- ─────────────────────────────────────────────────────────────────────────
-- JSON decode (own-schema only; see header)
-- ─────────────────────────────────────────────────────────────────────────

-- Promoted to Core 2026-08-22: RDConfigStore needed the same parser and a second
-- copy would have been a pasted helper. Behaviour unchanged; the own-schema
-- limitation documented on RDJson.decode still applies.
local decode = RDJson.decode
MMRestore.decode = decode -- exposed for the future progression-sheet tooling

-- ─────────────────────────────────────────────────────────────────────────
-- Archive read (nested layout preferred, flat fallback - mirrors MMAudit)
-- ─────────────────────────────────────────────────────────────────────────

local function readAll(path)
    local fullPath = DIR .. path
    -- cacheFileExists and getFileReader share cacheDir/Lua as their root
    -- (LuaManager.java:4617-4623, 4894-4915). Existence lets a missing optional
    -- layout remain ordinary while an existing-but-unopenable recovery point is
    -- reported as damaged instead of silently becoming "no archive".
    if not cacheFileExists(fullPath) then return nil, "missing", false end

    -- No guard - corrected 2026-08-19: BufferedReader is an exposed class
    -- (LuaManager.java:1651) and exposed method bodies cannot raise into Lua;
    -- MethodCaller swallows the IOException, logs the stack trace, and returns
    -- nil (MethodCaller.java:33-56). A read fault therefore reads as early
    -- EOF: a fault before the first line lands in the "empty" branch below,
    -- and a mid-stream fault yields TRUNCATED content that the decode step
    -- rejects at the candidate level - the same per-candidate isolation the
    -- pcall claimed to provide, now via the path the engine actually takes.
    local br = getFileReader(fullPath, false)
    if not br then return nil, "reader refused existing file", true end
    local lines = {}
    while true do
        local line = br:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    br:close()
    local content = table.concat(lines, "\n")
    if content == "" then return nil, "empty", true end
    return content, nil, true
end

-- Four candidates, and every one of them is load-bearing. Two layouts (nested
-- canonical, flat historical fallback) x two eras: the 42.20
-- write allowlist forced ".json" -> ".json.txt" (see RDShared), so any player whose
-- last WRITE predates that rename has their recovery point under the legacy name.
-- Reads are NOT gated, so the old files open fine and nothing needs migrating.
-- Candidate order breaks timestamp ties in favour of the canonical current path;
-- it does not decide freshness. The old first-nonempty chain could let an older
-- nested file mask a newer flat fallback, or let one corrupt file mask every valid
-- alternative. Drop the legacy pair only once no season on disk predates 42.20.
local function readLatest(safe, targetUsername)
    local paths = {
        safe .. "/latest" .. RDShared.EXT_DOC,
        safe .. ".latest" .. RDShared.EXT_DOC,
        safe .. "/latest" .. RDShared.EXT_DOC_LEGACY,
        safe .. ".latest" .. RDShared.EXT_DOC_LEGACY,
    }
    local best, bestStamp
    local problems, foreign = {}, {}
    local sawExisting = false

    for _, path in ipairs(paths) do
        local content, readErr, existed = readAll(path)
        if existed then sawExisting = true end
        if content then
            local rec, decodeErr = decode(content)
            if type(rec) ~= "table" or type(rec.snap) ~= "table" then
                problems[#problems + 1] = path .. ": " .. tostring(decodeErr or "missing snapshot")
            elseif rec.user and rec.user ~= targetUsername then
                foreign[#foreign + 1] = tostring(rec.user)
            else
                local stamp = tonumber(rec.t) or tonumber(rec.snap.writtenAt) or 0
                if not best or stamp > bestStamp then
                    best, bestStamp = rec, stamp
                end
            end
        elseif existed then
            problems[#problems + 1] = path .. ": " .. tostring(readErr)
        end
    end

    if best then
        if #problems > 0 then
            MMwarn("RESTORE skipped unusable archive candidate(s) for " .. targetUsername
                .. ": " .. table.concat(problems, "; "))
        end
        return best
    end
    if #foreign > 0 then return nil, "owner", foreign[1] end
    if sawExisting then return nil, "unreadable", table.concat(problems, "; ") end
    return nil, "missing"
end

-- ─────────────────────────────────────────────────────────────────────────
-- The restore
-- ─────────────────────────────────────────────────────────────────────────

-- Admin username for the audit envelope; "?" when the handler was reached
-- without one (a console path, the test fixture).
local function adminName(admin)
    return (admin and admin.getUsername and admin:getUsername()) or "?"
end

-- Every refusal BEFORE the apply goes on the target's own forensic record as
-- RESTORE_SKIPPED. Until 2026-09-05 these returned bare, so a refused restore
-- left nothing under Memoirs/<player>/: Dragonfly's audit line is written
-- before the handler runs and carries no outcome, and the reason string only
-- reached the admin's screen. Observed live that day - a second restore on
-- one player tripped the once-per-life gate and the memoir record showed no
-- attempt at all. `who` is the IsoPlayer when the target is online, else the
-- username string; MMAudit.log accepts both, and MMname(player) IS the
-- username, so both land in the directory readLatest reads from.
local function refuse(admin, who, why, reason, extra)
    if MMAudit then
        local data = { admin = adminName(admin), why = why }
        for k, v in pairs(extra or {}) do data[k] = v end
        MMAudit.log(who, "RESTORE_SKIPPED", data)
    end
    return { ok = false, reason = reason }
end

-- Which apply shape the archive gets - decided the way MMServer.onRead decides
-- it for a book, because the restore feeds the SAME codec and inherits the
-- same hazard. The additive "overwrite" (saved earnings + this life's
-- earnings, MMSnapshotCodec header) is only sound when those are two
-- different lives; run it against an archive the current life wrote and
-- every earned point is counted twice. That is what happened on 2026-09-05,
-- and the case is the DEFAULT here, not the edge: latest.json is rewritten by
-- every WRITE (MMAudit), so once a player has written on their new life the
-- archive is always their own.
--
--   same life     -> "max": non-additive top-up to the snapshot, identity kept
--                    (it IS the current build). Idempotent, so it neither needs
--                    the once-per-life gate nor spends it: a top-up of one's
--                    own earnings double-counts nothing, and stamping
--                    MMRecalled here would refuse the life's one legitimate
--                    read of an older book later.
--   other life    -> "overwrite", the memoir-read shape. A target with no
--                    MMLifeId is this case: the id is stamped at a life's first
--                    WRITE, so a fresh respawn - or a wiped players.db, the
--                    disaster this tool exists for - has none.
--   no lifeId in the archive (a pre-v4 write) -> provable neither way, so the
--                    read path's legacy bridge is the rule here too:
--                    identityMatches -> top-up, else overwrite.
-- Returns xpMode, chosenIdentity (nil = keep) and a code for the record.
local function chooseShape(target, snap, md)
    local ident = { profession = snap.profession, traits = snap.traits }
    if snap.lifeId then
        if md and md.MMLifeId == snap.lifeId then return "max", nil, "samelife" end
        return "overwrite", ident, "otherlife"
    end
    if MMSnapshotCodec.identityMatches(target, snap) then return "max", nil, "legacy-match" end
    return "overwrite", ident, "legacy-mismatch"
end

-- What the admin reads back beside "Restored <name>". The additive shape is
-- the plain word; the others say what was different about this one.
local SHAPE_NOTE = {
    samelife            = " (top-up: this life wrote the archive, nothing counted twice)",
    ["legacy-match"]    = " (top-up: pre-v4 archive, identity matches)",
    ["legacy-mismatch"] = " (pre-v4 archive, identity differs)",
}

-- Returns DFServer's handler contract: { ok = bool, message|reason = string }.
function MMRestore.run(admin, targetUsername, xpPercent)
    targetUsername = tostring(targetUsername or "")
    -- Unaudited by necessity: there is no player directory to record against.
    -- Dragonfly's own audit already holds the admin and the command.
    if targetUsername == "" then return { ok = false, reason = "No target username." } end
    local xpFrac, xpPct = restoreFraction(xpPercent)

    local target = MMRoster.findOnline(targetUsername)
    if not target then
        return refuse(admin, targetUsername, "offline",
            targetUsername .. " must be online to restore.")
    end
    if target:isDead() then
        return refuse(admin, target, "dead",
            targetUsername .. " is dead - restore after they respawn.")
    end

    local rec, archiveState, archiveDetail = readLatest(safeName(targetUsername), targetUsername)
    if archiveState == "missing" then
        return refuse(admin, target, "noarchive",
            "No memoir archive found for " .. targetUsername .. ".")
    end
    if archiveState == "unreadable" then
        MMwarn("RESTORE archive unreadable for " .. targetUsername .. ": " .. tostring(archiveDetail))
        return refuse(admin, target, "unreadable",
            "Archive for " .. targetUsername .. " is unreadable - check server console.",
            { detail = tostring(archiveDetail) })
    end
    if archiveState == "owner" then
        return refuse(admin, target, "owner",
            "Archive belongs to '" .. tostring(archiveDetail) .. "', not " .. targetUsername .. ".",
            { archiveOwner = tostring(archiveDetail) })
    end

    local snap = rec.snap
    -- The archive stores recipes normalized to a sorted LIST; the codec expects
    -- the live snapshot's SET shape. Denormalize before applying.
    if snap.recipes and #snap.recipes > 0 then
        local set = {}
        for _, id in ipairs(snap.recipes) do set[id] = true end
        snap.recipes = set
    end

    local md = target:getModData()
    local xpMode, chosen, lifeCheck = chooseShape(target, snap, md)
    local additive = (xpMode == "overwrite")

    -- Once-per-life gate, ADDITIVE shape only - a second additive apply on one
    -- life double-counts everything the first delivered. Death re-arms. The
    -- top-up is replay-safe and passes (see chooseShape).
    if additive and md and md.MMRecalled then
        return refuse(admin, target, "recalled", targetUsername
            .. " already recalled/restored this life. Death re-arms the gate.")
    end

    local preProgress = MMAudit and MMAudit.sampleProgression(target) or nil
    -- fullRestore, with the dial as an explicit fraction. xpFrac is 1.0 when no
    -- dial was sent, so this is byte-for-byte the old 100% behaviour by default.
    local apply = MMSnapshotCodec.applyToCharacter(target, snap, chosen, xpMode, true, xpFrac)
    if not apply.ok then
        -- A partial ADDITIVE apply closes the gate: replaying it could duplicate
        -- what already landed. A partial top-up is replay-safe ("max" never
        -- adds), so the life keeps its recall.
        if apply.partial and additive then
            if md then md.MMRecalled = true end
            if MMServer and MMServer.pushFields then MMServer.pushFields(target) end
        end
        MMwarn("RESTORE apply FAILED for " .. targetUsername .. " (xpMode=" .. xpMode
            .. ", phase=" .. tostring(apply.phase) .. ", partial=" .. tostring(apply.partial)
            .. "): " .. tostring(apply.error))
        if MMAudit then
            local postProgress = MMAudit.sampleProgression(target)
            MMAudit.log(target, "RESTORE_FAIL", MMAudit.attachProgression({
                admin = adminName(admin), xpMode = xpMode, lifeCheck = lifeCheck,
                phase = apply.phase, partial = apply.partial, err = tostring(apply.error)
            }, preProgress, postProgress))
        end
        if apply.partial then
            return { ok = false, reason = "Restore partially changed " .. targetUsername
                .. (additive and ". Do not retry; have them relog" or ". Have them relog")
                .. " and check the forensic record." }
        end
        return { ok = false, reason = "Restore preflight failed for " .. targetUsername
            .. "; nothing changed. Check server console." }
    end

    if additive and md then md.MMRecalled = true end
    if MMServer and MMServer.pushFields then MMServer.pushFields(target) end

    -- Mirror-apply on the target's client over the existing memoir RESULT
    -- channel - MMClient already knows how to apply applyData and refresh.
    -- xpFraction MUST travel with the mirror: the client recomputes the same
    -- targets from the same snapshot, and a mirror that defaulted to 100% while
    -- the server applied 60% would desync the character until relog. The shape
    -- (xpMode + chosen) travels for the same reason: both sides must run the
    -- same arithmetic on the same snapshot.
    sendServerCommand(target, MMShared.MODULE, MMShared.CMD.RESULT, {
        ok = true,
        say = "My life... it all comes back to me.",
        applyData = { snap = snap, chosen = chosen, xpMode = xpMode, fullRestore = true,
                      xpFraction = xpFrac },
    })

    if MMAudit then
        local postProgress = MMAudit.sampleProgression(target)
        MMAudit.log(target, "RESTORE_OK", MMAudit.attachProgression({
            admin      = adminName(admin),
            -- The dial is recorded because a restore at anything but 100% is a
            -- deliberate policy act (a season migration allowance, say), and
            -- "why is my carpentry lower than my old character" is unanswerable
            -- a month later without it.
            xpPct      = xpPct,
            -- Which shape ran and why. The postXP/snap diff alone cannot tell
            -- a doubled additive apply from a legitimate one - the 2026-09-05
            -- record read as a successful restore until the ratios were taken.
            xpMode     = xpMode,
            lifeCheck  = lifeCheck,
            archiveT   = rec.t,
            snap       = snap,
        }, preProgress, postProgress))
        MMAudit.scheduleRecheck(target, nil, postProgress)
    end
    local pctNote = (xpPct ~= 100) and (" at " .. xpPct .. "% of earned XP") or ""
    return { ok = true, message = "Restored " .. targetUsername .. pctNote
        .. (SHAPE_NOTE[lifeCheck] or "")
        .. " from archive (snapshot t=" .. tostring(snap.writtenAt or rec.t or "?") .. ")." }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Bulk restore
-- ─────────────────────────────────────────────────────────────────────────

-- Each target costs an archive read, a JSON decode, a whole-character codec
-- apply and a packet to that player. Ten of those inside one OnClientCommand is
-- already a visible hitch; forty would be a stall an admin reads as a crash.
local MAX_BATCH = 10

-- Restore a SELECTION, each player from their OWN archive.
--
-- That correctness property comes from MMRestore.run being pure per-target: it
-- resolves the IsoPlayer by the name it was handed and reads
-- readLatest(safeName(thatUsername)), with the envelope's rec.user as a
-- tiebreaker against safeName collisions. Nothing ambient, no "currently
-- selected" state on the server, no snapshot id on the wire - so five names
-- produce five independent restores and cross-contamination is impossible by
-- construction. Do not introduce shared state between iterations.
--
-- Partial failure is the NORMAL case here, not the exception: every target must
-- be online AND alive AND hold a readable archive AND not have already recalled
-- this life. Restore five and it is entirely likely two are skipped, so this
-- reports per-target rather than a single cheerful "done".
function MMRestore.runMany(admin, usernames, xpPercent)
    if type(usernames) ~= "table" then
        return { ok = false, reason = "No targets selected." }
    end

    -- Dedup, preserving click order. A name listed twice would restore on the
    -- first pass and then trip its OWN once-per-life gate on the second,
    -- reporting a failure that is really just the duplicate.
    local seen, targets = {}, {}
    for _, u in ipairs(usernames) do
        local name = tostring(u or "")
        if name ~= "" and not seen[name] then
            seen[name] = true
            targets[#targets + 1] = name
        end
    end
    if #targets == 0 then return { ok = false, reason = "No targets selected." } end

    -- One target hands straight to the single-target path, so its richer message
    -- ("...snapshot t=...") is untouched. Every ordinary single-select click
    -- still lands there: this change cannot regress the common case.
    if #targets == 1 then return MMRestore.run(admin, targets[1], xpPercent) end

    -- Never silently truncate. An admin who selected twenty and read "restored
    -- 10" would reasonably conclude the other ten FAILED, rather than that they
    -- were never attempted.
    local overflow = {}
    while #targets > MAX_BATCH do
        table.insert(overflow, 1, table.remove(targets))
    end

    local okNames, failed = {}, {}

    -- Per-target line into every admin's Console tab. The reply below is a
    -- single HaloText string and cannot carry ten reasons; this is where an
    -- admin actually finds out WHY someone was skipped.
    local function report(name, ok, why)
        if DFCore and DFCore.audit then
            DFCore.audit("memoirRestore", admin, "target=" .. name
                .. (ok and " (restored)" or (" (skipped: " .. tostring(why) .. ")")))
        else
            MMwarn("RESTORE batch -> " .. name
                .. (ok and ": restored" or (": skipped - " .. tostring(why))))
        end
    end

    for _, name in ipairs(targets) do
        -- pcall per target: one engine fault must not abandon the rest of the
        -- batch, half applied and wholly unreported.
        local called, res = pcall(MMRestore.run, admin, name, xpPercent)
        local ok, why = false, nil
        if not called then
            why = "internal error: " .. tostring(res)
            MMwarn("RESTORE batch: " .. name .. " threw: " .. tostring(res))
        elseif type(res) == "table" and res.ok then
            ok = true
        else
            why = (type(res) == "table" and (res.reason or res.message)) or "unknown failure"
        end

        if ok then okNames[#okNames + 1] = name else failed[#failed + 1] = name end
        report(name, ok, why)
    end

    for _, name in ipairs(overflow) do
        report(name, false, "not attempted, batch cap " .. MAX_BATCH)
    end

    -- Summary only - this becomes a floating HaloText line over the admin.
    local parts = { string.format("Restored %d of %d", #okNames, #targets) }
    -- Surface the dial whenever it is not 100: restoring five people at 60% is a
    -- different act from restoring them whole, and the admin should see which one
    -- just happened without going to the Console tab for it.
    local _, batchPct = restoreFraction(xpPercent)
    if batchPct ~= 100 then
        parts[#parts + 1] = string.format("%d%% of earned XP", batchPct)
    end
    if #failed > 0 then parts[#parts + 1] = string.format("%d skipped", #failed) end
    if #overflow > 0 then
        parts[#parts + 1] = string.format("%d over the %d cap", #overflow, MAX_BATCH)
    end
    if #failed > 0 or #overflow > 0 then parts[#parts + 1] = "see Console tab" end
    local summary = table.concat(parts, " - ") .. "."

    -- ok=false when nothing landed, so DFFeedback renders it as a failure rather
    -- than a green "Restored 0 of 5".
    if #okNames == 0 then return { ok = false, reason = summary } end
    return { ok = true, message = summary }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Dragonfly panel registration (deferred: DFServer loads after Memoirs/
-- alphabetically; OnServerStarted is the same gate DFPlayersTab_Server uses)
-- ─────────────────────────────────────────────────────────────────────────
Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] MMRestore: DFServer missing, restore handler not registered")
        return
    end
    -- Named local, not a function literal in the table: nameless (table-
    -- constructor) functions have thrown errors replaced by "Method name is
    -- null" at the engine's throw-time stack builder - full citation in
    -- MMTraitRepair.lua beside its handler.
    --
    -- Both shapes accepted. args.usernames is the selection (what the panel
    -- sends now); args.username is the pre-bulk single-target form, kept
    -- because a client on an older Dragonfly pointed at this server would
    -- otherwise silently restore nobody. ONE capability check covers the
    -- whole batch - it is the same permission for every target.
    -- args.xpPercent is the Players tab dial. It is clamped server-side in
    -- restoreFraction, never trusted as sent, and absent means 100.
    local function handleMemoirRestore(player, args)
        args = args or {}
        if type(args.usernames) == "table" then
            return MMRestore.runMany(player, args.usernames, args.xpPercent)
        end
        return MMRestore.run(player, args.username, args.xpPercent)
    end
    DFServer.registerHandler{
        action     = "memoirRestore",
        capability = Capability.CanModifyPlayerStatsInThePlayerStatsUI,
        run = handleMemoirRestore,
    }
    print("[Dragonfly] MMRestore handler registered")
end)

return MMRestore

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
