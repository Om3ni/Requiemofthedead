-- RQDirgeLog.lua - per-type diagnostic logs for Dirge
-- One file per zombie type, overwritten each session:
--   Dirge_Glutton.txt, Dirge_Scavenger.txt, Dirge_Screamer.txt
--   Dirge_Juggernaut.txt, Dirge_EMP.txt, Dirge_Boss.txt, Dirge_System.txt
--
-- Usage: RQDirgeLog.write("Glutton", "[INFO] something happened")
--        RQDirgeLog.write("Screamer", "[WARN] getSearchMode() returned nil")
--        RQDirgeLog.write("EMP", "[ERROR] blast target nil")

RQDirgeLog = RQDirgeLog or {}

-- Master kill-switch for diagnostic logging. When false, RQDirgeLog.write is a
-- no-op: no in-game print, no file write, no writer ever opened. Flip to true
-- when bug-hunting; flip back when done. Skips the work at the source so we
-- don't have to gate or strip the 96-odd call sites scattered across modules.
RQDirgeLog.ENABLED = false

local _writers   = {}   -- zType -> PrintWriter-compatible or false
local _counts    = {}   -- zType -> line count (for periodic flush)
local _side      = isServer() and "SV" or "CL"
local _homeDir   = nil

local function getHomeDir_cached()
    if _homeDir then return _homeDir end
    local ok, d = pcall(getHomeDir)
    _homeDir = (ok and d) or "./"
    return _homeDir
end

local function openWriter(zType)
    if _writers[zType] ~= nil then return _writers[zType] end

    local path = getHomeDir_cached() .. "Dirge_" .. zType .. ".txt"
    _counts[zType] = 0

    -- luajava: Kahlua's Java interop (server sandbox only; nil on client — pre-check avoids
    -- Kahlua printing a Java stack trace even when pcall would catch the nil-index error)
    local ok1, pw = false, nil
    if luajava then
        ok1, pw = pcall(function()
            local fw = luajava.newInstance("java.io.FileWriter",  path, false)
            return    luajava.newInstance("java.io.PrintWriter", fw)
        end)
    end
    if ok1 and pw then
        _writers[zType] = pw
        pw:println("=== Dirge " .. zType .. " [" .. _side .. "] ===")
        pw:flush()
        print("[RQDirgeLog] " .. zType .. " -> " .. path)
        return pw
    end

    -- fallback: standard io (available on dedicated-server Lua, not client sandbox)
    if io and io.open then
        local f = io.open(path, "w")
        if f then
            local w = {
                println = function(_, s) f:write(s .. "\n") end,
                flush   = function(_)    f:flush()           end,
                close   = function(_)    f:close()           end,
            }
            _writers[zType] = w
            w:println("=== Dirge " .. zType .. " [" .. _side .. "] ===")
            w:flush()
            return w
        end
    end

    print("[RQDirgeLog] " .. zType .. ": no file I/O available, print-only mode")
    _writers[zType] = false
    return false
end

function RQDirgeLog.write(zType, msg)
    if not RQDirgeLog.ENABLED then return end
    local ts   = tostring(getTimestampMs and getTimestampMs() or 0)
    local line = "[" .. ts .. "][" .. _side .. "] " .. msg
    print("[Dirge:" .. zType .. "] " .. line)

    local w = openWriter(zType)
    if not w then return end

    local ok, err = pcall(function()
        w:println(line)
        _counts[zType] = (_counts[zType] or 0) + 1
        if _counts[zType] % 10 == 0 then w:flush() end
    end)
    if not ok then
        print("[RQDirgeLog] write error (" .. zType .. "): " .. tostring(err))
        _writers[zType] = nil  -- force reopen
    end
end

function RQDirgeLog.flush()
    for zType, w in pairs(_writers) do
        if w and w ~= false then pcall(function() w:flush() end) end
    end
end

local function closeAll()
    for zType, w in pairs(_writers) do
        if w and w ~= false then
            pcall(function()
                w:println("=== session end ===")
                w:flush()
                w:close()
            end)
        end
    end
    _writers  = {}
    _counts   = {}
    _homeDir  = nil
end

Events.OnGameStart.Add(closeAll)

-- backward-compat shim so any lingering RQEatLog.write(...) calls don't crash
RQEatLog = { write = function(msg) RQDirgeLog.write("System", msg) end }

-- Copyright Project_Omen
