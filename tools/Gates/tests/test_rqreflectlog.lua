-- RQReflectLog fixture - exact LuaFileWriter contract and session framing.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL RQReflectLog: " .. message)
    end
end

local gameStartCallbacks = {}
Events = { OnGameStart = { Add = function(fn) gameStartCallbacks[#gameStartCallbacks + 1] = fn end } }

function isServer() return false end
function getTimestampMs() return 3723000 end

local writerMode = "ok"
local writes = {}
local opened = {}
function getFileWriter(filename, createIfNull, append)
    opened[#opened + 1] = { filename = filename, createIfNull = createIfNull, append = append }
    if writerMode == "nil" then return nil end
    return {
        write = function(_, line)
            writes[#writes + 1] = line
        end,
        close = function() end,
    }
end

RQReflectLog = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#gameStartCallbacks == 1, "module registers one session-reset handler")

RQReflectLog.writeAll({ "FIRST", "SECOND" })
check(#opened == 1 and opened[1].filename == "Dirge_Reflect_CL.txt", "opens the client reflection file")
check(#writes == 3 and string.find(writes[1], "session start", 1, true), "marks the session once before entries")
check(string.find(writes[2], "FIRST", 1, true) and string.find(writes[3], "SECOND", 1, true),
    "writes every supplied line with a stamp")

RQReflectLog.write("THIRD")
check(#writes == 4 and string.find(writes[4], "THIRD", 1, true), "single-line write reuses writeAll")

gameStartCallbacks[1]()
RQReflectLog.write("AFTER RESET")
check(#writes == 6 and string.find(writes[5], "session start", 1, true), "game start resets the session marker")

writerMode = "nil"
RQReflectLog.write("NO WRITER")
check(#writes == 6, "nil writer is a normal skipped forensic write")

realPrint(string.format("RQReflectLog: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
