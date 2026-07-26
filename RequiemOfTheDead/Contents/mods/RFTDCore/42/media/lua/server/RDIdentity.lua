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
            if dir and user and user ~= "" and not dirOwner[dir] then
                dirOwner[dir] = user
                if not userToDir[user] then userToDir[user] = dir end
            end
        end
        r:close()
    end)
end

local function appendClaim(dir, user)
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
