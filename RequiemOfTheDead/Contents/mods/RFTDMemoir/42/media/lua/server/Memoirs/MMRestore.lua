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
        run = function(player, args)
            return MMRestore.run(player, args and args.username)
        end,
    }
    print("[Dragonfly] MMRestore handler registered")
end)

return MMRestore
