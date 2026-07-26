-- DFPlayerRoles_Server - per-player role assignment persistence.
--
-- Same problem the role-editor solves for role *definitions*, applied here
-- for role *assignments*. target:setRole(role) writes the live IsoPlayer
-- state but vanilla save persistence doesn't reliably carry the assignment
-- across disconnect/reconnect cycles - the player loads back in with their
-- default role and we'd have to reapply manually every time.
--
-- Fix: maintain Dragonfly_PlayerRoles.txt (username -> roleName), reapply
-- on OnServerStarted (for players already connected after a host restart)
-- and on OnPlayerConnect / OnClientConnect (for the usual reconnect case).
-- Mirrors the tab-delimited file format and reader/writer convention from
-- Dragonfly_RoleEdit_Server so the eventual copy-over into Dragonfly/ is
-- friction-free.
--
-- Public API:
--   DFPlayerRoles.assign(username, roleName)  -> { ok, reason }
--   DFPlayerRoles.clear(username)             -> { ok }
--   DFPlayerRoles.get(username)               -> roleName or nil

if not isServer() then return end

require "RDShared"   -- explicit: file-scope RD* use must not ride on load order (see MMSvShared header)

RDShared.registerMod("RFTDStaffTools", "0.7.0")   -- keep in sync with mod.info

DFPlayerRoles = DFPlayerRoles or {}

local OVERRIDES_FILE = "Dragonfly_PlayerRoles.txt"
local FIELD_DELIM    = "\t"

-- ─────────────────────────────────────────────────────────────────────────
-- File I/O - mirrors Dragonfly_RoleEdit_Server conventions
-- ─────────────────────────────────────────────────────────────────────────

local function split(s, sep)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out + 1] = s:sub(i); return out end
        out[#out + 1] = s:sub(i, j - 1)
        i = j + #sep
    end
end

local function loadOverrides()
    local result = {}
    -- Don't gate on fileExists(): on dedicated it can return false even when
    -- the file is on disk and getFileReader can open it. Trust the reader.
    local reader = getFileReader(OVERRIDES_FILE, false)
    if not reader then return result end
    while true do
        local line = reader:readLine()
        if not line then break end
        if line ~= "" then
            local f = split(line, FIELD_DELIM)
            if f[1] and f[1] ~= "" and f[2] and f[2] ~= "" then
                result[f[1]] = f[2]
            end
        end
    end
    reader:close()
    return result
end

local function saveOverrides(overrides)
    local writer = getFileWriter(OVERRIDES_FILE, true, false)
    if not writer then return end
    for username, roleName in pairs(overrides) do
        writer:write(username .. FIELD_DELIM .. roleName .. "\n")
    end
    writer:close()
end

-- In-memory cache of username -> roleName. Loaded from disk once, then kept in
-- sync by assign()/clear(). Everything reads through this, so the only disk
-- reads are the one-time load and the post-write verify in assign() - nothing
-- touches the file on a recurring basis anymore.
-- NOTE: external edits to the file while the server is running won't be seen
-- until the next boot (or call reloadOverrides()).
local _overrides = nil

local function getOverrides()
    if _overrides == nil then _overrides = loadOverrides() end
    return _overrides
end

local function reloadOverrides()
    _overrides = loadOverrides()
    return _overrides
end

-- ─────────────────────────────────────────────────────────────────────────
-- Role lookup + apply
-- ─────────────────────────────────────────────────────────────────────────

local function findRole(name)
    local ok, roles = pcall(getRoles)
    if not ok or not roles then return nil end
    for i = 0, roles:size() - 1 do
        local r = roles:get(i)
        if r and r:getName() == name then return r end
    end
    return nil
end

-- Returns true only when it actually CHANGED the live role. If the player
-- already has the right role we leave them alone: re-running setRole mid-
-- session desyncs character state (see assign() note below), and doing it
-- unconditionally on every sweep is exactly what spammed the console.
local function applyToOnline(username, roleName)
    local target = getPlayerFromUsername(username)
    if not target then return false end

    -- Cheap check first: if the live role already matches, do nothing. This
    -- avoids the mid-session setRole desync and skips the findRole scan below.
    local currentName
    pcall(function()
        local cur = target:getRole()
        if cur then currentName = cur:getName() end
    end)
    if currentName == roleName then return false end  -- already correct: no-op

    local role = findRole(roleName)
    if not role then return false end
    local ok = pcall(function() target:setRole(role) end)
    pcall(function() target:transmitModData() end)
    return ok
end

-- ─────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────

function DFPlayerRoles.assign(username, roleName)
    if not username or username == "" then
        return { ok = false, reason = "missing username" }
    end
    if not findRole(roleName) then
        return { ok = false, reason = "unknown role: " .. tostring(roleName) }
    end
    local overrides = getOverrides()
    overrides[username] = roleName
    saveOverrides(overrides)

    -- Verify the write landed by reading back from disk (one read, only on
    -- assign - never on the recurring path).
    local verify = loadOverrides()
    if verify[username] ~= roleName then
        print(string.format(
            "[Dragonfly] WARNING: override write did not persist for %s -> %s (read back %s)",
            username, roleName, tostring(verify[username])))
        return { ok = false, reason = "override file write failed (see server console)" }
    end
    print(string.format(
        "[Dragonfly] DFPlayerRoles persisted: %s -> %s (file=%s)",
        username, roleName, OVERRIDES_FILE))

    -- Deliberately NOT calling target:setRole on the live IsoPlayer. Mid-
    -- session role changes desync the target's character state - movement
    -- caps, combat-stance nimbleness, in-flight animations - because B42
    -- derives a chunk of player state from the role at character-load time
    -- and doesn't gracefully handle live swaps. Override file is the
    -- canonical assignment; reapply on next connect / next server boot.
    return { ok = true }
end

function DFPlayerRoles.clear(username)
    if not username or username == "" then return { ok = false } end
    local overrides = getOverrides()
    overrides[username] = nil
    saveOverrides(overrides)
    return { ok = true }
end

function DFPlayerRoles.get(username)
    if not username then return nil end
    return getOverrides()[username]
end

-- ─────────────────────────────────────────────────────────────────────────
-- Reapply hooks
-- ─────────────────────────────────────────────────────────────────────────

local function reapplyAll(eventName)
    local tag = eventName or "tick"
    local overrides = getOverrides()
    -- Nothing assigned: stay silent (no disk read). NOTE: B42's Kahlua does NOT
    -- expose the global next(), so `next(overrides) == nil` throws "Object tried
    -- to call nil" and aborts reapplyAll on every invocation (server-start AND
    -- every connect event) - i.e. role overrides never reapply at all. Use a
    -- pairs() probe instead, which Kahlua does support. (See RQCastBar.lua.)
    local hasAny = false
    for _ in pairs(overrides) do hasAny = true; break end
    if not hasAny then return end

    local players = getOnlinePlayers()
    if not players then return end

    local applied = 0
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local username = p:getUsername()
            local roleName = overrides[username]
            if roleName and applyToOnline(username, roleName) then
                applied = applied + 1
                print(string.format(
                    "[Dragonfly]   reapplied (%s): %s -> %s",
                    tag, username, roleName))
            end
        end
    end

    -- Only announce when we actually changed something. A connect/boot sweep
    -- that finds everyone already on the right role stays silent instead of
    -- logging a no-op.
    if applied > 0 then
        print(string.format(
            "[Dragonfly] DFPlayerRoles reapplyAll(%s): applied %d override(s)",
            tag, applied))
    end
end

-- Every connect-ish event just triggers reapplyAll. Sweeping all online
-- players is cheap and dodges having to know each event's arg shape (some
-- pass the player, some don't, some pass it as the second arg).
Events.OnServerStarted.Add(function() reapplyAll("OnServerStarted") end)

local _connectRegistered = {}
local function tryBind(eventName)
    local ev = Events[eventName]
    if ev and ev.Add then
        ev.Add(function() reapplyAll(eventName) end)
        _connectRegistered[#_connectRegistered + 1] = eventName
    end
end
tryBind("OnPlayerConnect")    -- Husbandry's preferred B42 name
tryBind("OnClientConnect")    -- legacy fallback
tryBind("OnConnected")        -- PZ_API_CATALOG canonical "player connects"
tryBind("OnCreatePlayer")     -- last-resort: fires on player object creation

-- Connect-only by design: we apply on server start and on the connect events
-- above, and NOT on any recurring timer. Binding several connect events spans
-- the join sequence, so whichever one fires after the player is ready triggers
-- the (idempotent, cache-only) sweep. The old EveryOneMinute net is gone - it
-- re-read the file and re-ran setRole on every in-game minute, which was
-- needless overhead and re-introduced the mid-session desync assign() avoids.
--
-- Residual risk: if NONE of the connect events fire after the player is fully
-- loaded in this B42 build, a reconnecting player's role won't reapply until
-- the next server start. If that ever shows up, the robust fix is a client-side
-- "hello" over OnClientCommand (which this mod already uses) the instant the
-- player loads in, with the handler calling the same online-apply path.

if #_connectRegistered > 0 then
    print("[Dragonfly] DFPlayerRoles registered reapply hook on: " ..
        table.concat(_connectRegistered, ", "))
else
    print("[Dragonfly] WARNING: no player-connect event available; " ..
        "role overrides will only apply on server-start sweep")
end

print("[Dragonfly] DFPlayerRoles_Server loaded")

-- Dragonfly v0.2.0
