-- DFErrorPoller - taps getLuaDebuggerErrors() and pushes new lines to DFLog.
--
-- Polls on OnTickEvenPaused so errors surface even when the game is paused or
-- in a menu. Dedup is by hash of the raw string; identical errors don't spam
-- the buffer (DFLog.push handles repeat counting).
--
-- If an error line carries a ((MOD:modid)) attribution tag, the source becomes
-- "Mod:<id>"; otherwise it's just "Error".

if isServer() then return end

DFErrorPoller = DFErrorPoller or { seen = {}, lastSize = 0 }

local function extractModTag(text)
    local tag = string.match(tostring(text or ""), "%(%(MOD:([^)]+)%)%)")
    if tag and tag ~= "" then return "Mod:" .. tag end
    return "Error"
end

local function levelFor(text)
    local t = tostring(text or "")
    if string.find(t, "ERROR", 1, true) or string.find(t, "Exception", 1, true)
        or string.find(t, "java.lang.", 1, true) then
        return "error"
    end
    if string.find(t, "WARN", 1, true) then return "warn" end
    return "info"
end

-- Collapse multi-line stack traces into a single readable line so the log
-- strip (which uses drawText without newline-awareness) doesn't render
-- every line at the same Y coordinate. We keep the most informative head
-- (first non-empty line + first "Caused by" if present) and drop the
-- repeating Java frames - those are still in the server console log if
-- anyone needs the full trace.
local function normalize(text)
    if not text then return "" end
    local clean = string.gsub(tostring(text), "[\r\n]+", " | ")
    clean = string.gsub(clean, "%s+", " ")
    if #clean > 240 then clean = string.sub(clean, 1, 237) .. "..." end
    return clean
end

local function poll()
    if not DFLog then return end
    local errors
    local ok = pcall(function() errors = getLuaDebuggerErrors() end)
    if not ok or not errors then return end

    local size = errors:size()
    if size == DFErrorPoller.lastSize then return end
    DFErrorPoller.lastSize = size

    for i = 0, size - 1 do
        local entry
        pcall(function() entry = errors:get(i) end)
        if entry then
            local raw  = tostring(entry)
            local hash = #raw .. ":" .. string.sub(raw, 1, 80)
            if not DFErrorPoller.seen[hash] then
                DFErrorPoller.seen[hash] = true
                DFLog.push{
                    source = extractModTag(raw),
                    level  = levelFor(raw),
                    text   = normalize(raw),
                }
            end
        end
    end
end

Events.OnTickEvenPaused.Add(poll)
