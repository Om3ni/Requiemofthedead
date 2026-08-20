-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMMemoirsTab.lua - the Memoirs tab on the player panel (client).
--
-- WHAT THIS IS (owner, 2026-08-13): two character sheets side by side. The
-- LEFT is you, now - the same numbers the Shift+P sheet shows. The RIGHT is
-- who you would be if you read your memoir THIS MOMENT. Memoirs are consumed
-- on read, so "read now or grind first?" is a real decision with a real
-- price; this tab lets a player see the answer instead of doing restore math
-- in their head.
--
-- THE RIGHT SHEET IS A PROJECTION, NOT A PREVIEW FROM THE SERVER. The
-- snapshot lives in the book's modData (synced to the owning client on every
-- write - MMServer.syncItemModData), and MMSnapshotCodec is a SHARED file, so
-- the exact apply math - the grant rule, the per-skill restore knob, the
-- overwrite-vs-legacy-top-up split - runs here against live data without
-- asking the server or mutating anything. If the codec's rule ever changes,
-- this projection changes with it, because it calls the same functions the
-- apply does (buildGrantLevels / playerBuildGrantLevels / xpRestoreFraction).
--
-- WHEN THE BOOK CANNOT BE READ, THE SHEET IS STILL DRAWN - as the character
-- SAVED INSIDE rather than a projection, with the banner saying why. The
-- projection formula counts this life's earnings on top of the book's, which
-- is only correct because a readable book was written by a DIFFERENT life
-- (the same-life gate guarantees the two earning windows are disjoint); for a
-- book this life wrote, or a life that already spent its one recall, the
-- honest display is "here is what is banked", not a number the server would
-- refuse to produce.
--
-- The banner mirrors every server-side read gate (epoch, same-life, one
-- recall per life, owner) so what this tab promises and what the server does
-- can never disagree. Owner-mismatched books are skipped entirely - someone
-- else's memoir is not your stats.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "MMSvShared"
require "MMSnapshotCodec"
require "DFKit"

MMMemoirsTab = MMMemoirsTab or {}
local T = MMMemoirsTab

local PAD = 8
local FIELD_LINES = 4    -- both cards ship exactly four header fields
local MIN_LIST_ROWS = 4  -- skill rows the cards may never eat into

-- Click rects for the "+N more" / "show less" trait tails, refreshed by
-- drawCard every frame and read by Sheet:onMouseDown. Kept across a file
-- reload with the expansion state so a hot-reload does not snap the card shut.
T.moreRects = T.moreRects or {}
T.traitsExpanded = T.traitsExpanded or false

local layout -- forward decl: populate() and the tail click both re-run it

local function fS() return DFKit.font.small or UIFont.Small end
local function fh() return getTextManager():getFontHeight(fS()) end

-- ---------------------------------------------------------------------------
-- Skill math. Levels are derived from raw XP totals via the perk's own level
-- table - the same mapping creation's setXPToLevel and the codec's AddXP
-- targets resolve through - so both sheets speak the same units.
-- ---------------------------------------------------------------------------
local function levelForXp(perk, total)
    local lvl = 0
    for l = 1, 10 do
        local need = perk:getTotalXpForLevel(l)
        if need and need >= 0 and total >= need then lvl = l else break end
    end
    return lvl
end

local function fmtNum(n)
    return tostring(math.floor((n or 0) + 0.5))
end

-- "into-level / needed" at a given raw total, "MAX" at the cap - the same
-- shape the Shift+P sheet uses, so the two surfaces read as one system.
local function xpStr(perk, total, lvl)
    local need = perk:getXpForLevel(lvl + 1)
    if need == -1 then return "MAX" end
    local into = total - (perk:getTotalXpForLevel(lvl) or 0)
    if into < 0 then into = 0 end
    return fmtNum(into) .. "/" .. fmtNum(need)
end

-- Display set: skills with a parent category, sorted by name - mirrors the
-- Shift+P sheet's collectSkills so the row lists always line up.
local function displayPerks()
    local out = {}
    for i = 0, Perks.getMaxIndex() - 1 do
        local pt = Perks.fromIndex(i)
        local perk = PerkFactory.getPerk(pt)
        if perk and perk:getParent() ~= Perks.None then
            out[#out + 1] = {
                t = pt, perk = perk, id = perk:getId(),
                name = perk:getName() .. " (" .. PerkFactory.getPerkName(perk:getParent()) .. ")",
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Trait names -> {label, tex} chips (icon lookups hardened like the Shift+P
-- sheet: a bad def must cost one icon, not the card).
local function traitChips(names)
    local out = {}
    for _, nm in ipairs(names or {}) do
        local label, tex = tostring(nm), nil
        local trait = MMShared.findTrait(nm) -- by registry id; legacy bare names resolve vanilla-first
        -- No guards. The whole trait-definition
        -- surface is total: getCharacterTraitDefinition is a lookup on a
        -- field-initialized LinkedHashMap that returns null for an unknown key
        -- (CharacterTraitDefinition.java:22, 68-70), and getLabel/getTexture are
        -- field returns (:136-138, :91-93). The nil check IS the whole error
        -- path - a trait with no definition keeps its registry-id fallback,
        -- which is the behaviour these guards were producing anyway.
        if trait then
            local def = CharacterTraitDefinition.getCharacterTraitDefinition(trait)
            if def then
                local l = def:getLabel()
                if l and l ~= "" then label = l end
                tex = def:getTexture()
            end
        end
        out[#out + 1] = { label = label, tex = tex }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- Registry ids, not getName(): the card compares this list against a snapshot's,
-- and two same-named traits from different namespaces must not read as one.
local function playerTraitNames(player)
    local out = {}
    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, (known and known:size() or 0) - 1 do
        -- labelOf, not requireId: these become chips on a read-only card, and a
        -- view must not be the thing that refuses. Anything unverified arrives
        -- "?"-prefixed so it cannot be mistaken for a real id.
        out[#out + 1] = MMShared.labelOf(known:get(i))
    end
    return out
end

local function agoStr(writtenAt)
    if not writtenAt or writtenAt == 0 then return "unknown" end
    local now = (getTimestamp and getTimestamp()) or 0
    local s = now - writtenAt
    if s < 0 then s = 0 end
    if s < 90 then return "moments ago" end
    if s < 5400 then return math.floor(s / 60 + 0.5) .. " minutes ago" end
    if s < 129600 then return math.floor(s / 3600 + 0.5) .. " hours ago" end
    return math.floor(s / 86400 + 0.5) .. " days ago"
end

-- ---------------------------------------------------------------------------
-- The book. Newest owned memoir wins when several are carried; blank books
-- and books bound to someone else never qualify.
-- ---------------------------------------------------------------------------
local function findBook(player)
    local carried, owned = 0, {}
    -- No guard. getInventory is a bare field read (IsoGameCharacter.java
    -- :2953-2955, initialized at :557), and getAllTypeRecurse's only throw is
    -- Objects.requireNonNull on a NULL type argument (ItemContainer.java:3596)
    -- - "Memoir" is a literal. An unknown type just never matches (:1132-1137),
    -- so the result is a freshly allocated ArrayList, never null
    -- (:1866-1868 into :1713-1718); empty is the ordinary no-book answer.
    local list = player:getInventory():getAllTypeRecurse("Memoir")
    carried = list:size()
    local uname = player:getUsername()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local snap = item:getModData()["MM"]
        if type(snap) == "table" and snap.perks then
            local owner = snap.owner
            if not (owner and owner.username and uname and owner.username ~= uname) then
                owned[#owned + 1] = { item = item, snap = snap }
            end
        end
    end
    table.sort(owned, function(a, b)
        return (a.snap.writtenAt or 0) > (b.snap.writtenAt or 0)
    end)
    return owned[1], carried, #owned
end

-- Mirrors MMServer's read gates in order. Returns:
--   mode     "project" (right sheet = you after reading) | "contents" (right
--            sheet = the character saved inside)
--   xpMode   "overwrite" | "max" (project only)
--   text     banner line
--   sev      DFKit colour key for the banner line
local function classify(player, snap)
    local md = player:getModData()
    if (snap.epoch or 0) < MMShared.WIPE_EPOCH then
        return "contents", nil,
            "The ink has faded (pre-wipe book) - write over it for a fresh snapshot. Showing what it holds.",
            "danger"
    end
    if snap.lifeId and md and md.MMLifeId == snap.lifeId then
        return "contents", nil,
            "Written by this life - only a future you can read it. Showing the character saved inside.",
            "warn"
    end
    if md and md.MMRecalled then
        return "contents", nil,
            "This life already recalled a memoir - a second read refuses. Showing the character saved inside.",
            "warn"
    end
    if not snap.lifeId then
        -- Legacy pre-v4 book: the server picks by identity compare - a match
        -- could be the same life, so it only ever tops up.
        local matches = MMSnapshotCodec.identityMatches(player, snap)
        if matches then
            return "project", "max",
                "Readable now (legacy book): a top-up - nothing you have is ever lowered.",
                "ok"
        end
    end
    return "project", "overwrite",
        "Readable now. The right sheet is who you become the moment you read it.",
        "ok"
end

-- ---------------------------------------------------------------------------
-- Projection - THE GRANT RULE, run for display (see MMSnapshotCodec header).
-- targetXp is what applyEarnables would drive each skill's raw total to.
-- ---------------------------------------------------------------------------
local function skillRows(player, snap, mode, xpMode)
    local xp = player:getXp()
    local rows = {}
    local savedGrant, preGrant
    if snap and mode == "project" then
        savedGrant = MMSnapshotCodec.buildGrantLevels(snap.profession, snap.traits)
        preGrant   = MMSnapshotCodec.playerBuildGrantLevels(player)
    end

    for _, d in ipairs(displayPerks()) do
        local cur  = xp:getXP(d.t) or 0
        local lLvl = player:getPerkLevel(d.t) or 0
        local row = { name = d.name, L = { lvl = lLvl, xp = xpStr(d.perk, cur, lLvl) } }

        if snap then
            local target
            if mode == "project" then
                local pct = MMShared.xpRestoreFraction(d.id)
                local rawSaved = (snap.perks and snap.perks[d.id]) or 0
                local savedGrantXP = d.perk:getTotalXpForLevel(savedGrant[d.id] or 0) or 0
                -- Floor clamped to the book's own XP, mirroring applyEarnables: an
                -- evolved trait's phantom spawn floor must not project free levels.
                if savedGrantXP > rawSaved then savedGrantXP = rawSaved end
                local savedEarned = rawSaved - savedGrantXP
                if xpMode == "overwrite" then
                    local preGrantXP = d.perk:getTotalXpForLevel(preGrant[d.id] or 0) or 0
                    local newEarned = cur - preGrantXP
                    if newEarned < 0 then newEarned = 0 end
                    target = savedGrantXP + savedEarned * pct + newEarned
                else -- legacy top-up: never below current
                    target = savedGrantXP + savedEarned * pct
                    if cur > target then target = cur end
                end
            else -- contents: the book's raw totals, untaxed
                target = (snap.perks and snap.perks[d.id]) or 0
            end
            local rLvl = levelForXp(d.perk, target)
            row.R = {
                lvl  = rLvl,
                xp   = xpStr(d.perk, target, rLvl),
                dLvl = rLvl - lLvl,
                dXp  = target - cur,
            }
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Populate: collect both sheets. Called at build and by Refresh - cheap
-- enough that "the numbers are live when I look" beats caching.
-- ---------------------------------------------------------------------------
function T.populate()
    local player = getPlayer()
    if not player or player:isDead() then return end

    local book, carried, ownedCount = findBook(player)
    local snap = book and book.snap or nil

    -- LEFT: you, now.
    local nut = player:getNutrition()
    T.left = {
        title  = "YOU, NOW",
        fields = {
            { k = "Profession", v = MMShared.professionUIName((function()
                local p = player:getDescriptor() and player:getDescriptor():getCharacterProfession()
                return p and MMShared.labelOf(p) or nil -- id, so a shadowed path resolves right
            end)()) },
            { k = "Weight",   v = nut and fmtNum(nut:getWeight()) or "?" },
            { k = "Kills",    v = fmtNum(player:getZombieKills()) },
            { k = "Survived", v = math.floor(player:getHoursSurvived() or 0) .. " hours" },
        },
        traits = traitChips(playerTraitNames(player)),
    }

    -- BANNER + RIGHT: the book, or the reason there is none.
    local mode, xpMode
    if not snap then
        T.right = nil
        T.mode  = nil
        if carried > 0 then
            T.bookLine  = "Memoir carried, but blank."
            T.statusTxt = "Write in it (pen or pencil) to bank this character."
        else
            T.bookLine  = "No memoir in your inventory."
            T.statusTxt = "Craft one and write in it to bank this character against death."
        end
        T.statusSev = "textDim"
    else
        -- classify compares identities, so it runs the STRICT resolver and can
        -- raise on a character whose registry went stale. A read-only tab must
        -- not be the thing that refuses: fall back to showing what the book
        -- holds, and say why in the banner the tab already owns.
        local sev, txt
        local okC, m, xm, tx, sv = pcall(classify, player, snap)
        if okC then
            mode, xpMode, txt, sev = m, xm, tx, sv
        else
            mode, xpMode = "contents", nil
            txt = "Your character's traits cannot be verified against the registry"
                .. " (scripts reloaded under a live character?) - showing the memoir's contents."
            sev = "danger"
        end
        T.mode = mode
        local name = book.item:getName() or "Memoir"
        T.bookLine = name .. "  -  written " .. agoStr(snap.writtenAt)
            .. (ownedCount > 1 and ("  (newest of " .. ownedCount .. " carried)") or "")
        T.statusTxt = txt
        T.statusSev = sev

        -- Identity/kills on the right follow the same apply the codec runs:
        -- overwrite = the book's identity + kills stack; legacy top-up keeps
        -- identity and never lowers kills; contents = the book verbatim.
        local prof, traits, kills
        if mode == "project" and xpMode == "max" then
            prof   = T.left.fields[1].v
            traits = T.left.traits
            kills  = math.max(snap.kills and snap.kills.Zombie or 0, player:getZombieKills() or 0)
        else
            prof   = MMShared.professionUIName(snap.profession)
            traits = traitChips(snap.traits)
            kills  = (snap.kills and snap.kills.Zombie or 0)
                + ((mode == "project") and (player:getZombieKills() or 0) or 0)
        end
        local weight = snap.nutrition and fmtNum(snap.nutrition.weight)
            or (nut and fmtNum(nut:getWeight())) or "?"
        T.right = {
            title  = (mode == "project") and "AFTER READING" or "SAVED IN THE MEMOIR",
            fields = {
                { k = "Profession", v = prof },
                { k = "Weight",     v = weight },
                { k = "Kills",      v = fmtNum(kills) },
                { k = "Written",    v = agoStr(snap.writtenAt) },
            },
            traits = traits,
        }
    end

    T.rows = skillRows(player, snap, mode or "project", xpMode)
    -- An expanded card is sized to the trait set it was showing; Refresh (or
    -- a first populate after build) can change that set, so re-measure.
    if T.traitsExpanded and T.sheet then layout(T.sheet:getWidth(), T.sheet:getHeight()) end
    if T.list then
        DFKit.refillList(T.list, function(box)
            for _, row in ipairs(T.rows) do box:addItem(row.name, row) end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Columns. Both sheets' numbers cluster against the centre divider so the
-- eye jumps one gutter, not half a panel: name | lvl xp || lvl xp | delta.
-- ---------------------------------------------------------------------------
local function cols(w)
    local div = math.floor(w / 2)
    return {
        div  = div,
        name = 8,
        lLvl = div - 160,
        lXp  = div - 110,
        rLvl = div + 14,
        rXp  = div + 64,
        dta  = w - 78,
    }
end

local function deltaCol(dXp)
    local C = DFKit.col
    if dXp > 0.5 then return C.ok end
    if dXp < -0.5 then return C.danger end
    return C.textDim
end

-- ---------------------------------------------------------------------------
-- The sheet panel: banner, two cards, column headers, centre divider. The
-- skill list is a child listbox; rows draw their own divider segment.
-- ---------------------------------------------------------------------------
local Sheet = ISPanel:derive("MMMemoirsSheet")

-- Wrap trait chips into rows for a card of usable width `availW`. PURE
-- MEASUREMENT, no drawing: the height math (layout) and the paint (drawCard)
-- both run it, so what a card reserves and what it puts on screen can never
-- disagree. Each entry carries its x offset inside the row and its index in
-- the original list - the tail needs that index to count what it is hiding.
local function wrapTraits(traits, availW)
    local f, lh = fS(), fh()
    local rows, cur, cx = {}, {}, 0
    for i, t in ipairs(traits or {}) do
        local tw = getTextManager():MeasureStringX(f, t.label) + (t.tex and (lh + 4) or 0) + 14
        if cx > 0 and cx + tw > availW then
            rows[#rows + 1] = cur
            cur, cx = {}, 0
        end
        cur[#cur + 1] = { chip = t, x = cx, w = tw, i = i }
        cx = cx + tw
    end
    if #cur > 0 then rows[#rows + 1] = cur end
    return rows
end

-- Card height <-> trait row count, one formula read both ways: title line,
-- field lines, the pre-trait gap and the top/bottom padding are the chrome;
-- everything else is trait rows.
local function cardChromeH()
    local lh = fh()
    return 10 + (lh + 4) + FIELD_LINES * (lh + 3)
end
local function cardHeightFor(rows) return cardChromeH() + rows * (fh() + 4) end
local function rowsForCardHeight(hh)
    return math.floor((hh - cardChromeH()) / (fh() + 4))
end

local function drawCard(el, x, y, w, h, card, emptyText, side)
    local C = DFKit.col
    el:drawRect(x, y, w, h, DFKit.alpha.inset, C.bg.r, C.bg.g, C.bg.b)
    el:drawRectBorder(x, y, w, h, 0.45, C.line.r, C.line.g, C.line.b)
    local f, lh = fS(), fh()
    if not card then
        T.moreRects[side] = nil
        DFKit.drawEmpty(el, x, y, w, h, emptyText or "-")
        return
    end
    local tx, ty = x + PAD, y + 4
    el:drawText(card.title, tx, ty, C.accent.r, C.accent.g, C.accent.b, 1, f)
    ty = ty + lh + 4
    for _, fld in ipairs(card.fields) do
        el:drawText(fld.k .. ":", tx, ty, 0.85, 0.7, 0.4, 1, f)
        el:drawText(tostring(fld.v), tx + 88, ty, C.text.r, C.text.g, C.text.b, 1, f)
        ty = ty + lh + 3
    end
    -- traits: icon chips wrapped into T.traitRows rows, then a tail. The tail
    -- is a CLICK TARGET, not decoration (Sheet:onMouseDown): "+N more" grows
    -- both cards to fit the whole build and pushes the skill list down,
    -- "show less" puts it back. Collapsed is two rows, so the common build
    -- still reads at a glance without the list losing half its height.
    ty = ty + 2
    local availW = w - PAD * 2
    local rows = wrapTraits(card.traits, availW)
    local maxRows = T.traitRows or 2
    local tail, tailInline = nil, false
    if #rows > maxRows then
        while #rows > maxRows do table.remove(rows) end
        -- Shave chips off the last visible row until the label fits beside
        -- them - the count in the label changes as chips leave, so this loops.
        local last = rows[#rows]
        while true do
            tail = "+" .. (#card.traits - last[#last].i) .. " more"
            local need = last[#last].x + last[#last].w + getTextManager():MeasureStringX(f, tail)
            if need <= availW or #last == 1 then break end
            table.remove(last)
        end
        -- Already expanded and STILL clipped: the panel is too short to hold
        -- the build. Say so, and keep the click honest about what it does.
        if T.traitsExpanded then tail = tail .. " (show less)" end
        tailInline = true
    elseif T.traitsExpanded and #card.traits > 0 then
        tail = "show less" -- own row - layout() reserved it
    end

    for r = 1, #rows do
        for _, e in ipairs(rows[r]) do
            local cx = tx + e.x
            if e.chip.tex then
                el:drawTextureScaled(e.chip.tex, cx, ty - 1, lh + 2, lh + 2, 1, 1, 1, 1)
                cx = cx + lh + 4
            end
            el:drawText(e.chip.label, cx, ty, 0.9, 0.9, 0.9, 1, f)
        end
        if r < #rows or not tailInline then ty = ty + lh + 4 end
    end

    if tail then
        local last = tailInline and rows[#rows] and rows[#rows][#rows[#rows]] or nil
        local tailX = tx + (last and (last.x + last.w) or 0)
        local tw = getTextManager():MeasureStringX(f, tail)
        local hot = el:isMouseOver()
            and el:getMouseX() >= tailX - 3 and el:getMouseX() < tailX + tw + 3
            and el:getMouseY() >= ty - 2 and el:getMouseY() < ty + lh + 2
        local tc = hot and C.accent or C.textDim
        el:drawText(tail, tailX, ty, tc.r, tc.g, tc.b, 1, f)
        T.moreRects[side] = { x = tailX, y = ty, w = tw, h = lh }
    else
        T.moreRects[side] = nil
    end
end

-- The tail is drawn text with a remembered rect, not a widget. Returning
-- false for everything else matters: UIElement.onMouseDown treats a false
-- return as "not consumed" and walks on to the deck, which is what keeps the
-- panel's own drag/resize/tab clicks alive underneath this sheet.
function Sheet:onMouseDown(x, y)
    for _, r in pairs(T.moreRects) do
        if x >= r.x - 3 and x < r.x + r.w + 3 and y >= r.y - 2 and y < r.y + r.h + 2 then
            T.traitsExpanded = not T.traitsExpanded
            layout(self.width, self.height)
            return true
        end
    end
    return false
end

function Sheet:prerender()
    ISPanel.prerender(self)
    local C = DFKit.col
    local f, lh = fS(), fh()
    local w = self.width
    local halfW = math.floor((w - PAD * 3) / 2)

    -- banner
    self:drawText(T.bookLine or "", PAD, 4, C.text.r, C.text.g, C.text.b, 1, f)
    local sc = C[T.statusSev or "textDim"] or C.textDim
    self:drawText(T.statusTxt or "", PAD, 4 + lh + 3, sc.r, sc.g, sc.b, 1, f)
    self:drawRect(0, T.bannerH - 1, w, 1, 0.45, C.line.r, C.line.g, C.line.b)

    -- cards
    local cy = T.bannerH + PAD
    drawCard(self, PAD, cy, halfW, T.cardH, T.left, nil, "left")
    drawCard(self, PAD * 2 + halfW, cy, halfW, T.cardH, T.right,
        (T.bookLine and T.bookLine:find("blank")) and "The pages are empty."
        or "No memoir to compare against.", "right")

    -- column headers + centre divider down through the list
    local c = cols(w)
    local hy = cy + T.cardH + 4
    self:drawText("Skill", c.name, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Lvl", c.lLvl, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("XP", c.lXp, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Lvl", c.rLvl, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("XP", c.rXp, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawText("Change", c.dta, hy, 0.7, 0.7, 0.7, 1, f)
    self:drawRect(c.div, cy, 1, self.height - cy - PAD, 0.45, C.line.r, C.line.g, C.line.b)
end

local function drawSkillRow(self, y, item, alt)
    local row = item.item
    local h = self.itemheight
    local C = DFKit.col
    local c = cols(self:getWidth())
    if alt then self:drawRect(0, y, self:getWidth(), h, 0.06, 1, 1, 1) end
    self:drawRect(c.div, y, 1, h, 0.45, C.line.r, C.line.g, C.line.b)

    self:drawText(DFKit.fitText(row.name, self.font, c.lLvl - c.name - 10),
        c.name, y + 3, 0.9, 0.9, 0.9, 1, self.font)
    self:drawText(tostring(row.L.lvl), c.lLvl, y + 3, C.text.r, C.text.g, C.text.b, 1, self.font)
    self:drawText(row.L.xp, c.lXp, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 1, self.font)

    if row.R then
        local rc = deltaCol(row.R.dXp)
        self:drawText(tostring(row.R.lvl), c.rLvl, y + 3, rc.r, rc.g, rc.b, 1, self.font)
        self:drawText(row.R.xp, c.rXp, y + 3, rc.r, rc.g, rc.b, 0.85, self.font)
        local d
        if row.R.dLvl ~= 0 then
            d = string.format("%+d lvl", row.R.dLvl)
        elseif row.R.dXp > 0.5 or row.R.dXp < -0.5 then
            d = string.format("%+d xp", math.floor(row.R.dXp + (row.R.dXp >= 0 and 0.5 or -0.5)))
        end
        if d then self:drawText(d, c.dta, y + 3, rc.r, rc.g, rc.b, 1, self.font) end
    else
        self:drawText("-", c.rLvl, y + 3, C.textDim.r, C.textDim.g, C.textDim.b, 0.6, self.font)
    end
    return y + h
end

-- ---------------------------------------------------------------------------
-- Build / resize
-- ---------------------------------------------------------------------------
function layout(w, h)
    local lh = fh()
    T.bannerH = lh * 2 + 12

    -- Card height follows the trait tail's state: two rows collapsed; when
    -- expanded, as many rows as the fuller of the two cards needs, plus the
    -- "show less" row. Clamped so the skill list keeps MIN_LIST_ROWS - a
    -- 20-trait build on a short panel stays clipped (with the tail still
    -- saying "+N more") rather than swallowing the thing you came to read.
    local halfW = math.floor((w - PAD * 3) / 2)
    local rows = 2
    if T.traitsExpanded then
        for _, card in ipairs({ T.left, T.right }) do
            if card then rows = math.max(rows, #wrapTraits(card.traits, halfW - PAD * 2)) end
        end
        rows = rows + 1
    end
    T.cardH = cardHeightFor(rows)
    local chrome  = T.bannerH + PAD + 4 + lh + 4 + PAD
    local maxCard = h - chrome - (fh() + 6) * MIN_LIST_ROWS
    if T.cardH > maxCard then T.cardH = math.max(cardHeightFor(2), maxCard) end
    T.traitRows = math.max(2, rowsForCardHeight(T.cardH))

    T.sheet:setWidth(w); T.sheet:setHeight(h)
    local listY = T.bannerH + PAD + T.cardH + 4 + lh + 4
    DFKit.sizeList(T.list, 0, listY, w, h - listY - PAD)
    if T.btnRefresh then
        T.btnRefresh:setX(w - T.btnRefresh:getWidth() - PAD)
        T.btnRefresh:setY(4)
    end
end

function T.build(spec, panel, x, y, w, h)
    T.host = panel

    T.sheet = Sheet:new(0, 0, w, h)
    T.sheet.background = false
    T.sheet:initialise()
    T.sheet:instantiate()
    panel:addChild(T.sheet)

    T.list = ISScrollingListBox:new(0, 0, w, h)
    T.list:initialise()
    T.list.font = fS()
    T.list.itemheight = fh() + 6
    T.list.drawBorder = false
    -- The vanilla listbox always paints backgroundColor (its `background`
    -- flag is dead); a=0 is the only real "transparent" - the sheet's own
    -- ground and centre divider must show through.
    T.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    T.list.doDrawItem = drawSkillRow
    T.sheet:addChild(T.list)

    T.btnRefresh = DFKit.button(T.sheet, 0, 4, 80, "Refresh", T, function() T.populate() end)

    layout(w, h)
    T.populate()
end

function T.resize(spec, panel, w, h)
    if panel ~= T.host or not T.sheet then return end
    layout(w, h)
end

-- ---------------------------------------------------------------------------
-- Registration: after the Reclamation pair. Degrades to nothing without
-- Dragonfly, like every family tenant.
-- ---------------------------------------------------------------------------
Events.OnGameBoot.Add(function()
    if not (Dragonfly and Dragonfly.registerPlayerTab) then return end
    Dragonfly.registerPlayerTab{
        id     = "mm_memoirs",
        label  = "Memoirs",
        order  = 40,
        build  = T.build,
        resize = T.resize,
        -- Two full character sheets abreast: width is the scarce dimension.
        prefW  = 1150,
        prefH  = 700,
    }
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
