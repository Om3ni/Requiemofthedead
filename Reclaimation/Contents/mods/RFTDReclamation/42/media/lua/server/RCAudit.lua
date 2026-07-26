-- RCAudit - durable append-only ledger (server only).
--
-- getFileWriter is the ONLY working B42 server-side file I/O (raw io.open is
-- silently blocked). Every authoritative claim mutation writes one
-- bracket-stamped key=value line here, so cheating / disputes are resolved by
-- the ledger rather than by fragile server-veto.

if not isServer() then return end

RCAudit = RCAudit or {}

local FILE = "RFTDReclamation_Dismantle.txt"

local function stamp()
    local ok, s = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok and s then return s end
    return tostring(os.time())
end

-- DUAL-WRITE (RFTDCore adoption, transition state): every event still writes
-- the legacy line below - byte-identical format, same file - AND lands in
-- Core's forensic ring ("rc" stream, structured). Claim-lifecycle events
-- additionally become chronicle records in the owner's permanent per-player
-- record. The legacy line retires as a separate, verifiable step once a real
-- season has proven the new path; until then old and new are directly
-- comparable.
local CHRONICLE = {
    CLAIM   = "RC.VEHICLE_CLAIM",
    UNCLAIM = "RC.VEHICLE_RELEASE",
    EXPIRE  = "RC.VEHICLE_EXPIRE",
}

-- The chronicle subject is the CLAIM HOLDER, not necessarily the actor:
-- EXPIRE has no player object (kv.user carries the owner) and a staff release
-- carries kv.owner. The actor stays visible in the payload either way.
local function chronicleSubject(player, kv)
    if type(kv) == "table" then
        if kv.owner and kv.owner ~= "-" then return kv.owner end
        if kv.user and kv.user ~= "-" then return kv.user end
    end
    return player
end

local function coreWrite(action, player, kv)
    local data = (type(kv) == "table") and kv or { note = tostring(kv or "") }
    RDLog.forensic("rc", "RC." .. tostring(action), player or data.user or data.owner, data)
    local evt = CHRONICLE[action]
    if evt then
        RDLog.chronicle(evt, chronicleSubject(player, kv), data)
    end
end

-- log(action, player|nil, kv|nil)
--   action : short verb, e.g. "CLAIM", "UNCLAIM", "CLAIM-DENY", "EXPIRE"
--   player : the actor (nil for system events like expiry)
--   kv     : table of extra fields (sorted for stable output) or a string
function RCAudit.log(action, player, kv)
    pcall(coreWrite, action, player, kv)

    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
    if not ok or not writer then return end

    local user = (player and player.getUsername and player:getUsername()) or "-"
    local parts = { string.format("[%s] action=%s user=%s", stamp(), tostring(action), tostring(user)) }

    if type(kv) == "table" then
        local keys = {}
        for k in pairs(kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(kv[k]))
        end
    elseif kv ~= nil then
        parts[#parts + 1] = tostring(kv)
    end

    pcall(function()
        writer:write(table.concat(parts, " ") .. "\n")
        writer:close()
    end)
end
