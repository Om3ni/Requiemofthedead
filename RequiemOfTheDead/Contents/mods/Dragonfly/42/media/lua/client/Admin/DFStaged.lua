-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFStaged - edits held back from a live registry until somebody says go.
--
-- Both Admin sub-tabs do the same bookkeeping over two different registries:
-- hold the admin's changes, compare each against what the engine currently
-- holds, drop the ones that changed nothing, count what is outstanding, and
-- read back edit-then-live so a dial shows the staged value rather than the
-- stored one. Written twice it drifted immediately - check-helpers caught the
-- second copy the hour it was written - and the two would have disagreed about
-- the one rule that matters:
--
--   AN EDIT BACK TO THE CURRENT VALUE IS NOT AN EDIT.
--
-- Without that, "3 changes staged" counts changes that change nothing, and
-- Apply writes options the admin never decided to write. On the sandbox side
-- that is a wasted whole-set push; on the server side it is a spurious line in
-- the admin log attributing a change to someone who made none.
--
-- WHY IT LIVES IN Admin/ AND NOT IN CORE. Two consumers, both here, and the
-- concept is "an admin surface staging edits" rather than anything the suite at
-- large needs (CLAUDE.md sect. 5: one consumer stays put, and these two share a
-- folder). If a third surface outside Dragonfly ever wants it, promotion is a
-- file move - nothing here touches Dragonfly's own globals.
--
-- IT DOES NOT KNOW HOW TO WRITE. Applying is the caller's job and the two
-- differ completely: one builds a fresh SandboxOptions and pushes the whole
-- set, the other emits a console command per option. Folding those together
-- behind a flag is what CLAUDE.md sect. 11 warns about - a helper that erases a
-- real difference between call sites.

if isServer() then return end

DFStaged = DFStaged or {}
DFStaged.__index = DFStaged

-- `live(name)` returns what the registry currently holds for that option. It is
-- the one thing a store cannot work out for itself, and it is deliberately a
-- function rather than a table: the sandbox side reads the engine every call so
-- another admin's change is picked up, and the server side layers its own sent
-- echo underneath. Neither is a snapshot.
function DFStaged.new(live)
    return setmetatable({ pending = {}, live = live }, DFStaged)
end

-- Compared as STRINGS. A dial hands back whatever its kind stores - a boolean,
-- an index, a typed number - and the engine hands back its own shape for the
-- same option, so `2` and `"2"` are routinely the same value arriving by two
-- routes. Comparing raw would count every such pair as an edit.
function DFStaged:set(name, value)
    if tostring(self.live(name)) == tostring(value) then
        self.pending[name] = nil
    else
        self.pending[name] = value
    end
end

-- Staged value if there is one, otherwise whatever the registry holds. This is
-- what a form's get() calls, so an edited row shows the edit and every other
-- row shows the truth.
function DFStaged:get(name)
    local v = self.pending[name]
    if v ~= nil then return v end
    return self.live(name)
end

function DFStaged:has(name) return self.pending[name] ~= nil end

-- pairs(), not next(): Kahlua registers no global `next` (CLAUDE.md sect. 3,
-- and check-kahlua enforces it).
function DFStaged:count()
    local n = 0
    for _ in pairs(self.pending) do n = n + 1 end
    return n
end

-- How many of a named set are staged. The nav needs this per mod, so an edit on
-- a page the admin is not currently looking at is still visible.
function DFStaged:countIn(names)
    local n = 0
    for _, name in ipairs(names or {}) do
        if self.pending[name] ~= nil then n = n + 1 end
    end
    return n
end

function DFStaged:clear() self.pending = {} end

-- The staged set, name-sorted. Sorted because both callers walk it to act on a
-- live server, and an unordered walk means two applies of the same edits hit
-- the wire - and the admin log - in different orders for no reason.
function DFStaged:names()
    local out = {}
    for name in pairs(self.pending) do out[#out + 1] = name end
    table.sort(out)
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
