-- DFLog - in-memory log buffer for the admin console surface.
--
-- Sources we accept:
--   "Admin"      - actions audited by DFServer (broadcast to all admins)
--   "Error"      - errors scraped from getLuaDebuggerErrors() by DFErrorPoller
--   "Mod:<name>" - free-form lines pushed by a consumer mod
--
-- Levels: "info" / "warn" / "error" / "audit". The Console tab and the
-- bottom strip both subscribe and render from the same buffer.
--
-- Cross-admin sync: server audits broadcast via DFCore.audit, every client
-- receives, only admins see the panel so the buffer is benign for everyone.

if isServer() then return end

DFLog = DFLog or {
    entries   = {},
    capacity  = 500,
    listeners = {},
}

local function nowString()
    local ok, cal = pcall(function() return Calendar.getInstance() end)
    if not ok or not cal then return "--:--:--" end
    return string.format("%02d:%02d:%02d",
        cal:get(Calendar.HOUR_OF_DAY),
        cal:get(Calendar.MINUTE),
        cal:get(Calendar.SECOND))
end

local function notify(entry, kind)
    for _, fn in ipairs(DFLog.listeners) do
        pcall(fn, entry, kind)
    end
end

-- Push a new entry. If it duplicates the most recent line from the same
-- source, just bump that line's count instead of appending. Keeps the
-- buffer scannable when something spams.
function DFLog.push(entry)
    if not entry or not entry.text then return end
    entry.source = entry.source or "Admin"
    entry.level  = entry.level  or "info"
    entry.time   = entry.time   or nowString()
    entry.count  = 1

    local last = DFLog.entries[#DFLog.entries]
    if last and last.source == entry.source and last.text == entry.text then
        last.count = (last.count or 1) + 1
        last.time  = entry.time
        notify(last, "update")
        return last
    end

    DFLog.entries[#DFLog.entries + 1] = entry
    if #DFLog.entries > DFLog.capacity then
        table.remove(DFLog.entries, 1)
    end
    notify(entry, "push")
    return entry
end

function DFLog.clear()
    DFLog.entries = {}
    notify(nil, "clear")
end

function DFLog.subscribe(fn)
    if type(fn) == "function" then
        DFLog.listeners[#DFLog.listeners + 1] = fn
    end
end

function DFLog.unsubscribe(fn)
    for i, existing in ipairs(DFLog.listeners) do
        if existing == fn then
            table.remove(DFLog.listeners, i)
            return
        end
    end
end

-- Filter by source prefix ("Admin", "Error", "Mod") or exact match.
-- Returns a shallow copy; safe to iterate while new entries arrive.
function DFLog.snapshot(filter)
    local out = {}
    for _, e in ipairs(DFLog.entries) do
        if not filter or filter == "" or filter == "all"
            or e.source == filter
            or string.sub(e.source, 1, #filter) == filter then
            out[#out + 1] = e
        end
    end
    return out
end

function DFLog.formatLine(e)
    if not e then return "" end
    local count = (e.count and e.count > 1) and (" x" .. tostring(e.count)) or ""
    return string.format("[%s] [%s] %s%s",
        tostring(e.time or "--:--:--"),
        tostring(e.source or "?"),
        tostring(e.text or ""),
        count)
end

function DFLog.copyAllToClipboard(filter)
    local lines = {}
    for _, e in ipairs(DFLog.snapshot(filter)) do
        lines[#lines + 1] = DFLog.formatLine(e)
    end
    local text = table.concat(lines, "\n")
    local ok = pcall(function() Clipboard.setClipboard(text) end)
    if ok and DFFeedback then
        DFFeedback.good(string.format("Copied %d log lines.", #lines))
    elseif DFFeedback then
        DFFeedback.bad("Clipboard copy failed.")
    end
    return text
end

-- Receive cross-admin broadcast pushes from the server.
local function onServerCommand(module, command, args)
    if module ~= "RFTDDragonfly" then return end   -- literal: DFCore lives in Dragonfly, which is optional now that this buffer is Core infrastructure; audits only flow when the panel mod is present
    if command ~= "LogBroadcast" or not args then return end
    DFLog.push(args)
end
Events.OnServerCommand.Add(onServerCommand)
