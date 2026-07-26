-- RDIdentity.lua - stable filesystem identities for players (server only).
--
-- Usernames can contain anything; filenames cannot. The naive fix
-- (gsub("[^%w%-_]", "_")) has a collision: "Bob.Smith" and "Bob_Smith" both
-- map to "Bob_Smith" and would interleave into one stream. The fix is an
-- APPEND-ONLY claim ledger: the first user to produce a slug owns it forever
-- (recorded in RFTD/slugs.tsv as "slug<TAB>username"); a later user whose base
-- slug is already claimed gets "<base>~N". The base mapping can never emit
-- "~", so suffixed slugs cannot collide with anything.
--
-- The ledger is loaded once, lazily; every mapping decided in-session is
-- appended immediately (open-append-close - durable under a force-kill).
-- The username also rides on every chronicle record ("u"), so even a ledger
-- disaster loses convenience, not attribution.

if not isServer() then return end

RDIdentity = RDIdentity or {}

local FILE = RDShared.DIR .. "slugs.tsv"

local userToSlug = nil   -- username -> slug (lazy-loaded)
local slugOwner  = nil   -- slug -> username

local function baseSlug(name)
    name = tostring(name or "unknown")
    local s = name:gsub("[^%w%-_]", "_")
    if s == "" then s = "unknown" end
    return s
end

local function loadLedger()
    userToSlug, slugOwner = {}, {}
    pcall(function()
        local r = getFileReader(FILE, false)
        if not r then return end
        for _ = 1, 1000000 do   -- bounded: no while-true on a file we didn't write this session
            local line = r:readLine()
            if line == nil then break end
            local slug, user = line:match("^([^\t]+)\t(.*)$")
            if slug and user and user ~= "" and not slugOwner[slug] then
                slugOwner[slug] = user
                if not userToSlug[user] then userToSlug[user] = slug end
            end
        end
        r:close()
    end)
end

local function appendClaim(slug, user)
    pcall(function()
        local w = getFileWriter(FILE, true, true)
        if w then
            w:write(slug .. "\t" .. user .. "\n")
            w:close()
        end
    end)
end

-- The one public call: username -> stable slug, claiming it if new.
function RDIdentity.slugFor(username)
    if not userToSlug then loadLedger() end
    local user = tostring(username or "unknown")
    local known = userToSlug[user]
    if known then return known end

    local base = baseSlug(user)
    local slug = base
    local n = 1
    while slugOwner[slug] do
        n = n + 1
        slug = base .. "~" .. n
    end
    userToSlug[user] = slug
    slugOwner[slug] = user
    appendClaim(slug, user)
    return slug
end

return RDIdentity
