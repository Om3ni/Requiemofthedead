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

MMRestore = MMRestore or {}

local DIR = "Memoirs/"

-- must mirror MMAudit's safeName so we find the same files
local function safeName(name)
    name = tostring(name or "unknown")
    return (name:gsub("[^%w%-_]", "_"))
end

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
    local ok, result = pcall(parseValue)
    if not ok then return nil, tostring(result) end
    return result
end
MMRestore.decode = decode -- exposed for the future progression-sheet tooling

-- ─────────────────────────────────────────────────────────────────────────
-- Archive read (nested layout preferred, flat fallback - mirrors MMAudit)
-- ─────────────────────────────────────────────────────────────────────────

local function readAll(path)
    local content
    pcall(function()
        local br = getFileReader(DIR .. path, false)
        if not br then return end
        local lines = {}
        while true do
            local line = br:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
        br:close()
        content = table.concat(lines, "\n")
    end)
    if content == "" then return nil end
    return content
end

local function readLatest(safe)
    return readAll(safe .. "/latest.json") or readAll(safe .. ".latest.json")
end

local function findOnlineByUsername(name)
    local found
    pcall(function()
        local players = getOnlinePlayers()
        if not players then return end
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername() == name then found = p; break end
        end
    end)
    return found
end

-- ─────────────────────────────────────────────────────────────────────────
-- The restore
-- ─────────────────────────────────────────────────────────────────────────

-- Returns DFServer's handler contract: { ok = bool, message|reason = string }.
function MMRestore.run(admin, targetUsername)
    targetUsername = tostring(targetUsername or "")
    if targetUsername == "" then return { ok = false, reason = "No target username." } end

    local target = findOnlineByUsername(targetUsername)
    if not target then
        return { ok = false, reason = targetUsername .. " must be online to restore." }
    end
    local dead = false
    pcall(function() dead = target:isDead() end)
    if dead then
        return { ok = false, reason = targetUsername .. " is dead - restore after they respawn." }
    end

    local content = readLatest(safeName(targetUsername))
    if not content then
        return { ok = false, reason = "No memoir archive found for " .. targetUsername .. "." }
    end
    local rec, derr = decode(content)
    if type(rec) ~= "table" or type(rec.snap) ~= "table" then
        MMwarn("RESTORE archive unreadable for " .. targetUsername .. ": " .. tostring(derr))
        return { ok = false, reason = "Archive for " .. targetUsername .. " is unreadable - check server console." }
    end
    -- safeName collisions map two usernames onto one file; the envelope's user
    -- field is the tiebreaker - never apply someone else's character.
    if rec.user and rec.user ~= targetUsername then
        return { ok = false, reason = "Archive belongs to '" .. tostring(rec.user) .. "', not " .. targetUsername .. "." }
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
    local preLevels = MMAudit and MMAudit.perkLevels(target) or nil
    local okApply, err = pcall(function()
        MMSnapshotCodec.applyToCharacter(target, snap, chosen, "overwrite", true) -- fullRestore
    end)
    if not okApply then
        MMwarn("RESTORE apply FAILED for " .. targetUsername .. ": " .. tostring(err))
        if MMAudit then MMAudit.log(target, "RESTORE_FAIL", {
            admin = (admin and admin.getUsername and admin:getUsername()) or "?",
            err = tostring(err) }) end
        return { ok = false, reason = "Restore failed for " .. targetUsername .. " - check server console." }
    end

    if md then md.MMRecalled = true end
    if MMServer and MMServer.pushFields then MMServer.pushFields(target) end

    -- Mirror-apply on the target's client over the existing memoir RESULT
    -- channel - MMClient already knows how to apply applyData and refresh.
    sendServerCommand(target, MMShared.MODULE, MMShared.CMD.RESULT, {
        ok = true,
        say = "My life... it all comes back to me.",
        applyData = { snap = snap, chosen = chosen, xpMode = "overwrite", fullRestore = true },
    })

    if MMAudit then
        MMAudit.log(target, "RESTORE_OK", {
            admin      = (admin and admin.getUsername and admin:getUsername()) or "?",
            archiveT   = rec.t,
            lvlsBefore = preLevels,
            lvlsAfter  = MMAudit.perkLevels(target),
            postXP     = MMAudit.perkXP(target),
            snap       = snap,
        })
        MMAudit.scheduleRecheck(target, nil)
    end
    return { ok = true, message = "Restored " .. targetUsername
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
function MMRestore.runMany(admin, usernames)
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
    if #targets == 1 then return MMRestore.run(admin, targets[1]) end

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
        local called, res = pcall(MMRestore.run, admin, name)
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
        run = function(player, args)
            args = args or {}
            if type(args.usernames) == "table" then
                return MMRestore.runMany(player, args.usernames)
            end
            return MMRestore.run(player, args.username)
        end,
    }
    print("[Dragonfly] MMRestore handler registered")
end)

return MMRestore
