-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMEdit - the editor's working copy: draft, validate, diff. No engine, no UI.
--
-- M4's editor does not mutate the store. It takes a DRAFT of the raw zones,
-- edits that, and on an explicit Save hands the server a minimal change set;
-- the store only moves when the server's echo comes back (docs/limes-design.md
-- §6.1 rules 2 and 3). Everything in this file exists to make that one command
-- correct: what changed, what was pruned, and what must never be sent at all.
--
-- Split out from the panel deliberately. The map overlay is engine-coupled and
-- can only be tested by looking at it; this is where the rules that cost real
-- money if they are wrong actually live - the diff that keeps one edit to one
-- small packet (§6.1 rule 4), the prune that stops the store ratcheting (rule
-- 5), and the revision the server checks before applying (rule 7). All of it is
-- stock Lua, so it is tested rather than demonstrated.
--
-- IT ALSO RUNS SERVER-SIDE. A validated draft is not a trusted draft: LMSync
-- calls validate() again on what arrives, because the client half of this file
-- is running on a machine we do not own.
--
-- THE PERSIST GRAMMAR IS PART OF THE CONTRACT. LMPersist.parse only recognises
-- section names matching [%w_%-%.]+ and keys matching [%w_]+. A zone called
-- "Rosewood Fire Dept" serialises happily, survives the wire, resolves live -
-- and is GONE on the next server boot, because the section header will not
-- match on the way back in. There is no error, no warning, no partial record;
-- the zone simply is not there any more. Catching that at the moment the admin
-- types the name is the only place it is cheap.

Limes = Limes or {}
LMEdit = LMEdit or {}
LMEdit.__index = LMEdit

-- Mirrors of LMPersist's own patterns. Duplicated rather than imported because
-- LMPersist is a server file behind an isServer() guard and the editor is a
-- client one; the test suite pins them equal so the copy cannot rot.
LMEdit.NAME_PATTERN = "^[%w_%-%.]+$"
LMEdit.KEY_PATTERN  = "^[%w_]+$"

-- ---------------------------------------------------------------------------
-- Copying
-- ---------------------------------------------------------------------------

local function copyRect(r)
    return { r[1], r[2], r[3], r[4] }
end

local function copyRecord(rec)
    local out = { inherits = rec.inherits }
    if rec.rects then
        local rects = {}
        for i = 1, #rec.rects do rects[i] = copyRect(rec.rects[i]) end
        out.rects = rects
    end
    -- Enumerated COPIES, all of them: this function is the moment a raw record
    -- becomes a draft, and any key it does not name is silently gone from every
    -- draft, every save, and (via applyChangeSet) eventually the store itself.
    -- `profiles` earned its line here the same day it earned one in
    -- stripServerOnly.
    if rec.profiles then
        local profiles = {}
        for i = 1, #rec.profiles do profiles[i] = rec.profiles[i] end
        out.profiles = profiles
    end
    if rec.fields then
        local fields = {}
        for k, v in pairs(rec.fields) do fields[k] = v end
        out.fields = fields
    end
    return out
end

local function copyStore(raw)
    local out = {}
    for name, rec in pairs(raw or {}) do out[name] = copyRecord(rec) end
    return out
end

-- ---------------------------------------------------------------------------
-- Pruning - the shape that goes on the wire and into the file
--
-- §6.1 rule 5: a field the admin cleared is REMOVED, never written as an empty
-- value. The difference matters because of inheritance: an absent key inherits
-- its parent's value, while a key present with "" is a value in its own right
-- that flattenChain has to special-case. Merge-never-prune is how a store
-- silently becomes append-only, and an append-only store is what put PhunZones
-- at 62.8% of all mod traffic (Appendix A.2).
-- ---------------------------------------------------------------------------

local function pruneRecord(rec)
    if not rec then return nil end
    local out = {}

    local inh = rec.inherits
    if type(inh) == "string" and inh ~= "" then out.inherits = inh end

    if rec.rects and #rec.rects > 0 then
        local rects = {}
        for i = 1, #rec.rects do
            local r = rec.rects[i]
            local x1, y1 = tonumber(r and r[1]), tonumber(r and r[2])
            local x2, y2 = tonumber(r and r[3]), tonumber(r and r[4])
            if x1 and y1 and x2 and y2 then
                -- Normalised on the way out, exactly as LMCore would on the way
                -- in, so a rect dragged bottom-right-to-top-left is stored the
                -- same as one dragged the other way and the diff below does not
                -- see a change that is only a gesture direction.
                if x2 < x1 then x1, x2 = x2, x1 end
                if y2 < y1 then y1, y2 = y2, y1 end
                rects[#rects + 1] = { math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2) }
            end
        end
        if #rects > 0 then out.rects = rects end
    end

    -- Canonicalised like rects: junk entries dropped, duplicates collapse to
    -- their FIRST occurrence (the position the admin put it in is the one that
    -- means something), and an empty list is absent rather than present-empty -
    -- rule 5 again, since `profiles =` re-read from the ini would otherwise
    -- come back as a string field.
    if rec.profiles and #rec.profiles > 0 then
        local profiles, seen = {}, {}
        for i = 1, #rec.profiles do
            local p = rec.profiles[i]
            if type(p) == "string" and p ~= "" and not seen[p] then
                seen[p] = true
                profiles[#profiles + 1] = p
            end
        end
        if #profiles > 0 then out.profiles = profiles end
    end

    if rec.fields then
        local fields, any = {}, false
        for k, v in pairs(rec.fields) do
            if v ~= nil and v ~= "" then fields[k] = v; any = true end
        end
        if any then out.fields = fields end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Equality - what counts as "this zone changed"
-- ---------------------------------------------------------------------------

local function sameRects(a, b)
    if not a and not b then return true end
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        for j = 1, 4 do
            if a[i][j] ~= b[i][j] then return false end
        end
    end
    return true
end

local function sameFields(a, b)
    if not a and not b then return true end
    a, b = a or {}, b or {}
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function sameProfiles(a, b)
    if not a and not b then return true end
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    -- Order matters: [Hard, BloodMoon] and [BloodMoon, Hard] resolve
    -- differently (later wins), so reordering IS an edit.
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function sameRecord(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    return a.inherits == b.inherits
       and sameRects(a.rects, b.rects)
       and sameProfiles(a.profiles, b.profiles)
       and sameFields(a.fields, b.fields)
end

-- ---------------------------------------------------------------------------
-- Draft
-- ---------------------------------------------------------------------------

-- rawZones is copied, not referenced: the live store must not move under the
-- editor, and the editor must not move under a broadcast that lands mid-edit.
function LMEdit.new(rawZones, revision)
    local d = setmetatable({}, LMEdit)
    d.base    = copyStore(rawZones)
    d.work    = copyStore(rawZones)
    d.baseRev = tonumber(revision) or 0
    return d
end

function LMEdit:revision() return self.baseRev end

-- MEMOISED, AND THE CALLER MUST TREAT IT AS READ-ONLY. The map editor calls
-- this inside its render pass, so a fresh table plus a sort of ~76 names would
-- be allocated and thrown away sixty times a second for the entire time the tab
-- is open. The cache is dropped by the only three operations that can change
-- the set - create, remove, rename - and by nothing else, because editing a
-- zone's fields or rects cannot add or lose a name.
function LMEdit:names()
    if not self._names then
        local out = {}
        for name in pairs(self.work) do out[#out + 1] = name end
        table.sort(out)
        self._names = out
    end
    return self._names
end

function LMEdit:get(name) return self.work[name] end

function LMEdit:exists(name) return self.work[name] ~= nil end

-- Zones that name `parent` directly. Used by rename (rewrite) and remove
-- (warn), and by the panel to show what a template is carrying.
function LMEdit:childrenOf(parent)
    local out = {}
    for name, rec in pairs(self.work) do
        if rec.inherits == parent then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function LMEdit:create(name, rec)
    name = tostring(name or "")
    if name == "" then return false, "A zone needs a name." end
    if self.work[name] then return false, "'" .. name .. "' already exists." end
    local why = LMEdit.nameProblem(name)
    if why then return false, why end
    self.work[name] = rec and copyRecord(rec) or { rects = {}, fields = {} }
    self._names = nil
    return true
end

function LMEdit:remove(name)
    if not self.work[name] then return false, "No such zone." end
    self.work[name] = nil
    self._names = nil
    return true
end

-- RENAME REWRITES THE CHILDREN, in the same step, or not at all.
--
-- This is the operation the store was waiting for: the shipped ladder has
-- Medium (tier 2) and Intermediate (tier 3) as English synonyms on adjacent
-- rungs, and fixing that means renaming a template that other zones inherit
-- from. Done as two operations - rename, then repoint - the store spends the
-- interval with every child pointing at a zone that no longer exists, and if
-- the second half is forgotten those children silently fall back to _default.
-- Here the rewrite is not a follow-up the caller can skip.
function LMEdit:rename(old, new)
    new = tostring(new or "")
    if not self.work[old] then return false, "No such zone." end
    if new == old then return true, 0 end
    if new == "" then return false, "A zone needs a name." end
    if self.work[new] then return false, "'" .. new .. "' already exists." end
    local why = LMEdit.nameProblem(new)
    if why then return false, why end

    self.work[new] = self.work[old]
    self.work[old] = nil
    self._names = nil
    local n = 0
    for _, rec in pairs(self.work) do
        if rec.inherits == old then rec.inherits = new; n = n + 1 end
        -- Profile references are the SECOND place a name lives, and they get
        -- the same same-step guarantee: a rename that rewrote inherits but left
        -- profiles lists pointing at the old name would silently strip those
        -- zones of the profile at the next resolve.
        for i = 1, #(rec.profiles or {}) do
            if rec.profiles[i] == old then rec.profiles[i] = new; n = n + 1 end
        end
    end
    return true, n
end

function LMEdit:setInherits(name, parent)
    local rec = self.work[name]
    if not rec then return false, "No such zone." end
    if parent == nil or parent == "" then rec.inherits = nil; return true end
    parent = tostring(parent)
    if parent == name then return false, "A zone cannot inherit from itself." end
    rec.inherits = parent
    return true
end

-- ---------------------------------------------------------------------------
-- Profiles - the ordered list of field-bags this record applies (flat bags;
-- see LMCore's flattenChain for the merge contract). The mutators mirror the
-- rects trio in shape: small, draft-only, no coercion, validate() reports.
-- ---------------------------------------------------------------------------

LMEdit.MAX_PROFILES = 16

-- The list, by reference, never nil - callers iterate it. Do not mutate the
-- returned table directly; the mutators below keep the invariants.
function LMEdit:profilesOf(name)
    local rec = self.work[name]
    return (rec and rec.profiles) or {}
end

function LMEdit:addProfile(name, profile)
    local rec = self.work[name]
    if not rec then return false, "No such zone." end
    profile = tostring(profile or "")
    if profile == "" then return false, "A profile needs a name." end
    if profile == name then return false, "A zone cannot apply itself as a profile." end
    rec.profiles = rec.profiles or {}
    for i = 1, #rec.profiles do
        if rec.profiles[i] == profile then return false, "'" .. profile .. "' is already applied." end
    end
    if #rec.profiles >= LMEdit.MAX_PROFILES then
        return false, "A zone can apply at most " .. LMEdit.MAX_PROFILES .. " profiles."
    end
    rec.profiles[#rec.profiles + 1] = profile
    return true, #rec.profiles
end

function LMEdit:removeProfile(name, profile)
    local rec = self.work[name]
    if not rec or not rec.profiles then return false, "No such profile." end
    for i = 1, #rec.profiles do
        if rec.profiles[i] == profile then
            table.remove(rec.profiles, i)
            if #rec.profiles == 0 then rec.profiles = nil end
            return true
        end
    end
    return false, "No such profile."
end

-- delta is +1 (toward the end, stronger) or -1 (toward the front, weaker).
-- Order IS precedence - later beats earlier - so this is the admin's tiebreak.
function LMEdit:moveProfile(name, profile, delta)
    local rec = self.work[name]
    if not rec or not rec.profiles then return false, "No such profile." end
    for i = 1, #rec.profiles do
        if rec.profiles[i] == profile then
            local j = i + (delta > 0 and 1 or -1)
            if j < 1 or j > #rec.profiles then return false, "Already at the end." end
            rec.profiles[i], rec.profiles[j] = rec.profiles[j], rec.profiles[i]
            return true
        end
    end
    return false, "No such profile."
end

-- The Add picker's contents, computed here so it is testable without a UI:
-- template zones (no geometry) that are not the zone itself and not already
-- applied, sorted. A placed zone is deliberately excluded - its fields would
-- merge fine, but "apply Louisville to the gun store" is a category mistake
-- the picker should not invite.
function LMEdit:profileCandidates(name)
    local rec = self.work[name]
    local have = {}
    if rec then
        for i = 1, #(rec.profiles or {}) do have[rec.profiles[i]] = true end
    end
    local out = {}
    for zname, z in pairs(self.work) do
        if zname ~= name and zname ~= "_default" and not have[zname]
            and (not z.rects or #z.rects == 0) then
            out[#out + 1] = zname
        end
    end
    table.sort(out)
    return out
end

-- value nil (or "") clears the field. Nothing is coerced here: the draft holds
-- what the admin typed, validate() reports what it will become, and LMCore does
-- the actual coercion once at resolve time. Coercing in three places is how the
-- three places start to disagree.
function LMEdit:setField(name, key, value)
    local rec = self.work[name]
    if not rec then return false, "No such zone." end
    key = tostring(key or "")
    local why = LMEdit.keyProblem(key)
    if why then return false, why end
    rec.fields = rec.fields or {}
    if value == nil or value == "" then rec.fields[key] = nil
    else rec.fields[key] = value end
    return true
end

function LMEdit:setRects(name, rects)
    local rec = self.work[name]
    if not rec then return false, "No such zone." end
    local out = {}
    for i = 1, #(rects or {}) do out[i] = copyRect(rects[i]) end
    rec.rects = out
    return true
end

function LMEdit:addRect(name, r)
    local rec = self.work[name]
    if not rec then return false, "No such zone." end
    rec.rects = rec.rects or {}
    rec.rects[#rec.rects + 1] = copyRect(r)
    return true, #rec.rects
end

function LMEdit:removeRect(name, idx)
    local rec = self.work[name]
    if not rec or not rec.rects or not rec.rects[idx] then return false, "No such rect." end
    table.remove(rec.rects, idx)
    return true
end

-- ---------------------------------------------------------------------------
-- Containment and the tree (§11.3)
--
-- A zone drawn inside another is that zone's CHILD: it takes the parent's
-- policies as defaults and overrides what it wants to. There is one parent slot
-- in the record and this is what it means - `inherits`. Tier is a field you set,
-- not a template you point at, so nothing is lost by spending the slot here, and
-- an imported layer whose zones inherit from geometry-less templates keeps
-- resolving exactly as before (a template is a zone with no rects, which is why
-- it shows up in the tree as a folder that happens to have nowhere to stand).
--
-- Only the FIELDS follow the geometry. The spatial lookup has resolved nesting
-- correctly since M0 without any of this: Limes.getLocation takes the smallest
-- containing zone, so an apartment block drawn inside Rosewood already wins
-- inside its own walls.
-- ---------------------------------------------------------------------------

local function rectInside(inner, outer)
    return inner[1] >= outer[1] and inner[2] >= outer[2]
       and inner[3] <= outer[3] and inner[4] <= outer[4]
end

local function areaOf(rects)
    local a = 0
    for i = 1, #(rects or {}) do
        local r = rects[i]
        a = a + (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
    end
    return a
end

-- Does `host` swallow `rects` whole? EVERY rect has to land inside ONE of the
-- host's, not merely inside their combined bounding box - two rects at opposite
-- corners of the map have a bounding box covering everything between them, and
-- "inside Rosewood" must not mean "somewhere in the rectangle from Rosewood to
-- Louisville".
local function contains(hostRects, rects)
    if not hostRects or #hostRects == 0 then return false end
    if not rects or #rects == 0 then return false end
    for i = 1, #rects do
        local ok = false
        for j = 1, #hostRects do
            if rectInside(rects[i], hostRects[j]) then ok = true; break end
        end
        if not ok then return false end
    end
    return true
end

-- The zone that should adopt `name` on geometry alone: the SMALLEST zone whose
-- rectangles swallow all of this one's. Smallest, because nesting is usually
-- several deep - an apartment inside Rosewood inside a region - and the useful
-- parent is the innermost one. Ties break on name so two candidates of equal
-- area give the same answer on every machine.
--
-- Returns nil when nothing contains it, when it has no geometry of its own, or
-- when the only candidate is already an ancestor of the zone by some other
-- route (which would close a loop).
function LMEdit:containerOf(name)
    local rec = self.work[name]
    if not rec or not rec.rects or #rec.rects == 0 then return nil end

    -- Everything that would be reached by walking up from a candidate; adopting
    -- a descendant as a parent is how a cycle gets made by accident.
    local descendants = {}
    local function markDescendants(root)
        for _, other in ipairs(self:names()) do
            local r = self.work[other]
            if r and r.inherits == root and not descendants[other] then
                descendants[other] = true
                markDescendants(other)
            end
        end
    end
    markDescendants(name)

    local best, bestArea = nil, nil
    for _, other in ipairs(self:names()) do
        if other ~= name and not descendants[other] then
            local o = self.work[other]
            if o and contains(o.rects, rec.rects) then
                local a = areaOf(o.rects)
                if bestArea == nil or a < bestArea or (a == bestArea and other < best) then
                    best, bestArea = other, a
                end
            end
        end
    end
    return best
end

-- Point the zone at whatever now contains it. Returns the new parent (or nil)
-- and whether anything moved, so a caller can say so rather than guessing.
--
-- A zone dragged OUT of everything loses its parent, which is the same rule read
-- backwards; the alternative is a zone that visibly sits nowhere near its parent
-- but still takes its policies, and no admin would find that by looking.
function LMEdit:reparentByContainment(name)
    local rec = self.work[name]
    if not rec then return nil, false end
    local parent = self:containerOf(name)
    local was = rec.inherits
    if parent == was then return parent, false end
    rec.inherits = parent
    return parent, true
end

-- The zone list as a hierarchy: a FLAT array of { name, depth, parent, leaf },
-- parents before their children, siblings sorted by name. Flat because that is
-- what a list box draws, and computing it here keeps the panel from owning a
-- second, subtly different idea of what nests inside what.
--
-- Orphans - a zone whose `inherits` names something not in the store - are
-- roots. The live imported layer has several, and hiding them because their
-- parent is missing is precisely the wrong response to a dangling reference.
--
-- Cycle-safe by construction: a node is emitted once, tracked in `seen`, and
-- anything still unemitted at the end is appended at depth 0 rather than being
-- lost. validate() is what complains about the cycle; this only refuses to hang.
-- NESTING IS SPATIAL, NOT INHERITED (revised 2026-08-05).
--
-- A row is a child of another row only when its parent OCCUPIES SPACE. The tree
-- used to nest on `inherits` alone, and in an imported layer `inherits` is the
-- difficulty ladder - so every zone on the map filed itself under Easy, Hard,
-- Intermediate or Very_Hard, and finding Rosewood meant knowing its tier first.
-- That is a category the admin did not ask for and cannot navigate by.
--
-- A template is not a place. It has no geometry, nothing is inside it, and it
-- has no business being a folder. Zones under one render at the top level in
-- plain alphabetical order, which is what a list of names should do; real
-- containment - a block drawn inside a town - still nests, because there the
-- parent genuinely is somewhere you can stand.
--
-- The FIELD chain is untouched by any of this. A zone still inherits its
-- policies from its template exactly as before; only the shape of the list
-- changed. Sorting is alphabetical at every level, roots included, because
-- self:names() is sorted and both loops below walk it in that order.
local function hasGeometry(rec)
    return rec and rec.rects and #rec.rects > 0
end

function LMEdit:tree()
    local kids, roots = {}, {}
    local names = self:names()
    for i = 1, #names do
        local name = names[i]
        local p = self.work[name].inherits
        if p and self.work[p] and hasGeometry(self.work[p]) then
            kids[p] = kids[p] or {}
            table.insert(kids[p], name)
        else
            roots[#roots + 1] = name
        end
    end

    local out, seen = {}, {}
    local function emit(name, depth)
        if seen[name] then return end
        seen[name] = true
        local children = kids[name]
        out[#out + 1] = { name = name, depth = depth, parent = self.work[name].inherits,
                          leaf = (children == nil or #children == 0) }
        for _, c in ipairs(children or {}) do emit(c, depth + 1) end
    end
    for i = 1, #roots do emit(roots[i], 0) end
    for i = 1, #names do
        if not seen[names[i]] then
            out[#out + 1] = { name = names[i], depth = 0,
                              parent = self.work[names[i]].inherits, leaf = true }
            seen[names[i]] = true
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Reading a field the way the game will read it
--
-- The panel has to show what a zone's dial ACTUALLY resolves to, not what this
-- record happens to carry: a child that overrides nothing must still display
-- its parent's tier, or an admin sets a value that was already in force and
-- writes a redundant override into the store for nothing.
--
-- LMCore resolves against the live store; this resolves against the DRAFT,
-- which is the whole point - a change to the parent has to be visible on the
-- child before either has been saved. Chain order matches flattenChain exactly:
-- nearest wins, "_default" is the implicit root under everything.
-- ---------------------------------------------------------------------------

-- Does THIS record set the key itself (as opposed to inheriting it)? Drives the
-- "overridden" marker in the form, and is what tells an admin the difference
-- between a value that is theirs and a value that is merely visible.
function LMEdit:isOverride(zone, key)
    local rec = self.work[zone]
    return (rec and rec.fields and rec.fields[key] ~= nil) and true or false
end

-- One record's answer for `key`, nearest-source-first: its own fields, then its
-- applied profiles in REVERSE order (later in the list beats earlier, so the
-- nearest-first walk checks the last one first). Mirrors flattenChain's
-- own-beats-profiles, later-profile-beats-earlier order exactly - the two
-- resolvers are independent implementations and this helper is half of keeping
-- them honest; the other half is that both gate through Limes.profileActive,
-- so "is this profile on right now" has exactly one answer per machine.
--
-- `phases` is never served FROM a profile (it is the activation condition, not
-- cargo) - but a record's OWN phases value is served normally, which is how the
-- Details form edits it on the profile itself.
local function recordValue(self, cur, rec, key)
    local v = rec.fields and rec.fields[key]
    if v ~= nil and v ~= "" then return v, cur end
    local profs = rec.profiles
    if profs and key ~= "phases" then
        local gate = Limes.profileActive
        for i = #profs, 1, -1 do
            local prof = self.work[profs[i]]
            if prof and (not gate or gate(prof)) then
                local pv = prof.fields and prof.fields[key]
                if pv ~= nil and pv ~= "" then return pv, profs[i] end
            end
        end
    end
    return nil, nil
end

-- Returns value, source - where source is the zone or profile name the value
-- came from, "_default", or nil when only the registry default is left.
function LMEdit:effective(zone, key)
    local seen, cur = {}, zone
    while cur do
        if seen[cur] then break end            -- a cycle; validate() reports it
        seen[cur] = true
        local rec = self.work[cur]
        if not rec then break end
        local v, src = recordValue(self, cur, rec, key)
        if v ~= nil then return v, src end
        cur = rec.inherits
    end

    if not seen["_default"] then
        local root = self.work["_default"]
        if root then
            local v, src = recordValue(self, "_default", root, key)
            if v ~= nil then return v, src end
        end
    end

    -- NOT `spec and spec.default or nil`: that idiom cannot carry a default of
    -- `false`, which is exactly what `disabled` and `noannounce` are registered
    -- with, and it would report them as having no default at all.
    local spec = Limes.fields and Limes.fields.spec and Limes.fields.spec(key)
    if spec then return spec.default, nil end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Name / key grammar
-- ---------------------------------------------------------------------------

-- Returns nil when the name is fine, or the reason it is not. Phrased for the
-- admin, because this is the message the editor puts next to the field.
function LMEdit.nameProblem(name)
    name = tostring(name or "")
    if name == "" then return "A zone needs a name." end
    if not name:match(LMEdit.NAME_PATTERN) then
        return "'" .. name .. "' cannot be saved: zone names take letters, digits, "
            .. "_ - and . only. Anything else is lost when the server re-reads its "
            .. "file, and the zone disappears on the next restart."
    end
    return nil
end

function LMEdit.keyProblem(key)
    key = tostring(key or "")
    if key == "" then return "A field needs a name." end
    if key == "rects" or key == "inherits" or key == "name" or key == "profiles" then
        return "'" .. key .. "' is part of the record structure and cannot be a field."
    end
    if not key:match(LMEdit.KEY_PATTERN) then
        return "'" .. key .. "' cannot be saved: field names take letters, digits and _ only."
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Validation
--
-- Two levels, and the split is not cosmetic. An ERROR is something that loses
-- data or resolves wrongly, and Save is refused. A WARNING is something the
-- LIVE STORE ALREADY CONTAINS - the imported layer has dangling inherits and
-- childless templates in it right now - so promoting those to errors would mean
-- the first thing the editor does on a real server is refuse to save it.
-- ---------------------------------------------------------------------------

local function problem(list, level, zone, msg)
    list[#list + 1] = { level = level, zone = zone, msg = msg }
end

-- Walks `inherits` from `name` upwards, returning the name it loops on, or nil.
local function cycleAt(work, name)
    local seen, cur = {}, name
    while cur do
        if seen[cur] then return cur end
        seen[cur] = true
        local rec = work[cur]
        if not rec then return nil end
        cur = rec.inherits
    end
    return nil
end

-- Returns a list of { level, zone, msg }. Sorted by zone then message so the
-- panel's list does not reshuffle between keystrokes.
function LMEdit:validate()
    local out = {}
    local names = self:names()

    for i = 1, #names do
        local name = names[i]
        local rec  = self.work[name]

        local why = LMEdit.nameProblem(name)
        if why then problem(out, "error", name, why) end

        -- Inheritance
        if rec.inherits then
            if rec.inherits == name then
                problem(out, "error", name, "inherits from itself.")
            elseif not self.work[rec.inherits] then
                problem(out, "warning", name, "inherits '" .. rec.inherits
                    .. "', which is not in the store - its fields resolve from _default instead.")
            else
                local loop = cycleAt(self.work, name)
                if loop then
                    problem(out, "error", name, "inheritance loops back through '" .. loop
                        .. "'; the chain is cut at that point and the fields beyond it are lost.")
                end
            end
        end

        -- Rects
        for j = 1, #(rec.rects or {}) do
            local r = rec.rects[j]
            if not (tonumber(r and r[1]) and tonumber(r and r[2])
                and tonumber(r and r[3]) and tonumber(r and r[4])) then
                problem(out, "error", name, "rect " .. j .. " is not four numbers.")
            end
        end

        -- Profiles. Errors are the shapes that resolve wrongly; the rest are
        -- warnings because they still resolve to SOMETHING defensible, and the
        -- live store must stay saveable (the two-level rule above).
        local profs = rec.profiles or {}
        if #profs > LMEdit.MAX_PROFILES then
            problem(out, "error", name, "applies " .. #profs .. " profiles; the limit is "
                .. LMEdit.MAX_PROFILES .. ".")
        end
        local seenProf = {}
        for j = 1, #profs do
            local p = profs[j]
            if p == name then
                problem(out, "error", name, "applies itself as a profile.")
            elseif seenProf[p] then
                problem(out, "warning", name, "applies '" .. tostring(p)
                    .. "' more than once; only the first copy counts.")
            else
                seenProf[p] = true
                local prec = self.work[p]
                if not prec then
                    problem(out, "warning", name, "applies '" .. tostring(p)
                        .. "', which is not in the store - it contributes nothing.")
                else
                    -- Flat bags: only the profile's own fields ever merge. A
                    -- profile that carries structure of its own still works,
                    -- but the parts that look like they should do something
                    -- silently do not - say so.
                    if prec.rects and #prec.rects > 0 then
                        problem(out, "warning", name, "profile '" .. p
                            .. "' is a placed zone; only its own fields apply, its ground does not follow.")
                    end
                    if prec.inherits then
                        problem(out, "warning", name, "profile '" .. p
                            .. "' inherits '" .. prec.inherits
                            .. "', which is not followed - profiles contribute their own fields only.")
                    end
                    if prec.profiles and #prec.profiles > 0 then
                        problem(out, "warning", name, "profile '" .. p
                            .. "' applies profiles of its own, which are not followed.")
                    end
                    -- A zone that vanishes with the moon is probably a mistake:
                    -- disabled/priority through a PHASED profile is legal (both
                    -- are resolver-critical, so every machine agrees) but worth
                    -- a second look before the map starts breathing.
                    local pf = prec.fields or {}
                    if pf.phases and pf.phases ~= ""
                        and (pf.disabled ~= nil or pf.priority ~= nil) then
                        problem(out, "warning", name, "profile '" .. p
                            .. "' changes disabled/priority only during certain moon"
                            .. " phases - the zone's existence will follow the moon.")
                    end
                end
            end
        end

        -- Fields
        for k, v in pairs(rec.fields or {}) do
            local kwhy = LMEdit.keyProblem(k)
            if kwhy then
                problem(out, "error", name, kwhy)
            else
                local spec = Limes.fields and Limes.fields.spec and Limes.fields.spec(k)
                if not spec then
                    -- Not an error and not even really a defect: unregistered
                    -- keys are how a field from a milestone we have not built
                    -- yet survives a round trip through the editor intact.
                    problem(out, "warning", name, "field '" .. k
                        .. "' has no consumer installed - it is stored and passed through untouched.")
                elseif spec.type == "number" then
                    local n = tonumber(v)
                    if n == nil then
                        problem(out, "error", name, "field '" .. k .. "' = '" .. tostring(v)
                            .. "' is not a number; it would be dropped and the value inherited instead.")
                    elseif spec.min and n < spec.min then
                        problem(out, "warning", name, "field '" .. k .. "' = " .. tostring(n)
                            .. " is below the minimum and resolves as " .. tostring(spec.min) .. ".")
                    elseif spec.max and n > spec.max then
                        problem(out, "warning", name, "field '" .. k .. "' = " .. tostring(n)
                            .. " is above the maximum and resolves as " .. tostring(spec.max) .. ".")
                    end
                elseif spec.type == "boolean" then
                    local okv = (v == true or v == false or v == "true" or v == "false"
                             or v == 1 or v == 0 or v == "1" or v == "0")
                    if not okv then
                        problem(out, "error", name, "field '" .. k .. "' = '" .. tostring(v)
                            .. "' is not true or false; it would be dropped and the value inherited instead.")
                    end
                end
                -- phases has its own grammar on top of being a string. The
                -- parser skips junk tokens silently (resolution must not die
                -- on admin-typed data), so validate is where junk gets NAMED -
                -- and a value that is ALL junk parses to the empty set, which
                -- is never-active: a profile that looks configured and can
                -- never merge. "" means always; garbage does not.
                if k == "phases" and LMMoon and LMMoon.unknownTokens and v ~= "" then
                    local bad = LMMoon.unknownTokens(v)
                    if #bad > 0 then
                        local set = LMMoon.parsePhases(v)
                        local empty = true
                        if set then for _ in pairs(set) do empty = false break end end
                        if empty then
                            problem(out, "error", name, "phases = '" .. tostring(v)
                                .. "' names no real phase - this profile would NEVER be active."
                                .. " The vocabulary is new, waxing_crescent, first_quarter,"
                                .. " waxing_gibbous, full, waning_gibbous, last_quarter,"
                                .. " waning_crescent, waxing, waning, or 0-7.")
                        else
                            problem(out, "warning", name, "phases contains unknown token(s) '"
                                .. table.concat(bad, "', '") .. "' - they are ignored.")
                        end
                    end
                end
            end
        end
    end

    -- Zones orphaned by a deletion in this draft. Reported against the CHILD,
    -- because the child is the record that changes behaviour, and the admin who
    -- just deleted a template needs to see who was standing on it.
    for i = 1, #names do
        local rec = self.work[names[i]]
        if rec.inherits and not self.work[rec.inherits] and self.base[rec.inherits] then
            problem(out, "warning", names[i], "'" .. rec.inherits
                .. "' is being deleted in this edit; this zone loses its inherited fields.")
        end
        for j = 1, #(rec.profiles or {}) do
            local p = rec.profiles[j]
            if not self.work[p] and self.base[p] then
                problem(out, "warning", names[i], "profile '" .. p
                    .. "' is being deleted in this edit; this zone loses its fields.")
            end
        end
    end

    table.sort(out, function(a, b)
        if a.zone ~= b.zone then return a.zone < b.zone end
        return a.msg < b.msg
    end)
    return out
end

function LMEdit:errorCount()
    local n = 0
    for _, p in ipairs(self:validate()) do
        if p.level == "error" then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- The change set
-- ---------------------------------------------------------------------------

-- Returns changed (name -> pruned raw record), removed (sorted list of names),
-- and a count. THE DIFF IS THE POINT: sending the whole store back on every
-- save is the single line that made PhunZones the loudest mod on the wire
-- (Appendix A.3), and a store re-broadcast in full costs O(zones x players)
-- inside GlobalModData.transmit. An edit to one zone must cost one zone.
--
-- Comparison happens AFTER pruning on both sides, so clearing a field the
-- record never had, or re-typing the value it already carried, is correctly
-- nothing at all - the editor is allowed to be sloppy, the wire is not.
function LMEdit:changeSet()
    local changed, removed, n = {}, {}, 0

    for name, rec in pairs(self.work) do
        local now  = pruneRecord(rec)
        local was  = pruneRecord(self.base[name])
        if not sameRecord(now, was) then
            changed[name] = now
            n = n + 1
        end
    end

    for name in pairs(self.base) do
        if self.work[name] == nil then removed[#removed + 1] = name end
    end
    table.sort(removed)

    return changed, removed, n + #removed
end

function LMEdit:isDirty()
    local _, _, n = self:changeSet()
    return n > 0
end

-- The whole draft as a raw store, pruned - for callers that need the result
-- rather than the difference (a preview, a validating server that was handed a
-- full set, the .ini writer).
function LMEdit:snapshot()
    local out = {}
    for name, rec in pairs(self.work) do out[name] = pruneRecord(rec) end
    return out
end

-- Fold a change set into a raw store, pruning as it goes. The server applies an
-- incoming save with this, so client and server produce byte-identical stores
-- from the same command rather than each doing their own merge.
function LMEdit.applyChangeSet(rawZones, changed, removed)
    local out = {}
    for name, rec in pairs(rawZones or {}) do out[name] = copyRecord(rec) end
    for _, name in ipairs(removed or {}) do out[name] = nil end
    for name, rec in pairs(changed or {}) do out[name] = pruneRecord(rec) end
    return out
end

return LMEdit

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
