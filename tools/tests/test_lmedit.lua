-- SPDX-License-Identifier: GPL-3.0-or-later
-- test_lmedit.lua - M4's working copy: draft, validate, diff.
--
-- WHY THIS EXISTS: the editor is the first thing in Limes that GENERATES
-- traffic, and a map editor is the worst possible shape for it - a drag fires
-- at frame rate. docs/limes-design.md §6.1 turns that into eight rules, and
-- four of them are enforced by this file rather than by the panel:
--
--   rule 2  the editor edits a working copy and sends ONE command on Save.
--           LMEdit.new copies; nothing here writes to the live store.
--   rule 4  one announcement per edit - so the command carries a DIFF. An edit
--           to one zone must cost one zone. Re-sending the store is the single
--           line that put PhunZones at 62.8% of all mod traffic.
--   rule 5  prune on save: a cleared field is REMOVED, never stored empty.
--           Merge-never-prune is how a store silently becomes append-only.
--   rule 7  the save carries the revision it was made against.
--
-- And one rule that is not in §6.1 because it was only found while building
-- this: LMPersist.parse recognises section names matching [%w_%-%.]+ and keys
-- matching [%w_]+. A zone named "Rosewood Fire Dept" serialises, crosses the
-- wire, resolves live - and is GONE after the next server restart, silently,
-- because the section header will not match on the way back in. The editor
-- refuses that name at the point it is typed. The grammar is duplicated in
-- LMEdit; the last block here reads LMIni's source as text so the copy cannot
-- rot unnoticed. (It watched LMPersist until the dialect moved to LMIni on
-- 2026-08-05 - and caught the move, which is the point of the guard.)
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmedit.lua <repo-root>

local ROOT = arg[1] or "."
local LM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/"

for _, rel in ipairs({ "shared/LMCore.lua", "shared/LMEdit.lua" }) do
    local okLoad, err = pcall(dofile, LM .. rel)
    if not okLoad then
        print("FATAL: could not load " .. LM .. rel)
        print("  " .. tostring(err))
        os.exit(2)
    end
end

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function isTrue(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(detail)) end
end
local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end
local function findProblem(list, zone, level, needle)
    for _, p in ipairs(list) do
        if p.zone == zone and p.level == level and p.msg:find(needle, 1, true) then return p end
    end
    return nil
end

-- A small store shaped like the real one: a root template, a tier template
-- under it, two geographic zones under that, and one zone with an unregistered
-- field of the kind M2/M3 will eventually claim.
local function fixture()
    return {
        _default = { fields = { tier = 2 } },
        Hard     = { inherits = "_default", fields = { tier = 4 } },
        Riverside = {
            inherits = "Hard",
            rects  = { { 6000, 5000, 6500, 5400 } },
            fields = { priority = 3 },
        },
        Westpoint = {
            inherits = "Hard",
            rects  = { { 11000, 6600, 11800, 7200 }, { 11900, 6600, 12000, 6700 } },
            fields = { title = "West Point", futureThing = "remove" },
        },
    }
end

-- ---------------------------------------------------------------------------
-- 1. The draft is a copy, and a clean draft is silent
-- ---------------------------------------------------------------------------

local src = fixture()
local d   = LMEdit.new(src, 7)

eq("revision is carried", d:revision(), 7)
eq("names are sorted",    table.concat(d:names(), ","), "Hard,Riverside,Westpoint,_default")

d:setField("Riverside", "tier", 5)
d:addRect("Riverside", { 1, 2, 3, 4 })
eq("source fields untouched", src.Riverside.fields.tier, nil)
eq("source rects untouched",  #src.Riverside.rects, 1)

local clean = LMEdit.new(fixture(), 7)
local changed, removed, n = clean:changeSet()
eq("a clean draft changes nothing", n, 0)
eq("...no changed records", count(changed), 0)
eq("...no removals",        #removed, 0)
eq("...and is not dirty",   clean:isDirty(), false)

-- ---------------------------------------------------------------------------
-- 2. The diff is a diff (§6.1 rule 4)
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", 5)
changed, removed, n = d:changeSet()
eq("one edit, one record on the wire", count(changed), 1)
eq("...and it is the one edited",      changed.Riverside ~= nil, true)
eq("...total change count",            n, 1)

-- Setting a field to the value it already carries is not an edit.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "priority", 3)
eq("re-typing the same value is nothing", select(3, d:changeSet()), 0)

-- Nor is clearing a field that was never set.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "noannounce", nil)
eq("clearing an absent field is nothing", select(3, d:changeSet()), 0)

-- Nor is redrawing a rect in the opposite direction: pruning normalises, so a
-- bottom-right-to-top-left drag produces the same record as the other way round.
d = LMEdit.new(fixture(), 7)
d:setRects("Riverside", { { 6500, 5400, 6000, 5000 } })
eq("an inverted rect is the same rect", select(3, d:changeSet()), 0)

-- ---------------------------------------------------------------------------
-- 3. Prune on save (§6.1 rule 5)
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "priority", nil)
changed = d:changeSet()
isTrue("a cleared field leaves a changed record", changed.Riverside ~= nil)
eq("...the key is GONE, not empty",
    changed.Riverside.fields == nil or changed.Riverside.fields.priority == nil, true)
eq("...and an emptied field table is dropped entirely", changed.Riverside.fields, nil)

d = LMEdit.new(fixture(), 7)
d:setField("Westpoint", "title", "")
changed = d:changeSet()
eq('setting a field to "" clears it', changed.Westpoint.fields.title, nil)
eq("...siblings survive",             changed.Westpoint.fields.futureThing, "remove")

d = LMEdit.new(fixture(), 7)
d:setRects("Riverside", {})
changed = d:changeSet()
eq("an emptied rect list is dropped, not sent as {}", changed.Riverside.rects, nil)

d = LMEdit.new(fixture(), 7)
d:setInherits("Riverside", "")
changed = d:changeSet()
eq("an empty inherits is dropped", changed.Riverside.inherits, nil)

-- Rects are floored on the way out: the map hands back fractional world coords
-- on every frame of a drag, so a gesture that lands back on the same TILE must
-- produce no packet at all - which is the whole reason flooring happens in the
-- prune rather than in the panel.
d = LMEdit.new(fixture(), 7)
d:setRects("Riverside", { { 6000.7, 5000.2, 6500.9, 5400.4 } })
eq("a sub-tile nudge is not a change", select(3, d:changeSet()), 0)

d = LMEdit.new(fixture(), 7)
d:setRects("Riverside", { { 6000.7, 5000.2, 6500.9, 5401.4 } })
changed = d:changeSet()
eq("fractional world coords are floored", changed.Riverside.rects[1][1], 6000)
eq("...on every corner",                  changed.Riverside.rects[1][4], 5401)

-- ---------------------------------------------------------------------------
-- 4. Create / remove
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
eq("create a new zone", d:create("Rosewood"), true)
eq("create refuses a duplicate", select(1, d:create("Hard")), false)
d:setRects("Rosewood", { { 8000, 11000, 8400, 11400 } })
changed, removed, n = d:changeSet()
isTrue("the new zone is in the change set", changed.Rosewood ~= nil)
eq("a brand-new zone with no fields sends no field table", changed.Rosewood.fields, nil)

d = LMEdit.new(fixture(), 7)
d:remove("Riverside")
changed, removed, n = d:changeSet()
eq("a deletion is a removal, not an empty record", count(changed), 0)
eq("...listed by name", table.concat(removed, ","), "Riverside")
eq("...and counted",    n, 1)

-- Deleting then recreating identically is a no-op on the wire.
d = LMEdit.new(fixture(), 7)
d:remove("Riverside")
d:create("Riverside", { inherits = "Hard", rects = { { 6000, 5000, 6500, 5400 } }, fields = { priority = 3 } })
eq("delete + identical recreate is nothing", select(3, d:changeSet()), 0)

-- ---------------------------------------------------------------------------
-- 5. Rename rewrites the children, atomically
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
local okR, moved = d:rename("Hard", "Very_Hard")
eq("rename succeeds",            okR, true)
eq("...and reports the rewrites", moved, 2)
eq("the old name is gone",        d:exists("Hard"), false)
eq("Riverside follows the rename", d:get("Riverside").inherits, "Very_Hard")
eq("Westpoint follows too",        d:get("Westpoint").inherits, "Very_Hard")

changed, removed, n = d:changeSet()
eq("the rename removes the old name", table.concat(removed, ","), "Hard")
isTrue("...adds the new one",  changed.Very_Hard ~= nil)
isTrue("...and re-sends both children", changed.Riverside ~= nil and changed.Westpoint ~= nil)
-- Nothing dangles at any point: the child rewrite is part of the rename, not a
-- follow-up the caller can forget.
eq("no zone is left pointing at the old name",
    findProblem(d:validate(), "Riverside", "warning", "Hard") == nil, true)

eq("rename onto an existing name is refused", select(1, d:rename("Riverside", "Westpoint")), false)
eq("rename to itself is a no-op",             select(1, LMEdit.new(fixture(), 7):rename("Hard", "Hard")), true)

-- ---------------------------------------------------------------------------
-- 6. The name grammar - the silent-data-loss guard
-- ---------------------------------------------------------------------------

isTrue("a plain name is fine",        LMEdit.nameProblem("Riverside") == nil)
isTrue("underscores are fine",        LMEdit.nameProblem("Very_Hard") == nil)
isTrue("hyphens and dots are fine",   LMEdit.nameProblem("West-Point.2") == nil)
isTrue("digits are fine",             LMEdit.nameProblem("Zone42") == nil)
isTrue("A SPACE IS NOT",              LMEdit.nameProblem("Rosewood Fire Dept") ~= nil)
isTrue("a bracket is not",            LMEdit.nameProblem("Rose]wood") ~= nil)
isTrue("an equals is not",            LMEdit.nameProblem("a=b") ~= nil)
isTrue("empty is not",                LMEdit.nameProblem("") ~= nil)
eq("create refuses a name that cannot round-trip",
    select(1, LMEdit.new(fixture(), 7):create("Rosewood Fire Dept")), false)
eq("rename refuses one too",
    select(1, LMEdit.new(fixture(), 7):rename("Hard", "Really Hard")), false)

isTrue("a plain field key is fine",   LMEdit.keyProblem("tier") == nil)
isTrue("a hyphen in a key is not",    LMEdit.keyProblem("max-risk") ~= nil)
isTrue("'rects' is reserved",         LMEdit.keyProblem("rects") ~= nil)
isTrue("'inherits' is reserved",      LMEdit.keyProblem("inherits") ~= nil)
isTrue("'name' is reserved",          LMEdit.keyProblem("name") ~= nil)
eq("setField refuses a reserved key", select(1, LMEdit.new(fixture(), 7):setField("Hard", "rects", 1)), false)

-- ---------------------------------------------------------------------------
-- 7. Validation - errors block, warnings do not
-- ---------------------------------------------------------------------------

-- Live data already contains dangling inherits (ProtectedCountryAreas), so this
-- must be a warning. If it were an error the editor's first act on a real
-- server would be to refuse to save it.
d = LMEdit.new(fixture(), 7)
d:setInherits("Riverside", "NoSuchTemplate")
isTrue("a dangling inherits warns", findProblem(d:validate(), "Riverside", "warning", "not in the store"))
eq("...and does not block save", d:errorCount(), 0)

d = LMEdit.new(fixture(), 7)
d:setInherits("Hard", "Riverside")     -- Hard -> Riverside -> Hard
local probs = d:validate()
isTrue("a cycle is an error", findProblem(probs, "Hard", "error", "loops back"))
isTrue("...reported on both members", findProblem(probs, "Riverside", "error", "loops back"))
isTrue("...and blocks save", d:errorCount() > 0)

eq("self-inheritance is refused up front",
    select(1, LMEdit.new(fixture(), 7):setInherits("Hard", "Hard")), false)

-- tier is registered 0-10 and LMCore CLAMPS out-of-range values rather than
-- dropping them, so out-of-range is a warning that says what it will become.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", 99)
isTrue("above max warns with the resolved value",
    findProblem(d:validate(), "Riverside", "warning", "resolves as 10"))
eq("...and does not block save", d:errorCount(), 0)

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", -4)
isTrue("below min warns", findProblem(d:validate(), "Riverside", "warning", "resolves as 0"))

-- A value that will not coerce is a different matter: LMCore drops it and the
-- zone silently inherits instead, which is exactly the outcome an admin editing
-- a field does not expect.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", "quite hard")
isTrue("an uncoercible number is an error",
    findProblem(d:validate(), "Riverside", "error", "is not a number"))
isTrue("...and blocks save", d:errorCount() > 0)

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "noannounce", "maybe")
isTrue("an uncoercible boolean is an error",
    findProblem(d:validate(), "Riverside", "error", "is not true or false"))
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "noannounce", "true")
eq("the string 'true' is accepted for a boolean", d:errorCount(), 0)

-- An unregistered key is how a field from an unbuilt milestone survives a round
-- trip through the editor. It must warn, never block, and never be dropped.
--
-- The fixture uses a made-up name on purpose. It used to use `zeds`, which was a
-- real unregistered key right up until LMCore declared the zone policy
-- vocabulary - at which point this stopped testing the unregistered path at all
-- and started testing a registered string. A synthetic name cannot be claimed
-- out from under the test.
d = LMEdit.new(fixture(), 7)
isTrue("an unregistered field warns",
    findProblem(d:validate(), "Westpoint", "warning", "no consumer installed"))
eq("...and does not block save", d:errorCount(), 0)
d:setField("Westpoint", "title", "West Point 2")
changed = d:changeSet()
eq("...and rides through the change set untouched", changed.Westpoint.fields.futureThing, "remove")

-- Deleting a template that others stand on is allowed, but the children are
-- named so the admin sees who they just changed.
d = LMEdit.new(fixture(), 7)
d:remove("Hard")
probs = d:validate()
isTrue("orphaning a child warns, against the child",
    findProblem(probs, "Riverside", "warning", "is being deleted in this edit"))
isTrue("...for every child", findProblem(probs, "Westpoint", "warning", "is being deleted in this edit"))
eq("...and does not block save", d:errorCount(), 0)

-- Problems come back in a stable order so the panel does not reshuffle.
d = LMEdit.new(fixture(), 7)
d:setField("Westpoint", "tier", 99)
d:setField("Riverside", "tier", 99)
probs = d:validate()
isTrue("problems are sorted by zone", probs[1].zone <= probs[#probs].zone)

-- ---------------------------------------------------------------------------
-- 8. applyChangeSet - both sides fold the same command the same way
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", 5)
d:remove("Westpoint")
d:create("Rosewood")
d:setRects("Rosewood", { { 8000, 11000, 8400, 11400 } })
changed, removed = d:changeSet()

local folded = LMEdit.applyChangeSet(fixture(), changed, removed)
local snap   = d:snapshot()

eq("folded store has the same zone count", count(folded), count(snap))
for name, rec in pairs(snap) do
    local f = folded[name]
    isTrue("folded[" .. name .. "] exists", f ~= nil)
    if f then
        eq("folded[" .. name .. "].inherits", f.inherits, rec.inherits)
        eq("folded[" .. name .. "] rect count", #(f.rects or {}), #(rec.rects or {}))
        eq("folded[" .. name .. "] field count", count(f.fields), count(rec.fields))
    end
end
eq("the removed zone is gone from the fold", folded.Westpoint, nil)
eq("the edited value landed",                folded.Riverside.fields.tier, 5)
eq("the created zone landed",                folded.Rosewood.rects[1][3], 8400)

-- applyChangeSet must not alias the store it was given.
local before = fixture()
LMEdit.applyChangeSet(before, changed, removed)
eq("the source store is not mutated", before.Westpoint ~= nil, true)
eq("...nor its fields",               before.Riverside.fields.tier, nil)

-- ---------------------------------------------------------------------------
-- 8b. names() is memoised, so its invalidation has to be right
--
-- The map editor calls names() inside its render pass. Caching it stops ~76
-- names being sorted into a fresh table sixty times a second; getting the
-- invalidation wrong instead means the editor draws and lists a zone set that
-- no longer exists, which is a far worse bug than the allocation.
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
eq("names before", table.concat(d:names(), ","), "Hard,Riverside,Westpoint,_default")
d:create("Aardvark")
eq("create invalidates", table.concat(d:names(), ","), "Aardvark,Hard,Riverside,Westpoint,_default")
d:remove("Riverside")
eq("remove invalidates", table.concat(d:names(), ","), "Aardvark,Hard,Westpoint,_default")
d:rename("Hard", "Zulu")
eq("rename invalidates", table.concat(d:names(), ","), "Aardvark,Westpoint,Zulu,_default")

-- Edits that cannot change the set must NOT pay for a re-sort, and must not
-- return a different table either - a caller holding the list across a field
-- edit is the normal case in the render loop.
d = LMEdit.new(fixture(), 7)
local held = d:names()
d:setField("Riverside", "tier", 5)
d:setRects("Riverside", { { 1, 2, 300, 400 } })
d:setInherits("Riverside", "_default")
isTrue("a field/rect/inherits edit keeps the cached list", d:names() == held)
eq("...and the list is still right", table.concat(d:names(), ","), "Hard,Riverside,Westpoint,_default")

-- A refused create or rename must not invalidate a thing.
d = LMEdit.new(fixture(), 7)
held = d:names()
d:create("Hard")                       -- duplicate, refused
d:create("Bad Name")                   -- ungrammatical, refused
d:rename("Hard", "Westpoint")          -- collision, refused
eq("refused operations leave the set alone",
    table.concat(d:names(), ","), "Hard,Riverside,Westpoint,_default")

-- ---------------------------------------------------------------------------
-- 8c. Containment makes a child, and the tree draws it (§11.3)
--
-- The editor's rule is "draw a zone inside another and it becomes that zone's
-- child". One parent slot exists, so the spatial parent IS `inherits` - which
-- means these two functions decide what an admin's policies inherit from, and
-- getting "inside" wrong silently rewires the whole layer.
-- ---------------------------------------------------------------------------

local function nested()
    return {
        -- A region, a town inside it, a block inside the town, and a template
        -- with no geometry at all.
        Region    = { rects = { { 0, 0, 10000, 10000 } } },
        Rosewood  = { rects = { { 8000, 11000, 8900, 11900 } } },
        Town      = { rects = { { 1000, 1000, 3000, 3000 } } },
        Block     = { rects = { { 1200, 1200, 1400, 1400 } } },
        Hard      = { fields = { tier = 4 } },
    }
end

d = LMEdit.new(nested(), 1)
eq("the innermost container wins, not the outermost", d:containerOf("Block"), "Town")
eq("a town inside a region",                          d:containerOf("Town"), "Region")
eq("the region is contained by nothing",              d:containerOf("Region"), nil)
eq("a zone outside everything has no container",      d:containerOf("Rosewood"), nil)
eq("a template has no geometry, so no container",     d:containerOf("Hard"), nil)

-- A rect that merely OVERLAPS is not contained. This is the case that decides
-- whether "inside" is a usable word: a zone half in and half out of a town
-- would otherwise silently adopt the town's loot and difficulty.
d = LMEdit.new(nested(), 1)
d:setRects("Block", { { 2900, 2900, 3100, 3100 } })   -- straddles Town's edge
eq("a straddling rect is not inside", d:containerOf("Block"), "Region")

-- Multi-rect: EVERY rect must land inside ONE of the host's, never merely
-- inside their combined bounding box. Two rects at opposite corners of Town
-- have a bounding box covering everything between them.
d = LMEdit.new(nested(), 1)
d:setRects("Block", { { 1200, 1200, 1400, 1400 }, { 9000, 9000, 9100, 9100 } })
eq("one rect outside disqualifies the whole zone", d:containerOf("Block"), "Region")

d = LMEdit.new(nested(), 1)
d:setRects("Town", { { 1000, 1000, 2000, 2000 }, { 2500, 2500, 3000, 3000 } })
d:setRects("Block", { { 2600, 2600, 2700, 2700 } })   -- inside Town's SECOND rect
eq("inside any one of the host's rects is inside", d:containerOf("Block"), "Town")

-- Reparenting writes `inherits` and reports whether anything moved.
d = LMEdit.new(nested(), 1)
local p, moved = d:reparentByContainment("Block")
eq("reparent returns the parent", p, "Town")
eq("...and says it moved",        moved, true)
eq("...and wrote inherits",       d:get("Block").inherits, "Town")
p, moved = d:reparentByContainment("Block")
eq("reparenting an already-correct zone moves nothing", moved, false)

-- Dragged out of everything, a zone loses its parent. The same rule read
-- backwards - a zone sitting nowhere near its parent but still taking its
-- policies is not findable by looking at the map.
d = LMEdit.new(nested(), 1)
d:reparentByContainment("Block")
d:setRects("Block", { { 50000, 50000, 50100, 50100 } })
p, moved = d:reparentByContainment("Block")
eq("dragged outside, the parent is cleared", p, nil)
eq("...and that counts as a move",           moved, true)
eq("...inherits is gone, not empty",         d:get("Block").inherits, nil)

-- A descendant can never be adopted as a parent, however the geometry sits.
-- Town is inside Region; if Region's rects were shrunk inside Town's, the
-- naive answer is Region inherits Town - and the chain closes on itself.
d = LMEdit.new(nested(), 1)
d:setInherits("Town", "Region")
d:setRects("Region", { { 1100, 1100, 1200, 1200 } })   -- Region now sits inside Town
eq("a descendant is never adopted as a parent", d:containerOf("Region"), nil)

-- The tree: parents before children, siblings by name, depth counted.
d = LMEdit.new(nested(), 1)
d:reparentByContainment("Town")
d:reparentByContainment("Block")
local t = d:tree()
local flat = {}
for _, n in ipairs(t) do flat[#flat + 1] = string.rep(">", n.depth) .. n.name end
eq("the tree nests and orders", table.concat(flat, " "),
   "Hard Region >Town >>Block Rosewood")
eq("every zone appears exactly once", #t, 5)


for _, n in ipairs(t) do
    if n.name == "Town"  then eq("Town is not a leaf",  n.leaf, false) end
    if n.name == "Block" then eq("Block is a leaf",     n.leaf, true) end
    if n.name == "Block" then eq("Block knows its parent", n.parent, "Town") end
end

-- NESTING IS SPATIAL. A zone whose parent is a geometry-less TEMPLATE is a root,
-- not a child - otherwise an imported layer files every zone on the map under
-- Easy / Hard / Intermediate, because that is what `inherits` means there, and
-- finding a town means knowing its difficulty first. Templates are not places.
d = LMEdit.new(nested(), 1)
d:setInherits("Rosewood", "Hard")      -- Hard has no rects: a tier, not a place
t = d:tree()
flat = {}
for _, n in ipairs(t) do flat[#flat + 1] = string.rep(">", n.depth) .. n.name end
eq("a template parent does not nest its children", table.concat(flat, " "),
   "Block Hard Region Rosewood Town")
eq("...every zone still appears", #t, 5)

-- ...and the FIELD chain is untouched: only the list SHAPE changed. Rosewood
-- still takes Hard's tier, it just does not file itself underneath it.
eq("a template parent still supplies fields", (d:effective("Rosewood", "tier")), 4)

-- Alphabetical at every level, digits included.
d = LMEdit.new({
    Zulu    = { rects = { { 0, 0, 100, 100 } } },
    alpha   = { rects = { { 200, 200, 300, 300 } } },
    Mike    = { rects = { { 400, 400, 500, 500 } } },
    Bravo2  = { rects = { { 600, 600, 700, 700 } } },
    Bravo10 = { rects = { { 800, 800, 900, 900 } } },
}, 1)
flat = {}
for _, n in ipairs(d:tree()) do flat[#flat + 1] = n.name end
eq("roots sort alphabetically", table.concat(flat, ","), "Bravo10,Bravo2,Mike,Zulu,alpha")

-- An orphan is a ROOT, not a disappearance. The live imported layer has several
-- zones inheriting from templates that are not in the store; hiding them because
-- their parent is missing is the wrong answer to a dangling reference.
d = LMEdit.new(nested(), 1)
d:setInherits("Rosewood", "SomeMissingTemplate")
t = d:tree()
local found = false
for _, n in ipairs(t) do
    if n.name == "Rosewood" then found = true; eq("an orphan is a root", n.depth, 0) end
end
isTrue("an orphan still appears", found)
eq("nothing is lost to a dangling parent", #t, 5)

-- A cycle must not hang the tree, and must not swallow its members either.
d = LMEdit.new(nested(), 1)
d.work.Town.inherits  = "Block"      -- straight to the record: setInherits would
d.work.Block.inherits = "Town"       -- refuse the self-reference half of this
t = d:tree()
eq("a cycle still yields every zone", #t, 5)

-- ---------------------------------------------------------------------------
-- 8d. effective() - what the panel must SHOW
--
-- A child that overrides nothing has to display its parent's value, or an admin
-- sets a number that was already in force and a redundant override goes into the
-- store for nothing. Resolution runs against the DRAFT, not the live store, so
-- editing a parent moves its children before anything is saved.
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)     -- _default tier 2, Hard tier 4, Riverside under Hard
local v, src = d:effective("Riverside", "tier")
eq("an unset field resolves from the nearest ancestor", v, 4)
eq("...and says where it came from",                    src, "Hard")
eq("Riverside does not override it",  d:isOverride("Riverside", "tier"), false)

d:setField("Riverside", "tier", 5)
v, src = d:effective("Riverside", "tier")
eq("an override wins",            v, 5)
eq("...sourced to the zone",      src, "Riverside")
eq("...and reads as an override", d:isOverride("Riverside", "tier"), true)

-- Editing the PARENT moves the child, before either is saved.
d = LMEdit.new(fixture(), 7)
d:setField("Hard", "tier", 9)
eq("a parent edit reaches the child", (d:effective("Riverside", "tier")), 9)

-- Clearing an override falls back rather than reading as zero.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "tier", 5)
d:setField("Riverside", "tier", nil)
v, src = d:effective("Riverside", "tier")
eq("a cleared override falls back to the parent", v, 4)
eq("...sourced to the parent",                    src, "Hard")

-- _default is the implicit root under everything, including a zone with no
-- inherits at all.
d = LMEdit.new(fixture(), 7)
d:create("Loner")
v, src = d:effective("Loner", "tier")
eq("a parentless zone still sees _default", v, 2)
eq("...sourced to _default",                src, "_default")

-- Nothing anywhere: the registry default, and no source.
d = LMEdit.new(fixture(), 7)
v, src = d:effective("Riverside", "noannounce")
eq("an unset field falls to the registry default", v, false)
eq("...with no source",                            src, nil)

-- A cycle must not hang the walk.
d = LMEdit.new(fixture(), 7)
d.work.Hard.inherits      = "Riverside"
d.work.Riverside.inherits = "Hard"
v = d:effective("Riverside", "priority")
eq("a cycle still terminates and finds the value", v, 3)

-- ---------------------------------------------------------------------------
-- 9. The duplicated grammar must match LMPersist's real one
--
-- LMEdit cannot require LMPersist (server file, isServer() guard), so the
-- patterns are copied. This reads the persist source as TEXT and checks the
-- copy still matches - if someone widens the file format and not the editor,
-- the editor starts refusing names the server can store; narrow it and the
-- editor starts accepting names that vanish on restart.
-- ---------------------------------------------------------------------------

local f = io.open(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMIni.lua", "r")
if not f then
    print("FAIL could not read LMIni.lua to check the grammar copy")
    fail = fail + 1
else
    local text = f:read("*a")
    f:close()
    -- Plain substring search (find's 4th argument), not a pattern match: what
    -- is being compared here IS a pattern, and escaping one to look for the
    -- other is how this check would end up passing for the wrong reason.
    isTrue("LMIni still parses sections as [%w_%-%.]+",
        text:find("%[([%w_%-%.]+)%]", 1, true) ~= nil,
        "the section pattern changed - update LMEdit.NAME_PATTERN")
    isTrue("LMIni still parses keys as [%w_]+",
        text:find("([%w_]+)%s*=", 1, true) ~= nil,
        "the key pattern changed - update LMEdit.KEY_PATTERN")
    -- And the editor's copies say the same thing.
    eq("LMEdit name pattern", LMEdit.NAME_PATTERN, "^[%w_%-%.]+$")
    eq("LMEdit key pattern",  LMEdit.KEY_PATTERN,  "^[%w_]+$")
end

-- ---------------------------------------------------------------------------
-- 10. The store must survive a round trip through its own export
--
-- The import route spoke PhunZones and nothing else, so the .ini Limes writes
-- could not be pasted back: it died on line 1, because parseLua wants a Lua
-- table and an .ini opens with a comment. Backing up by copying the file out and
-- restoring by pasting it back is the first thing an admin tries, and "you can
-- export your store but not restore it" is not a property a store may have.
--
-- This pins the whole loop: serialize -> sniff -> parse -> identical records.
-- ---------------------------------------------------------------------------

-- The stub has to be in place before LMIni, which requires RDJson - stock Lua's
-- require would go looking for a .dll. Everything these two need is dofile'd.
local realRequire = require
require = function() end
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDJson.lua")
dofile(LM .. "shared/LMIni.lua")
dofile(LM .. "shared/LMImport.lua")
require = realRequire

local roundTrip = fixture()
roundTrip.Westpoint.fields.nobuilding = true      -- a boolean
roundTrip.Riverside.fields.title = "Riverside"    -- a string
local text = LMIni.serialize(roundTrip)

isTrue("our own export sniffs as an .ini", LMIni.looksLikeIni(text))
isTrue("a PhunZones export does not",
    not LMIni.looksLikeIni("return { version = 2, data = { A = { points = {} } } }"))
isTrue("a leading comment does not fool the sniffer",
    LMIni.looksLikeIni("; a comment\n\n[Zone]\nrects = 1,2,3,4\n"))

local okRt, res = LMImport.parseAny(text)
isTrue("parseAny accepts our own export", okRt, tostring(res))
if okRt then
    eq("...and reports the dialect", res.format, "ini")
    eq("...with every zone",         res.count, 4)
    eq("...inherits survives",       res.zones.Riverside.inherits, "Hard")
    eq("...rects survive",           res.zones.Westpoint.rects[2][3], 12000)
    eq("...numbers stay numbers",    res.zones.Hard.fields.tier, 4)
    eq("...booleans stay booleans",  res.zones.Westpoint.fields.nobuilding, true)
    eq("...strings stay strings",    res.zones.Riverside.fields.title, "Riverside")

    -- The real test: a draft built from the re-imported store is IDENTICAL to
    -- one built from the original. Any lossy field would show up as a change.
    local before = LMEdit.new(roundTrip, 1)
    local after  = LMEdit.new(res.zones, 1)
    local a, b = before:snapshot(), after:snapshot()
    local diff = LMEdit.new(a, 1)
    diff.base = b
    eq("a round trip changes nothing at all", select(3, diff:changeSet()), 0)
end

-- An .ini with no sections is refused as an .ini rather than being handed to the
-- PhunZones parser, which would report something misleading about Lua syntax.
local okEmpty, whyEmpty = LMImport.parseAny("; just a comment\n")
eq("a section-less .ini is refused", okEmpty, false)

print(string.format("LMEdit: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
