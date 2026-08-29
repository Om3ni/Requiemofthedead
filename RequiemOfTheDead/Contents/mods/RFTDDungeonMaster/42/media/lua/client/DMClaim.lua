-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMClaim - the player's Kits tab, on the Dragonfly PLAYER panel (client only).
--
-- Deliberately small, and the smallness is the design. This is a SELECTION from
-- a catalogue the server sent, never a submission into one: the only thing that
-- ever leaves here is a kit id. What that kit contains, whether this player may
-- have it, whether they have had it already, and what a roulette rolled are all
-- decided server-side, every time (DMKits_Server).
--
-- ---------------------------------------------------------------------------
-- IT LISTS ONLY WHAT IS CLAIMABLE. kitMine returns the kits this player is
-- entitled to and nothing else - no requirement text, no locked rows greyed
-- out with "needs the Delver flag". That is not tidiness: a list of everything
-- with the gates written next to it is a readout of every piece of authored
-- content on the server and exactly what it takes to reach it, handed to
-- everyone. A player learns they were part of something from what a kit gives
-- them (RDVars' header says the same thing about vars).
--
-- ---------------------------------------------------------------------------
-- THE REPLY ENVELOPE IS SHARED WITH THE AUTHORING TAB. One client can be both.
-- Every KitResult names the command it answers, so this window renders only
-- kitClaim's - otherwise an admin who deletes a kit would watch the deletion
-- notice appear in their own claim window as though something had been handed
-- to them.
--
-- ---------------------------------------------------------------------------
-- A CLAIM IS NOT ANSWERED TWICE. The button disables itself on send and the
-- reply re-enables it. RDNet rate-limits kitClaim to one per second and does
-- NOT answer a refused flood - replying to one re-amplifies it - so a tab
-- that let a player click four times would show them three claims that
-- silently never happened.
--
-- ---------------------------------------------------------------------------
-- IT LIVES ON THE PLAYER DECK, NOT THE VANILLA CLIENT PANEL (owner, 2026-08-23;
-- it shipped on the vanilla panel first). The family rule that surface follows
-- is player-facing things live IN the game where players already are, and the
-- player deck IS that surface - DFPlayerDeck's own header states it. A button
-- bolted onto vanilla's panel put kits in the one place the suite had already
-- decided player features do not go, beside the settings a player opens once.
--
-- THIS IS NOT A DRAGONFLY DEPENDENCY. registerPlayerTab lives in CORE
-- (DFPlayerRegistry.lua) and the registration is nil-guarded exactly as
-- Memoir, Reclamation and the Workshop tab guard theirs: no Dragonfly, no tab,
-- no error. Kits degrade rather than break, which is the direction sect. 12
-- requires.
--
-- BUILD IS SHOW. DFPlayerDeck throws away its content area and recreates it on
-- every tab selection (DFPlayerDeck.lua:256-263, the same contract DFDeck
-- honours), so build() re-runs each time the tab is opened and is therefore
-- where the re-read belongs. There is no onShow hook and none is needed.
--
-- MP ONLY. Registered behind isClient(): a kit catalogue is authored by an
-- admin on a server, and in singleplayer the tab could only ever sit on
-- "Checking..." forever. An absent tab is honest; an empty one is a bug report.

if isServer() then return end

require "DFKit"
require "DMKitDefs"
require "DMIcons"
require "ISUI/ISScrollingListBox"

DMClaim = DMClaim or {}
local C = DMClaim

local TOKEN  = "RFTDDungeonMaster"
local TAB_ID = "dm_kits"
local FONT   = DFKit.font.small

-- Tab state, not window state: the deck owns the panel and hands us a fresh one
-- per selection, so what survives between builds is the data and the selection,
-- never a widget.
C.panel   = nil
C.listBox = nil
C.status  = nil
C.busy    = false
C.kits = nil    -- nil until the server answers; {} means "none", which differs

-- ---------------------------------------------------------------------------
-- Pure
-- ---------------------------------------------------------------------------

-- Display order lives in DMKitDefs.displayOrder (promoted 2026-08-25).

-- The row's right-hand column. A repeatable kit says how many times this player
-- has taken it, because that is the only number they can act on; a one-time kit
-- says nothing, since being in this list at all means they have not had it.
function DMClaim.tagFor(k)
    if not k then return "" end
    -- A COOLING KIT SAYS SO FIRST. It is on the list precisely because the
    -- player has earned it and is waiting, and the wait is the only thing they
    -- can act on - how many times they have taken it is trivia by comparison.
    local wait = DMClaim.waitText(k.readyInMs)
    if wait ~= "" then return "in " .. wait end
    -- Ready. How many times they have taken it is the only thing left worth
    -- saying, and only once it is more than none.
    local taken = tonumber(k.taken) or 0
    if taken > 0 then return "taken " .. taken .. "x" end
    return tostring(k.claimText or "")
end

-- Is this row claimable right now? The server decides for real; this only
-- decides whether the button should look like it will work.
function DMClaim.isReady(k)
    return type(k) == "table" and (tonumber(k.readyInMs) or 0) <= 0
end

-- A duration in milliseconds -> the coarsest sentence that is still true.
-- Coarse ON PURPOSE: a countdown ticking down to the second invites a player
-- to sit on the panel watching it, and the number is only ever used to answer
-- "not yet, come back later".
function DMClaim.waitText(ms)
    local n = tonumber(ms)
    if not n or n <= 0 then return "" end
    local mins = math.ceil(n / 60000)
    if mins < 60 then
        return mins .. " min"
    end
    local hours = math.ceil(mins / 60)
    if hours < 48 then
        return hours .. " hr"
    end
    return math.ceil(hours / 24) .. " days"
end

-- Three states, three sentences. "Nothing yet" and "nothing at all" are
-- different facts, and a player told the second when the first is true walks
-- away from a reward they have earned.
function DMClaim.emptyLine(kits)
    if kits == nil then return "Checking..." end
    return "Nothing to claim right now."
end

-- The right-hand pane, as a flat list of drawable lines. Flattened HERE rather
-- than in the drawing so the nesting - a roulette holding branches holding
-- rows - is worked out once, in a function a fixture can read, instead of by a
-- loop counting indents at sixty frames a second.
--
-- Each line is { text, icon (a contents row or nil), indent, dim }.
-- `icon` carries the row rather than a texture because resolving one is a
-- registry lookup and the draw is where that belongs.
--
-- THERE IS NO ODDS FIELD, and its absence is enforced rather than assumed.
-- kitMine is built with DMKitDefs.contents(def, false), so a weight should
-- never arrive here at all - but "should never arrive" is the shape of every
-- disclosure leak, and this is the last gate before a number reaches a screen.
-- So the projection simply has nowhere to put one: a branch's percent is read
-- by nothing below, and a payload carrying one renders identically to a
-- payload that does not. The admin surface gets its odds from the raw
-- definition instead (DMKitsTab.summaryOf), which players never receive.
function DMClaim.linesFor(kit)
    local out = {}
    local contents = kit and kit.contents
    if not contents or #contents == 0 then
        -- A kit whose every grant is bookkeeping is a real thing to author -
        -- it moves a counter and says nothing - and the player still has to be
        -- told what taking it does, which is nothing they can see.
        out[#out + 1] = { text = "Nothing you can carry.", dim = true }
        return out
    end
    for _, row in ipairs(contents) do
        if row.kind == DMKitDefs.ROULETTE then
            out[#out + 1] = { text = DMIcons.rouletteHeading(row), dim = true }
            for _, b in ipairs(row.branches or {}) do
                if #(b.rows or {}) == 0 then
                    -- A branch of pure bookkeeping is still an OUTCOME. Saying
                    -- so keeps the list honest about how many ways this can go.
                    out[#out + 1] = { text = "something unseen", indent = 1,
                                      dim = true }
                else
                    for _, r in ipairs(b.rows) do
                        out[#out + 1] = {
                            text = DMIcons.label(r), icon = r, indent = 1,
                        }
                    end
                end
            end
        else
            out[#out + 1] = { text = DMIcons.label(row), icon = row }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

function DMClaim.refresh()
    RDNet.send(TOKEN, "kitMine", {})
end

-- Its OWN listener, not a forward from the authoring tab. The two surfaces want
-- different commands and neither consumes the other's, so there is no race to
-- arbitrate - and a player-facing window that depended on a staff tab being
-- loaded would be the wrong dependency in the wrong direction.
function DMClaim.receive(command, args)
    if command == "KitMine" then
        C.kits = (args and args.kits) or {}
        DMClaim.rebuild()
        return true

    elseif command == "KitResult" then
        -- Only a claim's answer. See the header: an admin is also a player.
        if not (args and args.command == "kitClaim") then return false end
        -- The reply is absorbed whether or not the tab is on screen: a player
        -- who claims and immediately switches tabs must not come back to a
        -- Claim button still disabled from a send that has already answered.
        C.busy   = false
        C.status = args.ok and tostring(args.message) or tostring(args.reason)
        -- Re-read either way. On success the kit may be gone from the list (a
        -- one-time kit just spent) or its count moved; on a refusal the list
        -- this window is showing is the thing that turned out to be wrong.
        DMClaim.refresh()
        return true
    end
    return false
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TOKEN then return end
    DMClaim.receive(command, args)
end)

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

local KitList = ISScrollingListBox:derive("DMClaimList")

function KitList:doDrawItem(y, item, alt)
    local k = item.item
    if not k then return y + item.height end
    if self.selected == item.index then
        local a = DFKit.col.accentDim
        self:drawRect(0, y, self.width, item.height - 1, 0.55, a.r, a.g, a.b)
    elseif alt then
        self:drawRect(0, y, self.width, item.height - 1, 0.10, 1, 1, 1)
    end
    self:drawRectBorder(0, y, self.width, item.height, 0.12, 1, 1, 1)

    local c = DFKit.col.text
    local tag = DMClaim.tagFor(k)
    local tw  = getTextManager():MeasureStringX(FONT, tag)
    self:drawText(DFKit.fitText(k.label or k.id, FONT, self.width - tw - 18),
                  6, y + 3, c.r, c.g, c.b, 1, FONT)
    local d = DFKit.col.textDim
    self:drawText(tag, self.width - tw - 6, y + 3, d.r, d.g, d.b, 1, FONT)
    return y + item.height
end

function KitList:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if idx < 1 or idx > #self.items then return end
    self.selected = idx
    local k = self.items[idx].item
    C.selected = k and k.id or nil
    C.shown    = k
    C.status   = nil
end

function DMClaim.rebuild()
    if not C.listBox then return end
    DFKit.refillList(C.listBox, function(box)
        for _, k in ipairs(DMKitDefs.displayOrder(C.kits)) do
            box:addItem(k.label or k.id, k).height = DFKit.rowHeight()
        end
    end)
    -- Put the highlight back where the ID says it is. Every claim triggers a
    -- re-read and refillList calls clear(), which sets selected = 1 - so a
    -- window reading its target off the widget would offer the Claim button
    -- for whatever landed first after the list changed under it.
    local box = C.listBox
    box.selected = -1
    if C.selected then
        for i, item in ipairs(box.items) do
            if item.item and item.item.id == C.selected then
                box.selected = i
                break
            end
        end
        if box.selected == -1 then C.selected = nil end
    end
    -- The shown kit is re-derived from the id for the same reason the highlight
    -- is: the list is replaced wholesale on every answer, and a held reference
    -- would go on describing a kit that is no longer in it.
    C.shown = nil
    for _, k in ipairs(C.kits or {}) do
        if k.id == C.selected then C.shown = k; break end
    end
end

-- ---------------------------------------------------------------------------
-- The tab
-- ---------------------------------------------------------------------------

function DMClaim.claim()
    if C.busy then
        -- Not a cosmetic guard. kitClaim is rated at one per second and a
        -- refused flood is NOT answered, so a second click inside that window
        -- buys silence the player would read as a claim that worked.
        C.status = "Still waiting on the last one..."
        return
    end
    if not C.selected then C.status = "Pick a kit first."; return end
    -- Refused HERE as well as on the server. Not a duplicate rule - a claim
    -- that the server will certainly refuse still costs the player their one
    -- request per second, and kitClaim does not answer a refused flood.
    if C.shown and not DMClaim.isReady(C.shown) then
        C.status = "Not ready yet - about "
            .. DMClaim.waitText(C.shown.readyInMs) .. " to go."
        return
    end
    C.busy   = true
    C.status = "Claiming..."
    RDNet.send(TOKEN, "kitClaim", { id = C.selected })
end

local ICON = 20   -- the icon column: square, and the row height follows it

-- Drawn over the host panel by the prerender wrap below.
function DMClaim.draw(panel)
    if not C.listBox then return end
    local t, d, pad = DFKit.col.text, DFKit.col.textDim, DFKit.metrics.pad
    local n = C.kits and #C.kits or 0

    panel:drawText(C.kits and ("AVAILABLE  (" .. n .. ")") or "AVAILABLE",
                   pad, C.bandY or 0, d.r, d.g, d.b, 1, FONT)
    if n == 0 then
        panel:drawText(DMClaim.emptyLine(C.kits), pad + 8,
                       C.listBox:getY() + 6, d.r, d.g, d.b, 1, FONT)
    end

    -- The contents pane.
    local rx, rw = C.paneX or 0, C.paneW or 0
    if rw > 0 then
        local kit = C.shown
        panel:drawText(kit and (kit.label or kit.id) or "CONTAINS",
                       rx, C.bandY or 0, d.r, d.g, d.b, 1, FONT)
        local y = C.listBox:getY()
        if not kit then
            panel:drawText("Pick a kit to see what is in it.", rx, y + 4,
                           d.r, d.g, d.b, 1, FONT)
        else
            if kit.note and kit.note ~= "" then
                panel:drawText(DFKit.fitText(kit.note, FONT, rw), rx, y + 2,
                               d.r, d.g, d.b, 1, FONT)
                y = y + DFKit.rowHeight()
            end
            local rowH = math.max(ICON + 2, DFKit.rowHeight())
            local bottom = C.listBox:getY() + C.listBox:getHeight()
            for _, line in ipairs(DMClaim.linesFor(kit)) do
                if y + rowH > bottom then
                    -- Clipped rather than drawn past the pane. A kit with more
                    -- rows than fit says so instead of painting over the
                    -- footer; the deck can be resized taller.
                    panel:drawText("...", rx, y + 2, d.r, d.g, d.b, 1, FONT)
                    break
                end
                local lx = rx + (line.indent or 0) * 14
                local tex = line.icon and DMIcons.texture(line.icon)
                if tex then
                    panel:drawTextureScaled(tex, lx, y, ICON, ICON, 1, 1, 1, 1)
                end
                local c = line.dim and d or t
                -- The icon column is reserved whether or not this row has one,
                -- so an XP grant among items does not shunt its own text left
                -- and break the column.
                panel:drawText(
                    DFKit.fitText(line.text, FONT, rw - (lx - rx) - ICON - 6),
                    lx + ICON + 6, y + 3, c.r, c.g, c.b, 1, FONT)
                y = y + rowH
            end
        end
    end

    if C.status then
        local a = DFKit.col.accent
        panel:drawText(DFKit.fitText(C.status, FONT, panel.width - 190),
                       pad, C.footY or 0, a.r, a.g, a.b, 1, FONT)
    end
end

-- Names left, contents right. The list is the narrower half on purpose: a kit
-- name is a few words and its contents are the thing being read.
local LIST_FRAC, LIST_MIN = 0.38, 150

local function layout(panel, x, y, w, h)
    if not C.listBox then return end
    local m, pad = DFKit.metrics, DFKit.metrics.pad
    local bandH  = DFKit.rowHeight()
    local footH  = m.btnH + pad * 2

    local listW = math.max(LIST_MIN, math.floor(w * LIST_FRAC))
    if listW > w - LIST_MIN then listW = math.max(0, w - LIST_MIN) end

    C.bandY = y
    C.listBox:setX(x)
    C.listBox:setY(y + bandH)
    C.listBox:setWidth(listW)
    C.listBox:setHeight(h - bandH - footH - pad)

    C.paneX = x + listW + pad
    C.paneW = math.max(0, w - listW - pad)
    C.footY = y + h - footH + 4
end

function DMClaim.build(spec, panel, x, y, w, h)
    local m, pad = DFKit.metrics, DFKit.metrics.pad
    local footH  = m.btnH + pad * 2

    local list = KitList:new(x, y, w, h)
    list.itemheight = DFKit.rowHeight()
    list.drawBorder = true
    DFKit.well(list)
    list:initialise(); list:instantiate()
    panel:addChild(list)
    C.listBox = list
    C.panel   = panel

    local bx = x + w
    for _, btn in ipairs({ { 90, "Claim", DMClaim.claim, "action" },
                           { 80, "Refresh", DMClaim.refresh, nil } }) do
        bx = bx - btn[1]
        DFKit.button(panel, bx, y + h - footH, btn[1], btn[2], panel,
                     function() btn[3]() end, btn[4])
        bx = bx - m.gap
    end

    -- WRAP, never replace: a second tenant on this panel keeps whatever it
    -- drew. Same idiom as DMKitsTab and RCVehicleTab.
    local orig = panel.prerender
    panel.prerender = function(self_)
        if orig then orig(self_) end
        DMClaim.draw(self_)
    end

    layout(panel, x, y, w, h)

    -- Build is show, so this is the re-read. A stale catalogue is the one thing
    -- a claim surface must never present: the kit a player is looking at may
    -- have been deleted, spent, or newly earned since they last opened this.
    C.status, C.busy = nil, false
    C.shown = nil
    DMClaim.rebuild()
    DMClaim.refresh()
end

function DMClaim.resize(spec, panel, w, h)
    layout(panel, 0, 0, w, h)
end

-- ---------------------------------------------------------------------------
-- Registration
--
-- OnGameStart rather than OnGameBoot: isClient() is the guard, and boot fires
-- before a joining client knows it is one.
-- ---------------------------------------------------------------------------
Events.OnGameStart.Add(function()
    if not isClient() then return end
    if not (Dragonfly and Dragonfly.registerPlayerTab) then return end
    Dragonfly.registerPlayerTab{
        id     = TAB_ID,
        label  = getText("IGUI_DM_Kits"),
        order  = 50,
        build  = DMClaim.build,
        resize = DMClaim.resize,
        -- A list of names and a claim button. It wants a modest room, not the
        -- fleet inspector's; the deck clamps to the screen either way.
        prefW  = 520,
        prefH  = 420,
    }
end)

return DMClaim

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
