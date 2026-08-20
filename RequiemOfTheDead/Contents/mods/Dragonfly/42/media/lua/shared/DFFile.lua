-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFFile - the one place Dragonfly crosses the engine's file-read boundary.
--
-- WHY THIS IS SHARED: one canonical read path (deck layout sizes and
-- Longstrider tours) instead of two copies of the same loop and the same
-- nil-on-absent handling.
--
-- The doctrine this file was built on - "readLine/close genuinely throw
-- IOException on a disk or decoding fault" - is dead. getFileReader hands back
-- a real java.io.BufferedReader, but BufferedReader is an EXPOSED class
-- (LuaManager.java:1651), so an IOException inside readLine or close is a Java
-- BODY throw: MethodCaller swallows it, stack-traces it to the console, and
-- the call returns nil (MethodCaller.java:33-56). From Lua a read fault is
-- indistinguishable from end-of-file - the loop simply ends early. Same
-- verdict as Core's RDLog.readFirstLine.
--
-- The WRITE side needs no counterpart: getFileWriter (LuaManager.java:5523-5555)
-- returns nil for a denied path or a failed open - both of its IOException
-- sites are caught and logged inside the engine - and LuaFileWriter.write/close
-- (LuaManager.java:9850-9868) declare "throws IOException" but delegate to
-- PrintWriter, which records I/O errors on an internal flag rather than raising
-- them through Lua. Callers write directly and check nil.

DFFile = DFFile or {}

-- ---------------------------------------------------------------------------
-- Read every line of a Lua-cache file.
--
-- Returns:
--   nil       the file is absent or the path was denied
--   lines     every line the reader produced
--
-- TRUNCATION IS NOT DETECTABLE HERE. A read fault presents as early EOF (see
-- the header), so the old second return value - `complete` - was always true
-- and the two guards that fed it could never fire; both are gone. A caller
-- that needs integrity must get it from the CONTENT: Longstrider's tour file
-- carries a whole Lua chunk, and loadstring rejects a partial one. Deck layout
-- needs nothing - a short file restores the rows it holds.
--
-- getFileReader is called with createIfNull=false, so its one unguarded throw
-- site - outFile.createNewFile() at LuaManager.java:4903 - is unreachable, and
-- its stream open is caught internally (:4909-4915). An absent file is the
-- engine's normal nil result, not a failure.
-- ---------------------------------------------------------------------------
function DFFile.readLines(filename)
    local r = getFileReader(filename, false)
    if not r then return nil end

    local lines, n = {}, 0
    local line = r:readLine()
    while line do
        n = n + 1
        lines[n] = line
        line = r:readLine()
    end
    r:close()

    return lines
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
-- ---------------------------------------------------------------------------
