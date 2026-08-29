-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFTypeAhead - rank a registry against what somebody is typing.
--
-- EXTRACTED FROM DFItemQuery 2026-08-25, which is the decision the kit-editor
-- slice left open. The ranker was never item-shaped: it scores a query against
-- three lowered strings per row - the full id, a display name, and the BARE
-- part after a namespace separator - and "bare" is `Base.Axe` and `base:Brave`
-- alike. Wiring the trait field to `DFItemQuery.rank` would have made the name
-- lie; writing a second filter would have been the duplication the kit slice
-- had just removed. So the ranker moved out and the item source sits on top of
-- it, unchanged for its callers.
--
-- SEPARATORS ARE A PARAMETER, not a constant, and that is the whole reason
-- this file exists rather than a rename. Items are dot-namespaced and traits
-- are colon-namespaced (CLAUDE.md sect. 6); a ranker that hardcoded "." would
-- rank `base:Brave` by its full id only, so typing "brave" would score it a
-- substring match behind every item whose module happens to start that way.
--
-- WHAT IT IS NOT: a fuzzy matcher. Prefix beats prefix beats substring, and
-- nothing else. A DM typing an id they half-remember wants the list to narrow
-- predictably, not to be guessed at.

DFTypeAhead = DFTypeAhead or {}

-- Default separators. A row's bare form is the substring after the LAST
-- separator that appears in it.
DFTypeAhead.SEPS = { ".", ":" }

-- Build one searchable entry. `full` is the id a caller submits, `disp` the
-- label a human reads (defaults to full). Returns nil for an unusable row so
-- a builder can skip it without a branch of its own.
function DFTypeAhead.entry(full, disp, seps)
    if type(full) ~= "string" or full == "" then return nil end
    disp = disp or full
    local lfull = string.lower(full)
    local bare  = lfull
    for _, sep in ipairs(seps or DFTypeAhead.SEPS) do
        local at = nil
        local from = 1
        while true do
            local found = string.find(lfull, sep, from, true)
            if not found then break end
            at = found
            from = found + 1
        end
        if at then bare = string.sub(lfull, at + 1) end
    end
    return {
        full  = full,
        disp  = disp,
        lfull = lfull,
        ldisp = string.lower(tostring(disp)),
        lbare = bare,
    }
end

-- Build entries from rows of { full, disp } (or { id, label } - both spellings
-- are accepted, because the registries in this suite use both).
function DFTypeAhead.build(rows, seps)
    local out = {}
    for i = 1, #(rows or {}) do
        local r = rows[i]
        local e = DFTypeAhead.entry(r.full or r.id, r.disp or r.label, seps)
        if e then out[#out + 1] = e end
    end
    return out
end

-- Pure ranking over an entries array - fixtures drive this directly.
-- Prefix on the bare id beats prefix on display/full id beats substring;
-- within a rank, alphabetical by full id so results are stable.
function DFTypeAhead.rank(entries, query, limit)
    local q = string.lower(tostring(query or ""))
    q = string.gsub(q, "^%s+", ""); q = string.gsub(q, "%s+$", "")
    if q == "" then return {} end
    limit = limit or 8

    local hits = {}
    for i = 1, #entries do
        local e = entries[i]
        local score
        if string.sub(e.lbare, 1, #q) == q then
            score = 1
        elseif string.sub(e.lfull, 1, #q) == q or string.sub(e.ldisp, 1, #q) == q then
            score = 2
        elseif string.find(e.lfull, q, 1, true) or string.find(e.ldisp, q, 1, true) then
            score = 3
        end
        if score then hits[#hits + 1] = { score = score, e = e } end
    end
    table.sort(hits, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.e.lfull < b.e.lfull
    end)

    local out = {}
    for i = 1, math.min(limit, #hits) do
        out[i] = { full = hits[i].e.full, disp = hits[i].e.disp }
    end
    return out
end

-- The shape DFEntry's `suggest` option wants: { value, label } rows. Every
-- consumer was writing this three-line adaptor itself.
function DFTypeAhead.suggest(entries, query, limit)
    local out = {}
    for _, r in ipairs(DFTypeAhead.rank(entries, query, limit)) do
        out[#out + 1] = { value = r.full, label = r.disp }
    end
    return out
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
