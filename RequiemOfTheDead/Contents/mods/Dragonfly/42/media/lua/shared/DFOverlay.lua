-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFOverlay - the admin layout overlay: its shape, its validation, and the one
-- rule that decides what it is allowed to do to a reflected page.
--
-- ---------------------------------------------------------------------------
-- WHAT IT IS. DFSandboxModel reads the options off the engine and emits them in
-- declaration order, split on the *Header decoys. That order is the mod
-- author's, and for a panel an admin lives in it is often the wrong one:
-- Dirge's sixty-four options are grouped by subsystem when the person tuning
-- them wants the six they actually change at the top. So an admin may impose
-- their own order and their own section headers, server-wide.
--
-- ---------------------------------------------------------------------------
-- WHAT IT IS NOT ALLOWED TO DO, AND WHY THAT IS THE WHOLE DESIGN
--
-- It cannot hide an option. Not "does not currently offer to"; cannot.
--
-- The temptation is obvious - an admin who has reordered forty options would
-- like to bury the twenty they never touch - and it is the same failure as the
-- registration API this panel was built to avoid. A registry has two sources of
-- truth and they drift; a hiding overlay has one source of truth and a filter
-- in front of it, which drifts identically and worse: the option is still there,
-- still doing whatever it does to the server, and the one screen that would have
-- shown it has been told not to. A mod ships a new option, nobody sees it, and
-- the panel is now actively lying about what the server is configured to do.
--
-- So the contract is FALL-THROUGH, and it is structural rather than checked:
--
--   Every option the model reflected is emitted. An option the overlay places
--   is emitted where it was placed. An option the overlay does not mention is
--   emitted immediately after the last option before it - in reflected order -
--   that the overlay DID place, so a newly shipped option lands beside whichever
--   neighbour the admin has already put somewhere. Options before any placed
--   option go to the top of the page.
--
-- apply() builds its output by walking those two sets and nothing else, so there
-- is no branch in which an option can fail to be written. The fixture pins it
-- from the outside as well - an overlay listing one option must still render all
-- of them - because a structural guarantee that nobody tests is a comment.
--
-- The reverse case is the cheap one: an entry naming an option that no longer
-- exists (mod removed it, mod disabled, sandbox page renamed) is skipped and
-- counted. It cannot fault the page, because the page is the thing an admin
-- would need in order to fix it.
--
-- ---------------------------------------------------------------------------
-- SHAPE. A flat sequence per page, of exactly two kinds:
--
--     "RFTDDirge.SomeOption"     an option, by its full namespaced name
--     { h = "Tuning" }           a section header, authored
--
-- Flat rather than nested sections-holding-options, for one reason: the editor
-- is a drag list, and a drag list is flat. A nested shape would have to be
-- flattened to edit and rebuilt to save, and every bug in that pair is an option
-- landing somewhere nobody asked for. The sections the panel draws are derived
-- at the end of apply(), where a header simply starts a new one.
--
-- Reflected headers are NOT tracked separately from authored ones. The first
-- time a page is edited it is seeded from flatten(), which turns the mod's own
-- *Header sections into ordinary header entries the admin can move or delete.
-- After that the overlay owns the page's section structure outright. A header a
-- mod ships LATER therefore does not appear - but every option under it does,
-- by the fall-through rule, next to its reflected neighbour. Options are the
-- thing that must not vanish; a divider is scenery.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE IS SHARED AND PURE. Both sides need it and they need the same
-- copy: the client applies it to draw, the server sanitises it before storing,
-- and a stored overlay is untrusted wire data that a second implementation
-- would eventually disagree about. No ISUI, no engine calls, no globals touched
-- at file scope - which is also what makes it safe under the client's
-- alphabetical shared walk (CLAUDE.md sect. 4).

DFOverlay = DFOverlay or {}

-- Bounds. This is wire data: a client sends it, the server stores it, and every
-- admin is handed it back. None of these numbers is a judgement about taste -
-- they are the ceiling above which a payload stops being a layout and starts
-- being a way to fill a server's disk. The largest real page today is Dirge's
-- 64 options, so 400 entries leaves room for headers and for a page four times
-- the size before anyone notices the limit exists.
DFOverlay.MAX_ENTRIES = 400
DFOverlay.MAX_TITLE   = 48
DFOverlay.MAX_NAME    = 96
DFOverlay.MAX_KEY     = 64

-- The server options page has no engine page name of its own - ServerOption
-- carries no category of any kind - so the panel gives it one. It lives here
-- rather than in the model because three files key on it (the model builds it,
-- the store files a layout under it, and the write gate reads it to decide
-- WHICH capability an edit needs), and a sentinel spelled out in three places
-- is a sentinel that will one day be spelled two ways.
DFOverlay.SERVER_KEY = "__server"

local function trim(s)
    return (tostring(s):match("^%s*(.-)%s*$"))
end

-- Titles are authored text that reaches drawText and a JSON file. Anything
-- below space - a newline pasted out of a chat window, a stray tab - is
-- collapsed rather than escaped: a header is one line by definition, and the
-- alternative is a value whose stored form and drawn form differ.
local function cleanTitle(s)
    local out = trim(s):gsub("%c", " "):gsub("%s+", " ")
    return trim(out):sub(1, DFOverlay.MAX_TITLE)
end

-- A page key is a sandbox page name (RFTDDirge, RFTDNecro, ...) or the server
-- page's sentinel. Validated because it is a TABLE KEY on the server's stored
-- document: an unbounded key is an unbounded document.
function DFOverlay.validKey(key)
    if type(key) ~= "string" then return false end
    if #key == 0 or #key > DFOverlay.MAX_KEY then return false end
    return key:match("^[%w_]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- flatten - a reflected page as an overlay would express it.
--
-- This is the identity layout, and it is what seeds the editor: an admin who
-- opens the editor and changes nothing then saves an overlay that reproduces
-- exactly what they were already looking at. That property is worth having on
-- purpose - it means "save" is never a leap.
-- ---------------------------------------------------------------------------
function DFOverlay.flatten(page)
    local out = {}
    if type(page) ~= "table" then return out end
    for _, sec in ipairs(page.sections or {}) do
        if sec.title then out[#out + 1] = { h = sec.title } end
        for _, opt in ipairs(sec.options or {}) do
            if opt.name then out[#out + 1] = opt.name end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- sanitize - the server's door.
--
-- Runs before anything is stored, on the assumption that the sender is hostile
-- and not merely mistaken (CLAUDE.md sect. 13). Everything that is not one of
-- the two legal entry shapes is dropped and counted; the count is what the
-- handler logs, because silently accepting three quarters of a payload is how a
-- client and a server end up with different ideas of the same layout.
--
-- Duplicate option names are dropped rather than deduplicated in apply(). Both
-- would work; doing it here means the STORED document is already canonical, so
-- every reader agrees without repeating the rule.
--
-- Returns (clean, dropped).
-- ---------------------------------------------------------------------------
function DFOverlay.sanitize(entries)
    local out, dropped = {}, 0
    if type(entries) ~= "table" then return out, dropped end

    local seen = {}
    for i = 1, #entries do
        local e = entries[i]
        if #out >= DFOverlay.MAX_ENTRIES then
            dropped = dropped + 1
        elseif type(e) == "string" then
            local name = trim(e)
            if name ~= "" and #name <= DFOverlay.MAX_NAME and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            else
                dropped = dropped + 1
            end
        elseif type(e) == "table" and type(e.h) == "string" then
            local title = cleanTitle(e.h)
            if title ~= "" then
                out[#out + 1] = { h = title }
            else
                dropped = dropped + 1
            end
        else
            dropped = dropped + 1
        end
    end
    return out, dropped
end

-- ---------------------------------------------------------------------------
-- apply - a reflected page, re-ordered.
--
-- Returns (page, stats). The page is a NEW table in the shape DFSandboxModel
-- emits, so schemaFor and the views do not learn that an overlay exists. The
-- option rows inside it are the model's own tables, by reference: they are read
-- and never written, and copying them would mean a second thing to keep in step
-- when the model grows a field.
--
--   stats.placed  options the overlay positioned
--   stats.added   options it did not mention, carried in by fall-through
--   stats.stale   entries naming an option the model no longer has
--
-- `added` is the number the panel shows. It is the only way an admin learns
-- that the page they arranged has grown since, and it is the difference between
-- "my layout is fine" and "three settings I have never seen are sitting next to
-- ones I placed".
--
-- No overlay, or an empty one, returns the page UNCHANGED. Not a rebuilt
-- equivalent - the same table - so the common case costs nothing and cannot
-- differ from the model by any amount at all.
-- ---------------------------------------------------------------------------
function DFOverlay.apply(page, entries)
    local stats = { placed = 0, added = 0, stale = 0 }
    if type(page) ~= "table" then return nil, stats end
    if type(entries) ~= "table" or #entries == 0 then return page, stats end

    -- The reflected page, flattened to a name->row map and a name order. Both
    -- are needed: the map to resolve what the overlay names, the order to know
    -- where an unmentioned option belongs.
    local rowOf, reflected = {}, {}
    for _, sec in ipairs(page.sections or {}) do
        for _, opt in ipairs(sec.options or {}) do
            if opt.name and not rowOf[opt.name] then
                rowOf[opt.name] = opt
                reflected[#reflected + 1] = opt.name
            end
        end
    end

    -- Pass one: what the overlay places, in the overlay's order.
    local placedList, isPlaced = {}, {}
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.h then
            placedList[#placedList + 1] = { h = e.h }
        elseif type(e) == "string" then
            if rowOf[e] and not isPlaced[e] then
                isPlaced[e] = true
                placedList[#placedList + 1] = { name = e }
                stats.placed = stats.placed + 1
            else
                -- Names an option this model does not have, or names one twice.
                -- sanitize() removes the second case from anything we stored,
                -- so in practice this is a mod that shipped an option away.
                stats.stale = stats.stale + 1
            end
        end
    end

    -- Pass two: where everything else goes. Walk the REFLECTED order carrying an
    -- anchor - the last placed option seen - and file each unmentioned option
    -- behind it. A run of new options keeps its own reflected order because each
    -- one becomes the anchor for the next.
    local head, after = {}, {}
    local anchor = nil
    for _, name in ipairs(reflected) do
        if isPlaced[name] then
            anchor = name
        else
            if anchor then
                local bucket = after[anchor]
                if not bucket then bucket = {}; after[anchor] = bucket end
                bucket[#bucket + 1] = name
            else
                head[#head + 1] = name
            end
            stats.added = stats.added + 1
        end
    end

    -- Emit. Every option is in exactly one of head / placedList / after, and all
    -- three are walked here - which is the whole of the never-hide guarantee.
    local flat = {}
    for _, name in ipairs(head) do flat[#flat + 1] = rowOf[name] end
    for _, e in ipairs(placedList) do
        if e.h then
            flat[#flat + 1] = { header = e.h }
        else
            flat[#flat + 1] = rowOf[e.name]
            for _, name in ipairs(after[e.name] or {}) do
                flat[#flat + 1] = rowOf[name]
            end
        end
    end

    -- Back into sections. A header starts one; a leading section nobody wrote
    -- into is an artefact of always opening with one, exactly as in the model.
    local sections = { { title = nil, options = {} } }
    for _, item in ipairs(flat) do
        if item.header then
            sections[#sections + 1] = { title = item.header, options = {} }
        else
            local sec = sections[#sections]
            sec.options[#sec.options + 1] = item
        end
    end
    if #sections > 1 and #sections[1].options == 0 then
        table.remove(sections, 1)
    end

    return {
        page     = page.page,
        label    = page.label,
        sections = sections,
        count    = #reflected,
    }, stats
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
