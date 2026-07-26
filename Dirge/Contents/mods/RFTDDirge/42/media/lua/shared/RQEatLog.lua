-- RQEatLog.lua - compatibility shim
-- All shared Lua files are autoloaded by PZ regardless of require().
-- This file MUST NOT contain io.open or any file I/O — io is nil in
-- the Kahlua client sandbox and the exception crashes the tick loop.
-- All calls are forwarded to RQDirgeLog (the actual logger).

RQEatLog = {
    write = function(msg)
        if RQDirgeLog and RQDirgeLog.write then
            RQDirgeLog.write("System", msg)
        else
            print("[RQEatLog:shim] " .. tostring(msg))
        end
    end,
    flush = function()
        if RQDirgeLog and RQDirgeLog.flush then
            RQDirgeLog.flush()
        end
    end,
}

-- Copyright Project_Omen
