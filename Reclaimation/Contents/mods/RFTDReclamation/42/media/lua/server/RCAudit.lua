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

-- log(action, player|nil, kv|nil)
--   action : short verb, e.g. "CLAIM", "UNCLAIM", "CLAIM-DENY", "EXPIRE"
--   player : the actor (nil for system events like expiry)
--   kv     : table of extra fields (sorted for stable output) or a string
function RCAudit.log(action, player, kv)
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
