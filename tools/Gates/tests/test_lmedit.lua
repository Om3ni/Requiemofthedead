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

-- `risk` stands where the old `tier` number field did in these fixtures: tier
-- became the structural SLOT with the record-kind model (its own section at
-- the end), and everything here that used it was exercising ordinary field
-- mechanics. Registered with the old registration's clamp so the coercion
-- expectations carry over unchanged.
Limes.fields.register("TEdit", "risk", { type = "number", default = 0, min = 0, max = 10 })

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
        _default = { fields = { risk = 2 } },
        Hard     = { inherits = "_default", fields = { risk = 4 } },
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

d:setField("Riverside", "risk", 5)
d:addRect("Riverside", { 1, 2, 3, 4 })
eq("source fields untouched", src.Riverside.fields.risk, nil)
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
d:setField("Riverside", "risk", 5)
changed, removed, n = d:changeSet()
eq("one edit, one record on the wire", count(changed), 1)
eq("...and it is the one edited",      changed.Riverside ~= nil, true)
eq("...total change count",            n, 1)

-- landedIn: "are my changes already in that store?" - the editor's own-save
-- test. When a save's delta broadcast comes back, the draft is still dirty
-- against its BASE but identical to the LIVE store; that must read as landed
-- (rebase), while any divergence - a different value, a record someone else
-- added back - must not.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", 5)
d:remove("Westpoint")
local live = fixture()
live.Riverside.fields.risk = 5
live.Westpoint = nil
eq("a saved draft reads as landed", d:landedIn(live), true)
live.Riverside.fields.risk = 6
eq("a diverged value is not landed", d:landedIn(live), false)
live.Riverside.fields.risk = 5
live.Westpoint = { rects = {} }
eq("a removal someone restored is not landed", d:landedIn(live), false)
eq("a clean draft is trivially landed", LMEdit.new(fixture(), 7):landedIn(fixture()), true)

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

isTrue("a plain field key is fine",   LMEdit.keyProblem("risk") == nil)
isTrue("a hyphen in a key is not",    LMEdit.keyProblem("max-risk") ~= nil)
isTrue("'rects' is reserved",         LMEdit.keyProblem("rects") ~= nil)
isTrue("'inherits' is reserved",      LMEdit.keyProblem("inherits") ~= nil)
isTrue("'name' is reserved",          LMEdit.keyProblem("name") ~= nil)
isTrue("'kind' is reserved",          LMEdit.keyProblem("kind") ~= nil)
isTrue("'tier' is reserved",          LMEdit.keyProblem("tier") ~= nil)
isTrue("'moon' is reserved",          LMEdit.keyProblem("moon") ~= nil)
isTrue("the moon_ prefix is reserved", LMEdit.keyProblem("moon_speed") ~= nil)
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

-- risk is registered 0-10 (mirroring the old tier registration) and LMCore
-- CLAMPS out-of-range values rather than dropping them, so out-of-range is a
-- warning that says what it will become.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", 99)
isTrue("above max warns with the resolved value",
    findProblem(d:validate(), "Riverside", "warning", "resolves as 10"))
eq("...and does not block save", d:errorCount(), 0)

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", -4)
isTrue("below min warns", findProblem(d:validate(), "Riverside", "warning", "resolves as 0"))

-- A value that will not coerce is a different matter: LMCore drops it and the
-- zone silently inherits instead, which is exactly the outcome an admin editing
-- a field does not expect.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", "quite hard")
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
d:setField("Westpoint", "risk", 99)
d:setField("Riverside", "risk", 99)
probs = d:validate()
isTrue("problems are sorted by zone", probs[1].zone <= probs[#probs].zone)

-- ---------------------------------------------------------------------------
-- 8. applyChangeSet - both sides fold the same command the same way
-- ---------------------------------------------------------------------------

d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", 5)
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
eq("the edited value landed",                folded.Riverside.fields.risk, 5)
eq("the created zone landed",                folded.Rosewood.rects[1][3], 8400)

-- applyChangeSet must not alias the store it was given.
local before = fixture()
LMEdit.applyChangeSet(before, changed, removed)
eq("the source store is not mutated", before.Westpoint ~= nil, true)
eq("...nor its fields",               before.Riverside.fields.risk, nil)

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
d:setField("Riverside", "risk", 5)
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
        Hard      = { fields = { risk = 4 } },
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
eq("a template parent still supplies fields", (d:effective("Rosewood", "risk")), 4)

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
local v, src = d:effective("Riverside", "risk")
eq("an unset field resolves from the nearest ancestor", v, 4)
eq("...and says where it came from",                    src, "Hard")
eq("Riverside does not override it",  d:isOverride("Riverside", "risk"), false)

d:setField("Riverside", "risk", 5)
v, src = d:effective("Riverside", "risk")
eq("an override wins",            v, 5)
eq("...sourced to the zone",      src, "Riverside")
eq("...and reads as an override", d:isOverride("Riverside", "risk"), true)

-- Editing the PARENT moves the child, before either is saved.
d = LMEdit.new(fixture(), 7)
d:setField("Hard", "risk", 9)
eq("a parent edit reaches the child", (d:effective("Riverside", "risk")), 9)

-- Clearing an override falls back rather than reading as zero.
d = LMEdit.new(fixture(), 7)
d:setField("Riverside", "risk", 5)
d:setField("Riverside", "risk", nil)
v, src = d:effective("Riverside", "risk")
eq("a cleared override falls back to the parent", v, 4)
eq("...sourced to the parent",                    src, "Hard")

-- _default is the implicit root under everything, including a zone with no
-- inherits at all.
d = LMEdit.new(fixture(), 7)
d:create("Loner")
v, src = d:effective("Loner", "risk")
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
-- The literal parser (promoted from LMImport 2026-08-26).
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLuaLiteral.lua")
dofile(LM .. "shared/LMIni.lua")
dofile(LM .. "shared/LMImport.lua")
require = realRequire

local roundTrip = fixture()
-- fixture()'s template is named "Hard", which the S2 ladder migration in the
-- ini lane rightly treats as the old archetype and converts on the way back
-- in. Correct for real stores; wrong for this LOSSLESS pin - so the template
-- steps out of the ladder vocabulary first.
roundTrip.Bastion = roundTrip.Hard
roundTrip.Hard = nil
roundTrip.Riverside.inherits = "Bastion"
roundTrip.Westpoint.inherits = "Bastion"
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
    eq("...inherits survives",       res.zones.Riverside.inherits, "Bastion")
    eq("...rects survive",           res.zones.Westpoint.rects[2][3], 12000)
    eq("...numbers stay numbers",    res.zones.Bastion.fields.risk, 4)
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

-- ---------------------------------------------------------------------------
-- Profiles (M-A, 2026-08-07): the draft half. Flat bags, ordered, structural.
--
-- The stakes are the silent-erasure class: `profiles` is the fourth key the
-- copy/prune/equality trio enumerates, and a site that misses it deletes
-- profile membership as a side effect of editing an unrelated dial - no error,
-- no symptom, discovered when the moon stops mattering. Each site gets its own
-- pin here.
-- ---------------------------------------------------------------------------

local function profFixture()
    local f = fixture()
    f.Spooky   = { fields = { futureLoot = "rare" } }              -- a profile
    f.Sprinty  = { fields = { title = "fast" } }                   -- another
    f.Riverside.profiles = { "Spooky", "Sprinty" }
    return f
end

-- Copy: a draft carries the list, and carries it by value.
local pd = LMEdit.new(profFixture(), 3)
eq("a draft copies the profiles list", pd:profilesOf("Riverside")[1], "Spooky")
local srcStore = profFixture()
local pd2 = LMEdit.new(srcStore, 3)
srcStore.Riverside.profiles[1] = "Mutated"
eq("...by value, not by reference", pd2:profilesOf("Riverside")[1], "Spooky")

-- A clean draft with profiles is still silent - the equality half of the pin.
eq("a clean profiled draft has no changes", select(3, pd:changeSet()), 0)

-- Mutators.
isTrue("addProfile appends", pd:addProfile("Westpoint", "Spooky"))
eq("...at the end", pd:profilesOf("Westpoint")[1], "Spooky")
local okDup = pd:addProfile("Riverside", "Spooky")
eq("adding a duplicate is refused", okDup, false)
local okSelf = pd:addProfile("Riverside", "Riverside")
eq("a zone cannot apply itself", okSelf, false)
isTrue("removeProfile removes", pd:removeProfile("Westpoint", "Spooky"))
eq("...and an empty list goes absent, not empty", pd.work.Westpoint.profiles, nil)
local okGone = pd:removeProfile("Westpoint", "Spooky")
eq("removing what is not there is refused", okGone, false)

-- Order is precedence, so move must actually move.
isTrue("moveProfile toward the end", pd:moveProfile("Riverside", "Spooky", 1))
eq("...reorders", pd:profilesOf("Riverside")[2], "Spooky")
local okEnd = pd:moveProfile("Riverside", "Spooky", 1)
eq("moving past the end is refused", okEnd, false)

-- The cap.
local capd = LMEdit.new({ Z = { rects = { { 0, 0, 9, 9 } }, fields = {} } }, 1)
for i = 1, LMEdit.MAX_PROFILES do
    capd:addProfile("Z", "P" .. i)
end
local okOver = capd:addProfile("Z", "POver")
eq("the profile cap holds", okOver, false)

-- changeSet: membership and ORDER are both edits.
local cd = LMEdit.new(profFixture(), 3)
cd:removeProfile("Riverside", "Sprinty")
local changed = select(1, cd:changeSet())
isTrue("removing a profile is a change", changed.Riverside ~= nil)
eq("...and the saved record keeps the rest", changed.Riverside.profiles[1], "Spooky")
local od = LMEdit.new(profFixture(), 3)
od:moveProfile("Riverside", "Spooky", 1)
isTrue("reordering alone is a change", (select(1, od:changeSet())).Riverside ~= nil)

-- THE ERASURE PIN: editing an unrelated dial must not touch the list.
local ed = LMEdit.new(profFixture(), 3)
ed:setField("Riverside", "risk", 5)
local echanged = select(1, ed:changeSet())
eq("an unrelated edit still carries the profiles list",
   echanged.Riverside.profiles and echanged.Riverside.profiles[2], "Sprinty")
-- ...and folding it back into a store keeps it.
local folded = LMEdit.applyChangeSet(profFixture(), echanged, {})
eq("applyChangeSet preserves membership", folded.Riverside.profiles[1], "Spooky")

-- Prune canonicalisation: junk drops, duplicates collapse to first.
local jd = LMEdit.new({ Z = { rects = { { 0, 0, 9, 9 } },
    profiles = { "A", "", "A", 7, "B" }, fields = { risk = 1 } } }, 1)
local jchanged = select(1, LMEdit.new({}, 1) and jd:changeSet())
-- base was the same store, so force a change to see the pruned shape
jd:setField("Z", "risk", 2)
jchanged = select(1, jd:changeSet())
eq("prune drops junk and duplicates", #jchanged.Z.profiles, 2)
eq("...first occurrence wins", jchanged.Z.profiles[1], "A")
eq("...order otherwise kept", jchanged.Z.profiles[2], "B")

-- Rename rewrites BOTH reference kinds in one step.
local rd = LMEdit.new(profFixture(), 3)
local okRen, nRefs = rd:rename("Spooky", "Haunted")
isTrue("rename succeeds", okRen)
eq("profile references rewrote", rd:profilesOf("Riverside")[1], "Haunted")
local rd2 = LMEdit.new(profFixture(), 3)
rd2:addProfile("Hard", "Spooky")
local _, n2 = rd2:rename("Hard", "Harder")
isTrue("inherits rewrites still counted alongside", n2 >= 2)
eq("...children repointed", rd2.work.Riverside.inherits, "Harder")

-- effective(): profile values show, precedence holds, source is named.
local fd = LMEdit.new(profFixture(), 3)
local v, srcName = fd:effective("Riverside", "futureLoot")
eq("a profile's value resolves on the zone", v, "rare")
eq("...and the source names the profile", srcName, "Spooky")
-- Later profile beats earlier: both set `title`.
fd.work.Spooky.fields.title = "spooky"
local tv, tsrc = fd:effective("Riverside", "title")
eq("later profile wins", tv, "fast")
eq("...source agrees", tsrc, "Sprinty")
-- Own field beats profiles.
fd:setField("Riverside", "title", "mine")
eq("own field beats profiles", (fd:effective("Riverside", "title")), "mine")
-- A parent's profile reaches the child.
local gd = LMEdit.new(profFixture(), 3)
gd.work.Hard.profiles = { "Spooky" }
gd.work.Riverside.profiles = nil
eq("a parent's profile reaches the child",
   (gd:effective("Riverside", "futureLoot")), "rare")
-- isOverride stays own-fields-only: a profile-supplied value is not "moved".
eq("profile values are not overrides", gd:isOverride("Riverside", "futureLoot"), false)

-- Validate rules.
local vd = LMEdit.new(profFixture(), 3)
vd.work.Riverside.profiles[3] = "Riverside"
isTrue("self-application is an error",
    findProblem(vd:validate(), "Riverside", "error", "applies itself"))
vd.work.Riverside.profiles[3] = "Ghost"
isTrue("an unknown profile warns",
    findProblem(vd:validate(), "Riverside", "warning", "not in the store"))
vd.work.Riverside.profiles[3] = "Westpoint"
isTrue("a placed zone as a profile warns",
    findProblem(vd:validate(), "Riverside", "warning", "placed zone"))
vd.work.Riverside.profiles[3] = "Hard"
isTrue("a profile with inherits warns it is not followed",
    findProblem(vd:validate(), "Riverside", "warning", "not followed"))
vd.work.Riverside.profiles[3] = "Spooky"
isTrue("a duplicate application warns",
    findProblem(vd:validate(), "Riverside", "warning", "more than once"))
vd.work.Riverside.profiles[3] = nil
vd:remove("Spooky")
isTrue("deleting an applied profile warns the zone that loses it",
    findProblem(vd:validate(), "Riverside", "warning", "being deleted"))

-- keyProblem refuses the structural name as a field.
isTrue("'profiles' is refused as a field key", LMEdit.keyProblem("profiles") ~= nil)

-- Ini round-trip: structural, ordered, absent-when-empty.
local rtStore = profFixture()
local rtText = LMIni.serialize(rtStore)
isTrue("serialize writes a profiles line", rtText:find("profiles = Spooky,Sprinty", 1, true) ~= nil)
local rtZones = LMIni.parse(rtText)
eq("parse reads it back ordered", rtZones.Riverside.profiles[2], "Sprinty")
eq("zones without profiles stay without", rtZones.Westpoint.profiles, nil)
-- The numeric-name hazard: structural parsing keeps names as STRINGS.
local numZones = LMIni.parse("[Z]\nprofiles = 42\n")
eq("a numeric-looking profile name stays a string", numZones.Z.profiles[1], "42")
-- An empty value is absent, not present-empty.
local emptyZones = LMIni.parse("[Z]\nprofiles =\n")
eq("an empty profiles line is absent", emptyZones.Z.profiles, nil)
eq("...and does not become a field either", emptyZones.Z.fields.profiles, nil)

-- ---------------------------------------------------------------------------
-- RESOLVER PARITY (the standing fixture). LMCore.flattenChain and
-- LMEdit:effective are two independent implementations of one contract; this
-- drives the same store through both and diffs every key. M-B extends it
-- across moon phases. If this fails, nothing else about profiles matters.
-- ---------------------------------------------------------------------------

local parityStore = {
    _default = { profiles = { "Ambient" }, fields = { risk = 2, futureA = "root" } },
    Ambient  = { fields = { futureB = "ambient", futureA = "amb-a" } },
    Spooky   = { fields = { futureLoot = "rare", title = "spooky" } },
    Sprinty  = { fields = { title = "fast" } },
    Hard     = { inherits = "_default", fields = { risk = 4 } },
    Town     = { inherits = "Hard", rects = { { 0, 0, 99, 99 } },
                 profiles = { "Spooky", "Sprinty" },
                 fields = { priority = 1 } },
}
Limes.apply(parityStore, 40)
local parityDraft = LMEdit.new(parityStore, 40)
local KEYS = { "risk", "priority", "futureA", "futureB", "futureLoot", "title" }
for _, k in ipairs(KEYS) do
    local resolved = Limes.getZone("Town").fields[k]
    local eff      = parityDraft:effective("Town", k)
    -- flattenChain COERCES registered fields and effective() deliberately does
    -- not - compare through tostring so "4" and 4 agree, which is exactly the
    -- looseness the panel itself lives with.
    eq("parity on '" .. k .. "'", tostring(eff), tostring(resolved))
end

-- ...and across MOON PHASES (M-B). Both resolvers gate through the one shared
-- Limes.profileActive, and this is the proof: a phased profile under three
-- skies, every key compared through both paths at each.
require = function() end
dofile(LM .. "shared/LMMoon.lua")
require = realRequire
local moonSky = 4
LMMoon.setProvider(function() return moonSky end)
local moonStore = {
    _default  = { fields = { risk = 1, title = "calm" } },
    BloodMoon = { fields = { risk = 8, title = "blood", phases = "full" } },
    Waxer     = { fields = { title = "waxing", phases = "waxing" } },
    Town      = { inherits = "_default", rects = { { 0, 0, 99, 99 } },
                  profiles = { "BloodMoon", "Waxer" }, fields = {} },
}
for _, sky in ipairs({ 4, 2, 0 }) do
    moonSky = sky
    Limes.apply(moonStore, 50 + sky)
    local d2 = LMEdit.new(moonStore, 50 + sky)
    -- Compared through Limes.fields.get, not raw .fields: effective() applies
    -- the registry default when nothing sets a key, and fields.get is the
    -- store-side read with the same contract. Raw .fields holds only what is
    -- SET - that asymmetry is by design (the blank-inherits contract), not a
    -- parity break.
    for _, k in ipairs({ "risk", "title", "phases" }) do
        eq("moon parity, sky " .. sky .. ", '" .. k .. "'",
           tostring(d2:effective("Town", k)),
           tostring(Limes.fields.get(Limes.getZone("Town"), k)))
    end
end
-- Spot the actual values so the parity above cannot be vacuously equal.
moonSky = 4
Limes.apply(moonStore, 60)
eq("full moon reads blood",  Limes.getZone("Town").fields.title, "blood")
moonSky = 2
Limes.apply(moonStore, 61)
eq("first quarter reads waxing", Limes.getZone("Town").fields.title, "waxing")
moonSky = 0
Limes.apply(moonStore, 62)
eq("new moon reads calm",    Limes.getZone("Town").fields.title, "calm")

-- Validate speaks the phases grammar (these rules need LMMoon, so they live
-- after its load rather than with the other validate tests).
local pv = LMEdit.new(moonStore, 62)
pv:setField("BloodMoon", "phases", "full, bloodmoon")
isTrue("a junk token warns and names itself",
    findProblem(pv:validate(), "BloodMoon", "warning", "bloodmoon"))
pv:setField("BloodMoon", "phases", "bloodmoon")
isTrue("an all-junk phases is a never-active ERROR",
    findProblem(pv:validate(), "BloodMoon", "error", "NEVER"))
pv:setField("BloodMoon", "phases", "full")
eq("clean phases raise nothing new",
   findProblem(pv:validate(), "BloodMoon", "error", "NEVER"), nil)
local dv = LMEdit.new(moonStore, 62)
dv:setField("BloodMoon", "disabled", true)
isTrue("phased disabled warns that the zone will follow the moon",
    findProblem(dv:validate(), "Town", "warning", "follow the moon"))

-- ---------------------------------------------------------------------------
-- The record-kind model (S1, 2026-08-26): the draft half. The slot, the
-- terminal guards, the moon setters, kind-aware validation, the erasure pins
-- for the three new structural keys, and resolver parity across the tier bag.
-- ---------------------------------------------------------------------------

local function kindFixture()
    return {
        _default = { tier = "Newcomer", fields = { futureA = "root" } },
        Newcomer = { kind = "tier", fields = { rank = 1, risk = 1 } },
        Spicy    = { kind = "tier", fields = { rank = 4, risk = 4 },
                     moon = { phases = "full", fields = { risk = 9 } } },
        Calm     = { kind = "profile", fields = { title = "calm profile" } },
        Town     = { tier = "Spicy", rects = { { 0, 0, 99, 99 } }, fields = {} },
        Block    = { inherits = "Town", rects = { { 10, 10, 19, 19 } },
                     fields = { title = "The Block" } },
    }
end

-- The slot resolves against the draft through the SAME exported walk.
local kd = LMEdit.new(kindFixture(), 9)
local tv, tsrc2 = kd:effectiveTier("Block")
eq("effectiveTier walks the chain", tv, "Spicy")
eq("...and names the source", tsrc2, "Town")
eq("a slotless root falls to _default", (kd:effectiveTier("_default")), "Newcomer")

-- setTier: set, clear, and the refusals.
isTrue("setTier sets", kd:setTier("Block", "Newcomer"))
eq("...and the slot is the zone's own now", (kd:effectiveTier("Block")), "Newcomer")
isTrue("setTier clears on nil", kd:setTier("Block", nil))
eq("...back to the ancestor's", (kd:effectiveTier("Block")), "Spicy")
eq("a record cannot be its own tier", select(1, kd:setTier("Town", "Town")), false)

-- Terminal guards, every structural mutator.
eq("a tier cannot inherit",       select(1, kd:setInherits("Spicy", "Town")), false)
eq("a tier cannot take a tier",   select(1, kd:setTier("Spicy", "Newcomer")), false)
eq("a tier has no ground",        select(1, kd:addRect("Spicy", { 0, 0, 9, 9 })), false)
eq("a tier applies no profiles",  select(1, kd:addProfile("Spicy", "Calm")), false)
eq("a profile cannot inherit",    select(1, kd:setInherits("Calm", "Town")), false)
eq("a profile has no ground",     select(1, kd:setRects("Calm", { { 0, 0, 9, 9 } })), false)

-- Moon setters: tier-only, clearing rules.
isTrue("setMoonPhases on a tier", kd:setMoonPhases("Newcomer", "full"))
isTrue("setMoonField on a tier",  kd:setMoonField("Newcomer", "risk", 7))
eq("moon setters refuse a zone",    select(1, kd:setMoonPhases("Town", "full")), false)
eq("moon setters refuse a profile", select(1, kd:setMoonField("Calm", "risk", 1)), false)
eq("a moon field key is still a key",
   select(1, kd:setMoonField("Newcomer", "rects", 1)), false)

-- The picker: profiles in, tiers out, legacy templates still in.
kd = LMEdit.new(kindFixture(), 9)
kd.work.LegacyTmpl = { fields = { futureB = "x" } }
local cands = table.concat(kd:profileCandidates("Town"), ",")
eq("profile records and legacy templates are candidates", cands, "Calm,LegacyTmpl")

-- The tree lists PLACES: tier and profile records are not rows (they get
-- their own panels), legacy templates and unknown-kind anomalies stay
-- visible, and zone nesting is untouched.
kd.work.Weird = { kind = "faction", fields = {} }
local treeNames = {}
for _, row in ipairs(kd:tree()) do treeNames[#treeNames + 1] = row.name end
eq("tiers and profiles are not tree rows",
   table.concat(treeNames, ","), "LegacyTmpl,Town,Block,Weird,_default")

-- Validation.
local vk = LMEdit.new(kindFixture(), 9)
vk.work.Weird = { kind = "faction", fields = {} }
isTrue("an unknown kind is an error",
    findProblem(vk:validate(), "Weird", "error", "not a record kind"))
vk = LMEdit.new(kindFixture(), 9)
vk.work.Spicy.rects = { { 0, 0, 9, 9 } }
vk.work.Spicy.inherits = "Town"
vk.work.Spicy.tier = "Newcomer"
vk.work.Calm.profiles = { "Newcomer" }
local vprobs = vk:validate()
isTrue("a tier with ground is an error",    findProblem(vprobs, "Spicy", "error", "rectangles"))
isTrue("a tier with inherits is an error",  findProblem(vprobs, "Spicy", "error", "cannot inherit"))
isTrue("a tier with a tier is an error",    findProblem(vprobs, "Spicy", "error", "tier of its own"))
isTrue("a profile applying profiles is an error",
    findProblem(vprobs, "Calm", "error", "cannot apply profiles"))
vk = LMEdit.new(kindFixture(), 9)
vk.work.Town.moon = { phases = "full", fields = {} }
isTrue("a moon overlay on a zone is an error",
    findProblem(vk:validate(), "Town", "error", "only a tier record"))
vk = LMEdit.new(kindFixture(), 9)
vk:setTier("Town", "Ghost")
isTrue("a dangling tier slot warns",
    findProblem(vk:validate(), "Town", "warning", "not in the store"))
vk:setTier("Town", "Calm")
isTrue("a mis-kinded tier slot warns",
    findProblem(vk:validate(), "Town", "warning", "not a tier record"))
vk = LMEdit.new(kindFixture(), 9)
vk.work.Town.profiles = { "Spicy" }
isTrue("applying a tier as a profile is an error",
    findProblem(vk:validate(), "Town", "error", "is a tier"))
vk = LMEdit.new(kindFixture(), 9)
vk:remove("Spicy")
isTrue("deleting a tier warns the zones standing on it",
    findProblem(vk:validate(), "Town", "warning", "loses its tier dials"))
vk = LMEdit.new(kindFixture(), 9)
vk:setMoonPhases("Newcomer", "bloodmoon")
isTrue("all-junk moon phases is a never-active error",
    findProblem(vk:validate(), "Newcomer", "error", "NEVER"))
vk = LMEdit.new(kindFixture(), 9)
vk:setMoonField("Newcomer", "risk", "very")
isTrue("moon dials get the same spec checks as fields",
    findProblem(vk:validate(), "Newcomer", "error", "is not a number"))

-- lootReduce grammar in validate.
vk = LMEdit.new(kindFixture(), 9)
vk:setField("Calm", "lootReduce", "Base.Axe=25; cat:Ammo=50")
eq("a clean lootReduce raises nothing",
   findProblem(vk:validate(), "Calm", "error", "lootReduce"), nil)
vk:setField("Calm", "lootReduce", "Base.Axe=25; garbage")
isTrue("a bad rule among good ones warns",
    findProblem(vk:validate(), "Calm", "warning", "garbage"))
vk:setField("Calm", "lootReduce", "nothing here")
isTrue("an all-junk rule list is an error",
    findProblem(vk:validate(), "Calm", "error", "no rule that parses"))

-- THE ERASURE PINS for kind/tier/moon: a clean draft is silent, an unrelated
-- edit carries all three, and the fold keeps them.
local ck = LMEdit.new(kindFixture(), 9)
eq("a clean kinded draft has no changes", select(3, ck:changeSet()), 0)
ck:setField("Town", "risk", 5)
local kchanged = select(1, ck:changeSet())
eq("an unrelated edit still carries the slot", kchanged.Town.tier, "Spicy")
ck = LMEdit.new(kindFixture(), 9)
ck:setMoonField("Spicy", "risk", 8)
kchanged = select(1, ck:changeSet())
eq("a moon edit is a change", kchanged.Spicy ~= nil, true)
eq("...that carries kind", kchanged.Spicy.kind, "tier")
eq("...and the whole overlay", kchanged.Spicy.moon.phases, "full")
local kfolded = LMEdit.applyChangeSet(kindFixture(), kchanged, {})
eq("applyChangeSet keeps the overlay", kfolded.Spicy.moon.fields.risk, 8)
-- kind = "zone" normalises to absent so it cannot masquerade as an edit.
ck = LMEdit.new(kindFixture(), 9)
ck.work.Town.kind = "zone"
eq("an explicit kind=zone is not a change", select(3, ck:changeSet()), 0)
-- A slot change alone is a change.
ck = LMEdit.new(kindFixture(), 9)
ck:setTier("Town", "Newcomer")
eq("a slot change alone is a change", select(1, ck:changeSet()).Town.tier, "Newcomer")

-- Rename carries the slot (the third reference kind).
local rk = LMEdit.new(kindFixture(), 9)
local okRk, nRk = rk:rename("Spicy", "Blazing")
isTrue("renaming a tier succeeds", okRk)
eq("...and the zones standing on it repoint", rk.work.Town.tier, "Blazing")

-- Ini round trip: kind, the slot, and the flat moon encoding.
local kText = LMIni.serialize(kindFixture())
isTrue("serialize writes kind",        kText:find("kind = tier", 1, true) ~= nil)
isTrue("serialize writes the slot",    kText:find("tier = Spicy", 1, true) ~= nil)
isTrue("serialize writes moon_phases", kText:find("moon_phases = full", 1, true) ~= nil)
isTrue("serialize writes moon dials",  kText:find("moon_risk = 9", 1, true) ~= nil)
local kBack = LMIni.parse(kText)
eq("kind reads back",       kBack.Spicy.kind, "tier")
eq("the slot reads back",   kBack.Town.tier, "Spicy")
eq("moon reads back nested", kBack.Spicy.moon.fields.risk, 9)
eq("...with its gate",      kBack.Spicy.moon.phases, "full")
-- A pre-slot store's numeric tier survives as a STRING for the migration.
local oldBack = LMIni.parse("[Z]\ntier = 5\n")
eq("a legacy numeric tier stays a string", oldBack.Z.tier, "5")
-- The full loop: nothing changes across serialize+parse.
local kDiff = LMEdit.new(LMIni.parse(kText), 1)
kDiff.base = LMEdit.new(kindFixture(), 1):snapshot()
eq("a kinded round trip changes nothing", select(3, kDiff:changeSet()), 0)

-- RESOLVER PARITY across the tier bag and its moon overlay: the same store
-- through both resolvers under three skies, every key compared.
for _, sky in ipairs({ 4, 0 }) do
    moonSky = sky
    Limes.apply(kindFixture(), 70 + sky)
    local pd3 = LMEdit.new(kindFixture(), 70 + sky)
    for _, zone in ipairs({ "Town", "Block", "_default", "Spicy", "Calm" }) do
        for _, k in ipairs({ "risk", "rank", "futureA", "title" }) do
            eq("kind parity, sky " .. sky .. ", " .. zone .. ".'" .. k .. "'",
               tostring(pd3:effective(zone, k)),
               tostring(Limes.fields.get(Limes.getZone(zone), k)))
        end
    end
end
-- Spot the actual values so the parity cannot be vacuously equal.
moonSky = 4
Limes.apply(kindFixture(), 80)
eq("full moon: the overlay wins", Limes.getZone("Town").fields.risk, 9)
moonSky = 0
Limes.apply(kindFixture(), 81)
eq("new moon: the base dial wins", Limes.getZone("Town").fields.risk, 4)

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
