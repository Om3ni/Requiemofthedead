-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFDeckLayout - remembered per-tab window sizes for the Dragonfly decks.
--
-- DFDeck and DFPlayerDeck carried byte-identical save/load implementations,
-- each behind one blanket pcall over the whole file operation. The contract
-- lives here once; a deck supplies only its own filename.
--
-- Format, one line per tab:  <key> w=<int> h=<int>
-- The old single-line "w= h=" format fails this parse and is forgotten: one
-- default-sized open, then the file is rewritten new-style.
--
-- Client-local and non-fatal by policy. A deck that forgets its size is a
-- nuisance; a deck that refuses to open because it could not read a
-- preference is a fault. Position is never stored - the deck centres itself
-- on the screen it opens on.

require "DFFile"

require "RDFile"

DFDeckLayout = DFDeckLayout or {}

-- ---------------------------------------------------------------------------
-- Save. Mechanism in RDFile (2026-08-25); its header carries the engine
-- facts the block here used to derive.
--
-- Returns written-row count, or nil when the file could not be opened.
-- ---------------------------------------------------------------------------
function DFDeckLayout.save(filename, sizes)
    local lines = {}
    for k, r in pairs(sizes or {}) do
        -- Validated before formatting, not guarded after: math.floor on a nil
        -- or non-numeric field throws, and under the old blanket that single
        -- malformed record silently discarded every tab size after it in the
        -- pairs walk. A bad row is skipped; its peers still persist.
        local w = tonumber(r and r.w)
        local h = tonumber(r and r.h)
        if w and h then
            lines[#lines + 1] = string.format("%s w=%d h=%d", tostring(k),
                math.floor(w), math.floor(h))
        end
    end
    if not RDFile.rewriteLines(filename, lines) then return nil end
    return #lines
end

-- ---------------------------------------------------------------------------
-- Load. No guard here - DFFile.readLines owns the mod's one read path, and a
-- read fault presents there as early EOF (exposed BufferedReader; see the
-- DFFile.lua header), so a truncated file simply restores fewer rows.
--
-- A partial read is kept rather than discarded: every row recovered before
-- the fault still restores its tab, because a deck that remembers three of
-- four sizes is strictly better than one that remembers none.
-- ---------------------------------------------------------------------------
function DFDeckLayout.load(filename)
    local out = {}

    local lines = DFFile.readLines(filename)
    if not lines then return out end

    for _, line in ipairs(lines) do
        local k, w, h = line:match("^(%S+) w=(%d+) h=(%d+)")
        if k then out[k] = { w = tonumber(w), h = tonumber(h) } end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
-- ---------------------------------------------------------------------------
