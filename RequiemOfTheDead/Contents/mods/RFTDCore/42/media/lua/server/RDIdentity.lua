-- RDIdentity.lua - stable filesystem identities for players (server only).
--
-- Each player owns one directory per season: <SafeName>.<SteamID>, e.g.
-- chronicle/p/MoaKami.76561198012345680/. The SteamID suffix makes the name
-- collision-proof across accounts (two different "Bob Smith"s sanitize to the
-- same SafeName but never share a SteamID) and rename-resistant.
--
-- SteamID caveat (same one GuardianLogger documents): getSteamID() returns a
-- Java long that exceeds Lua's exact-integer range (2^53), so through Lua it
-- is ALWAYS a lossy double and no server-side global yields the exact string.
-- The %.0f render used here is deterministic and STABLE per account - a fine
-- directory identity - but it is an approximation: never treat it as a ban
-- key. The exact id lives in the engine's cmd.txt, joinable on username.
--
-- Claims are recorded in an APPEND-ONLY ledger (RFTD/slugs.tsv, one
-- "dir<TAB>username" line per claim) so writes that only know a username
-- (offline events, system rows) resolve to the same directory the player
-- claimed while online. When a directory must be minted with no SteamID
-- available, a taken name gets "~N" - the base mapping can never emit "~",
-- so suffixed names cannot collide with anything.
--
-- LEDGER INTEGRITY. The format is line-and-tab delimited and the username is
-- written verbatim, so the two delimiters are not equally safe:
--
--   TAB is safe and deliberately allowed. loadLedger anchors on the FIRST tab
--   and (.*) swallows the remainder, so "Bob<TAB>Smith" round-trips intact.
--
--   NEWLINE is not. It splits one claim across two physical lines, and the
--   tail fragment parses as a WELL-FORMED claim of its own - so a crafted
--   username ("x\nSomeDir\tvictim") injects an arbitrary dir->user mapping and
--   can point another player's name at a directory of its choosing. PZ Lua has
--   no delete primitive (see RDLog's rotation note), so a poisoned line is
--   permanent. The write is therefore REFUSED rather than escaped: escaping
--   would change the lookup key and re-mint a directory for every player whose
--   name contains the escape character. A refused claim still gets a working
--   in-memory directory for the session; it just isn't persisted.
--
-- In practice `user` always arrives from the engine's getUsername(), so this
-- is defence against an assumption we do not control rather than an observed
-- attack. The read side additionally shape-checks the dir field, which is a
-- known alphabet (safeName's output, plus "." before a SteamID and "~N" for
-- suffixes) - anything else was not written by this file.

if not isServer() then return end

RDIdentity = RDIdentity or {}

local FILE = RDShared.DIR .. "slugs.tsv"

local userToDir = nil   -- username -> dir (lazy-loaded)
local dirOwner  = nil   -- dir -> username

local function safeName(name)
    name = tostring(name or "unknown")
    local s = name:gsub("[^%w%-_]", "_")
    if s == "" then s = "unknown" end
    return s
end

-- A username safe to persist: no line break can reach the ledger. See the
-- LEDGER INTEGRITY note in the header for why this refuses rather than escapes.
local function ledgerSafe(user)
    return not tostring(user):find("[\r\n]")
end

-- The dir field's full alphabet: safeName output ([%w%-_]) plus "." joining a
-- SteamID and "~" introducing a collision suffix. A line outside it was not
-- written by appendClaim.
local function dirShapeOk(dir)
    return dir:match("^[%w%-_.~]+$") ~= nil
end

-- Best-effort SteamID as a stable digit string; nil when unavailable
-- (no player object, dedi without Steam, lookup failure).
function RDIdentity.sidApprox(player)
    if type(player) == "string" or player == nil then return nil end
    local ok, s = pcall(function()
        local id = player:getSteamID()
        if not id or id == 0 then return nil end
        return string.format("%.0f", id)
    end)
    if ok and s and s ~= "0" then return s end
    return nil
end

local function loadLedger()
    userToDir, dirOwner = {}, {}
    pcall(function()
        local r = getFileReader(FILE, false)
        if not r then return end
        for _ = 1, 1000000 do   -- bounded: no while-true on a file we didn't write this session
            local line = r:readLine()
            if line == nil then break end
            local dir, user = line:match("^([^\t]+)\t(.*)$")
            -- A stray \r survives readLine on a CRLF-written ledger and would
            -- otherwise become part of the username key.
            if user then user = user:gsub("\r+$", "") end
            if dir and user and user ~= "" and dirShapeOk(dir)
               and ledgerSafe(user) and not dirOwner[dir] then
                dirOwner[dir] = user
                if not userToDir[user] then userToDir[user] = dir end
            end
        end
        r:close()
    end)
end

local function appendClaim(dir, user)
    if not ledgerSafe(user) then
        print("[RFTDCore] RDIdentity: refusing to persist a claim whose username "
            .. "contains a line break (dir=" .. tostring(dir) .. "). The session "
            .. "directory still works; it will be re-minted next boot.")
        return
    end
    pcall(function()
        local w = getFileWriter(FILE, true, true)
        if w then
            w:write(dir .. "\t" .. user .. "\n")
            w:close()
        end
    end)
end

local function usernameOf(subj)
    if type(subj) == "string" then return subj end
    if subj ~= nil then
        local ok, name = pcall(function() return subj:getUsername() end)
        if ok and name then return tostring(name) end
    end
    return "unknown"
end

-- The one public call: player (IsoPlayer or username string) -> directory
-- name, claiming it on first sight. Pass the PLAYER OBJECT whenever one
-- exists - that is what lets the SteamID into the name; a string subject can
-- only reuse an existing claim or mint a SteamID-less fallback.
function RDIdentity.dirFor(subj)
    if not userToDir then loadLedger() end
    local user = usernameOf(subj)
    local known = userToDir[user]
    if known then return known end

    local base = safeName(user)
    local sid  = RDIdentity.sidApprox(subj)
    local dir
    if sid then
        dir = base .. "." .. sid
        -- Same account re-claiming under a changed username keeps its own
        -- directory; a genuinely different account never lands here because
        -- SteamIDs differ. An exact duplicate means the ledger already knows
        -- this pair under another username spelling - suffix rather than mix.
        while dirOwner[dir] do dir = dir .. "~2" end
    else
        dir = base
        local n = 1
        while dirOwner[dir] do
            n = n + 1
            dir = base .. "~" .. n
        end
    end
    userToDir[user] = dir
    dirOwner[dir] = user
    appendClaim(dir, user)
    return dir
end

return RDIdentity
