-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCNoPark - places a replacement vehicle must never be put (server only).
--
-- WHY A LIST AND NOT A RULE. Vehicle zones get painted inside buildings, and
-- most of those are fine: a fire station apparatus bay or a dealership showroom
-- is a parking space and vanilla fills it. A blanket "outdoors only" test was
-- tried first and thrown out - it also refused every carport and overhang, and
-- it guessed at a problem instead of measuring one. So indoor stalls stay legal
-- and the exceptions are recorded as they are found. A rule that guesses is
-- worse than a list that knows.
--
-- WHERE IT LIVES. Rectangles are appended to a plain text file next to the
-- audit ledger, one per line, in the order they were marked:
--
--     x,y,z,w,h,label
--
-- Deliberately the flattest format that survives a hand edit, because it has a
-- second life: once a season has collected a real list, those lines get pasted
-- into BUILTIN below and ship with the mod, so a fresh server starts already
-- knowing the bad rooms. The file and the table are read the same way, and
-- entries in either are indistinguishable at query time.
--
-- getFileWriter is the only working server-side write in B42 (RCAudit's header
-- has the detail) and its extension allowlist is ini|cfg|txt|log, CASE
-- SENSITIVE - hence .txt.
--
-- MARKING IS BY ROOM, NOT BY BRUSH. An admin standing in the offending garage
-- presses one button and the room's own bounding box is recorded. The chain is
-- all methods and so all reachable: square:getRoom() -> IsoRoom:getRoomDef()
-- (IsoRoom.java:450) -> RoomDef:getX/getY/getW/getH/getName (RoomDef.java:224-244).
-- No painting UI, no coordinate typing, and the result is exactly the shape the
-- building actually is rather than a guessed square around the player.

if not isServer() then return end

require "RCShared"

RCNoPark = RCNoPark or {}

local FILE = "RFTDReclamation_NoPark.txt"

-- Shipped exclusions. Empty on purpose: everything here should have been
-- EARNED by a real report. Paste collected lines from the file into this table
-- when promoting them, keeping the label - it is the only record of why.
--   { x = 0, y = 0, z = 0, w = 0, h = 0, label = "why" },
RCNoPark.BUILTIN = {
}

local rects = nil   -- BUILTIN + file, resolved once per session

local function parseLine(line)
    if type(line) ~= "string" then return nil end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:sub(1, 1) == "#" then return nil end
    local x, y, z, w, h, label = line:match(
        "^(-?%d+),(-?%d+),(-?%d+),(%d+),(%d+),?(.*)$")
    if not x then return nil end
    w, h = tonumber(w), tonumber(h)
    -- A zero-area rect would match nothing and silently look like it worked.
    if w < 1 or h < 1 then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z),
             w = w, h = h, label = (label ~= "" and label or nil) }
end

local function load()
    rects = {}
    for _, r in ipairs(RCNoPark.BUILTIN) do
        if r.w and r.h and r.w > 0 and r.h > 0 then rects[#rects + 1] = r end
    end
    local builtin = #rects

    local reader
    -- createIfNull false: a server that has never marked anything should not
    -- have a mystery empty file appear next to its ledger.
    -- guarded: file I/O through the getFileReader allowlist can throw
    if not pcall(function() reader = getFileReader(FILE, false) end) or not reader then
        RCShared.dbg("nopark: %d built-in, no file yet", builtin)
        return
    end
    local bad = 0
    -- guarded: disk reads; a truncated or vanished file must fall back to the
    -- built-ins already collected
    pcall(function()
        local line = reader:readLine()
        while line do
            local r = parseLine(line)
            if r then rects[#rects + 1] = r
            elseif line ~= "" and line:sub(1, 1) ~= "#" then bad = bad + 1 end
            line = reader:readLine()
        end
    end)
    -- guarded: close on a handle whose read may already have failed
    pcall(function() reader:close() end)

    -- Malformed lines are COUNTED, not swallowed. This file is meant to be hand
    -- edited, and a typo that silently drops an exclusion would present as "the
    -- Janitor keeps parking in my garage again".
    print(string.format("[RC] NoPark: %d exclusion(s) - %d built-in, %d from file%s",
        #rects, builtin, #rects - builtin,
        bad > 0 and string.format(", %d UNREADABLE line(s)", bad) or ""))
end

-- Force a re-read (after an add, or an admin hand-editing the file).
function RCNoPark.reload() rects = nil end

function RCNoPark.all()
    if not rects then load() end
    return rects
end

-- Is this tile inside any excluded rectangle? Called per candidate tile by
-- RCParking.canPlace, so it stays a plain array walk - the list is human-sized
-- by construction (one entry per complaint) and will never be long enough to
-- justify an index.
function RCNoPark.blocks(x, y, z)
    if not rects then load() end
    if #rects == 0 then return false end
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    for i = 1, #rects do
        local r = rects[i]
        if z == r.z and x >= r.x and x < r.x + r.w
                    and y >= r.y and y < r.y + r.h then
            return true, r.label
        end
    end
    return false
end

-- Append one rectangle. Returns true, or nil plus a reason.
function RCNoPark.add(x, y, z, w, h, label)
    if not (x and y and w and h) or w < 1 or h < 1 then return nil, "bad rect" end
    -- Commas and newlines would corrupt the line format; the label is free text
    -- typed by nobody in particular, so it is sanitised rather than trusted.
    label = tostring(label or "marked"):gsub("[,\r\n]", " "):sub(1, 60)

    local writer
    -- guarded: file I/O through the getFileWriter allowlist can throw
    if not pcall(function() writer = getFileWriter(FILE, true, true) end) or not writer then
        return nil, "cannot write " .. FILE
    end
    -- guarded: disk write; the caller gets "write failed" instead of an error
    local ok = pcall(function()
        writer:writeln(string.format("%d,%d,%d,%d,%d,%s",
            math.floor(x), math.floor(y), math.floor(z or 0),
            math.floor(w), math.floor(h), label))
    end)
    -- guarded: close on a handle whose write may already have failed
    pcall(function() writer:close() end)
    if not ok then return nil, "write failed" end

    RCNoPark.reload()
    return true
end

-- Mark the room the player is standing in. Returns the rect, or nil plus a
-- reason the admin can act on.
function RCNoPark.addRoomAt(player)
    if not player then return nil, "no player" end
    local sq = player:getSquare()
    if not sq then return nil, "no square under you" end

    -- getRoom null-checks its id (IsoGridSquare.java:8013); getRoomDef and the
    -- RoomDef bounds/name are field returns (IsoRoom.java:450, RoomDef.java:210-245)
    local room = sq:getRoom()
    local def = room and room:getRoomDef()
    -- Outdoors has no room, and that is the common misfire: an admin standing
    -- in the car park rather than the garage. Say which, so the next press is
    -- from the right place.
    if not def then return nil, "you are not inside a room - stand in the garage" end

    local x, y, w, h = def:getX(), def:getY(), def:getW(), def:getH()
    local name = def:getName()
    if not (x and y and w and h) or w < 1 or h < 1 then
        return nil, "could not read this room's bounds"
    end

    local z = math.floor(sq:getZ())

    local added, why = RCNoPark.add(x, y, z, w, h, name or "room")
    if not added then return nil, why end
    return { x = x, y = y, z = z, w = w, h = h, label = name }
end

print("[RC] RCNoPark loaded (placement exclusion list)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
