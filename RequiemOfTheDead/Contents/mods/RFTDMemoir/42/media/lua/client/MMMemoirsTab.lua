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
        if trait then
            local ok, def = pcall(CharacterTraitDefinition.getCharacterTraitDefinition, trait)
            if ok and def then
                local okl, l = pcall(function() return def:getLabel() end)
                if okl and l and l ~= "" then label = l end
                local okt, tx = pcall(function() return def:getTexture() end)
                if okt then tex = tx end
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
        local t = known:get(i)
        out[#out + 1] = MMShared.fqid(t) or t:getName()
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
    local ok, list = pcall(function() return player:getInventory():getAllTypeRecurse("Memoir") end)
    if ok and list then
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
    end
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
                local savedGrantXP = d.perk:getTotalXpForLevel(savedGrant[d.id] or 0) or 0
                local savedEarned = ((snap.perks and snap.perks[d.id]) or 0) - savedGrantXP
                if savedEarned < 0 then savedEarned = 0 end
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
                return p and (MMShared.fqid(p) or p:getName()) or nil -- id, so a shadowed path resolves right
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
        local sev, txt
        mode, xpMode, txt, sev = classify(player, snap)
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

local function drawCard(el, x, y, w, h, card, emptyText)
    local C = DFKit.col
    el:drawRect(x, y, w, h, DFKit.alpha.inset, C.bg.r, C.bg.g, C.bg.b)
    el:drawRectBorder(x, y, w, h, 0.45, C.line.r, C.line.g, C.line.b)
    local f, lh = fS(), fh()
    if not card then
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
    -- traits: icon chips wrapped over two rows, then a "+N more" tail - the
    -- card is fixed-height so a 12-trait build must summarise, not overflow.
    ty = ty + 2
    local cx, rowsUsed, shown = tx, 1, 0
    for i, t in ipairs(card.traits) do
        local tw = getTextManager():MeasureStringX(f, t.label) + (t.tex and (lh + 4) or 0) + 14
        if cx + tw > x + w - PAD - 52 then
            if rowsUsed >= 2 then
                el:drawText("+" .. (#card.traits - shown) .. " more", cx, ty,
                    C.textDim.r, C.textDim.g, C.textDim.b, 1, f)
                break
            end
            rowsUsed = rowsUsed + 1
            cx, ty = tx, ty + lh + 4
        end
        if t.tex then
            el:drawTextureScaled(t.tex, cx, ty - 1, lh + 2, lh + 2, 1, 1, 1, 1)
            cx = cx + lh + 4
        end
        el:drawText(t.label, cx, ty, 0.9, 0.9, 0.9, 1, f)
        cx = cx + getTextManager():MeasureStringX(f, t.label) + 14
        shown = i
    end
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
    drawCard(self, PAD, cy, halfW, T.cardH, T.left)
    drawCard(self, PAD * 2 + halfW, cy, halfW, T.cardH, T.right,
        (T.bookLine and T.bookLine:find("blank")) and "The pages are empty."
        or "No memoir to compare against.")

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
local function layout(w, h)
    local lh = fh()
    T.bannerH = lh * 2 + 12
    T.cardH   = lh * 7 + 26
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
