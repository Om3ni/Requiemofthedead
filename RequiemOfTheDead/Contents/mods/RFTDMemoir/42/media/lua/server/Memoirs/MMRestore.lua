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
--   * Once per life, same gate as memoir reads (modData.MMRecalled): the additive
--     overwrite model double-counts if applied twice to one life (the second
--     apply reads the first restore as "this life's earnings"). Death re-arms.
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

local function decode(s)
    local pos = 1
    local function fail(msg) error(msg .. " at " .. tostring(pos)) end
    local function skipWs()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then break end
            pos = pos + 1
        end
    end
    local function isNumChar(c)
        return c == "-" or c == "+" or c == "." or c == "e" or c == "E"
            or (c >= "0" and c <= "9")
    end
    local function parseString()
        pos = pos + 1 -- opening quote
        local out = {}
        while true do
            if pos > #s then fail("unterminated string") end
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = s:sub(pos + 1, pos + 1)
                if n == "n" then out[#out + 1] = "\n"
                elseif n == "r" then out[#out + 1] = "\r"
                elseif n == "t" then out[#out + 1] = "\t"
                else out[#out + 1] = n end -- \" \\ and anything else: literal
                pos = pos + 2
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    local parseValue
    parseValue = function()
        skipWs()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skipWs()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skipWs()
                if s:sub(pos, pos) ~= '"' then fail("expected object key") end
                local k = parseString()
                skipWs()
                if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
                pos = pos + 1
                obj[k] = parseValue()
                skipWs()
                local d = s:sub(pos, pos)
                if d == "," then pos = pos + 1
                elseif d == "}" then pos = pos + 1; break
                else fail("expected ',' or '}'") end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skipWs()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skipWs()
                local d = s:sub(pos, pos)
                if d == "," then pos = pos + 1
                elseif d == "]" then pos = pos + 1; break
                else fail("expected ',' or ']'") end
            end
            return arr
        elseif c == '"' then
            return parseString()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        elseif isNumChar(c) then
            local startPos = pos
            while pos <= #s and isNumChar(s:sub(pos, pos)) do pos = pos + 1 end
            local n = tonumber(s:sub(startPos, pos - 1))
            if n == nil then fail("bad number") end
            return n
        end
        fail("unexpected character '" .. tostring(c) .. "'")
    end
    -- guarded because error() IS this parser's control flow - fail() above raises on
    -- malformed input, and this is where it is turned back into a return value.
    local ok, result = pcall(parseValue)
    if not ok then return nil, tostring(result) end
    return result
end
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

-- Returns DFServer's handler contract: { ok = bool, message|reason = string }.
function MMRestore.run(admin, targetUsername, xpPercent)
    targetUsername = tostring(targetUsername or "")
    if targetUsername == "" then return { ok = false, reason = "No target username." } end
    local xpFrac, xpPct = restoreFraction(xpPercent)

    local target = MMRoster.findOnline(targetUsername)
    if not target then
        return { ok = false, reason = targetUsername .. " must be online to restore." }
    end
    if target:isDead() then
        return { ok = false, reason = targetUsername .. " is dead - restore after they respawn." }
    end

    local rec, archiveState, archiveDetail = readLatest(safeName(targetUsername), targetUsername)
    if archiveState == "missing" then
        return { ok = false, reason = "No memoir archive found for " .. targetUsername .. "." }
    end
    if archiveState == "unreadable" then
        MMwarn("RESTORE archive unreadable for " .. targetUsername .. ": " .. tostring(archiveDetail))
        return { ok = false, reason = "Archive for " .. targetUsername .. " is unreadable - check server console." }
    end
    if archiveState == "owner" then
        return { ok = false, reason = "Archive belongs to '" .. tostring(archiveDetail)
            .. "', not " .. targetUsername .. "." }
    end

    local snap = rec.snap
    -- The archive stores recipes normalized to a sorted LIST; the codec expects
    -- the live snapshot's SET shape. Denormalize before applying.
    if snap.recipes and #snap.recipes > 0 then
        local set = {}
        for _, id in ipairs(snap.recipes) do set[id] = true end
        snap.recipes = set
    end

    -- Same once-per-life gate as memoir reads - a second additive apply on one
    -- life double-counts everything the first restore delivered. Death re-arms.
    local md = target:getModData()
    if md and md.MMRecalled then
        return { ok = false, reason = targetUsername
            .. " already recalled/restored this life. Death re-arms the gate." }
    end

    local chosen = { profession = snap.profession, traits = snap.traits }
    local preProgress = MMAudit and MMAudit.sampleProgression(target) or nil
    -- fullRestore, with the dial as an explicit fraction. xpFrac is 1.0 when no
    -- dial was sent, so this is byte-for-byte the old 100% behaviour by default.
    local apply = MMSnapshotCodec.applyToCharacter(target, snap, chosen, "overwrite", true, xpFrac)
    if not apply.ok then
        if apply.partial then
            if md then md.MMRecalled = true end
            if MMServer and MMServer.pushFields then MMServer.pushFields(target) end
        end
        MMwarn("RESTORE apply FAILED for " .. targetUsername .. " (phase="
            .. tostring(apply.phase) .. ", partial=" .. tostring(apply.partial)
            .. "): " .. tostring(apply.error))
        if MMAudit then
            local postProgress = MMAudit.sampleProgression(target)
            MMAudit.log(target, "RESTORE_FAIL", MMAudit.attachProgression({
            admin = (admin and admin.getUsername and admin:getUsername()) or "?",
            phase = apply.phase, partial = apply.partial, err = tostring(apply.error)
            }, preProgress, postProgress))
        end
        if apply.partial then
            return { ok = false, reason = "Restore partially changed " .. targetUsername
                .. ". Do not retry; have them relog and check the forensic record." }
        end
        return { ok = false, reason = "Restore preflight failed for " .. targetUsername
            .. "; nothing changed. Check server console." }
    end

    if md then md.MMRecalled = true end
    if MMServer and MMServer.pushFields then MMServer.pushFields(target) end

    -- Mirror-apply on the target's client over the existing memoir RESULT
    -- channel - MMClient already knows how to apply applyData and refresh.
    -- xpFraction MUST travel with the mirror: the client recomputes the same
    -- targets from the same snapshot, and a mirror that defaulted to 100% while
    -- the server applied 60% would desync the character until relog.
    sendServerCommand(target, MMShared.MODULE, MMShared.CMD.RESULT, {
        ok = true,
        say = "My life... it all comes back to me.",
        applyData = { snap = snap, chosen = chosen, xpMode = "overwrite", fullRestore = true,
                      xpFraction = xpFrac },
    })

    if MMAudit then
        local postProgress = MMAudit.sampleProgression(target)
        MMAudit.log(target, "RESTORE_OK", MMAudit.attachProgression({
            admin      = (admin and admin.getUsername and admin:getUsername()) or "?",
            -- The dial is recorded because a restore at anything but 100% is a
            -- deliberate policy act (a season migration allowance, say), and
            -- "why is my carpentry lower than my old character" is unanswerable
            -- a month later without it.
            xpPct      = xpPct,
            archiveT   = rec.t,
            snap       = snap,
        }, preProgress, postProgress))
        MMAudit.scheduleRecheck(target, nil, postProgress)
    end
    local pctNote = (xpPct ~= 100) and (" at " .. xpPct .. "% of earned XP") or ""
    return { ok = true, message = "Restored " .. targetUsername .. pctNote
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
    DFServer.registerHandler{
        action     = "memoirRestore",
        capability = Capability.CanModifyPlayerStatsInThePlayerStatsUI,
        -- Both shapes accepted. args.usernames is the selection (what the panel
        -- sends now); args.username is the pre-bulk single-target form, kept
        -- because a client on an older Dragonfly pointed at this server would
        -- otherwise silently restore nobody. ONE capability check covers the
        -- whole batch - it is the same permission for every target.
        -- args.xpPercent is the Players tab dial. It is clamped server-side in
        -- restoreFraction, never trusted as sent, and absent means 100.
        run = function(player, args)
            args = args or {}
            if type(args.usernames) == "table" then
                return MMRestore.runMany(player, args.usernames, args.xpPercent)
            end
            return MMRestore.run(player, args.username, args.xpPercent)
        end,
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
