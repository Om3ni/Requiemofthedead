-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFServerView - the server's own INI options, in the deck.
--
-- Sibling of DFSandboxView and deliberately NOT a copy of it: the two registries
-- enumerate identically, so DFSandboxModel reads both and DFSandboxView.schemaFor
-- translates both. What differs is the write path, and it differs enough that
-- sharing the view would have meant a flag on every other line.
--
-- ---------------------------------------------------------------------------
-- THE WRITE PATH, and why it is not batched like the sandbox one.
--
-- Sandbox options move as ONE packet carrying the entire set, which is what
-- makes an instant-apply there a lost-update hazard for every option at once.
-- Server options do not move that way at all: each change is its own console
-- command, `/changeoption <Name> "<value>"`, handled by ChangeOptionCommand
-- (@CommandName "changeoption", ChangeOptionCommand.java:20). One option in,
-- one option out - so writing option A cannot disturb option B, and the reason
-- the sandbox tab batches simply does not exist here.
--
-- It is still staged rather than instant, for a different and smaller reason:
-- a review step before touching a live server's configuration, and one place to
-- change your mind. Vanilla sends on every keystroke-commit
-- (ISServerOptions.lua:184).
--
-- ARGUMENT SYNTAX IS NOT FREE-FORM. CommandBase splits on whitespace keeping
-- quoted runs together, then strips every quote from each token
-- (CommandBase.java:147-150), and @CommandArgs requires (\w+) then (.*) - the
-- second applied to the SECOND TOKEN only. So a value containing spaces MUST be
-- quoted or everything after the first word is silently dropped, and a value
-- containing a quote loses it. Both are handled in commandFor below.
--
-- ---------------------------------------------------------------------------
-- THE LOCAL ECHO, which is the honest part.
--
-- changeOption writes the value and saves the ini and tells NO client
-- (ServerOptions.java:335-344). There is no counterpart to the sandbox path's
-- re-broadcast (GameServer.java:1623-1630). So a connected client's copy is
-- whatever it received at connect, for the rest of the session:
--
--   * after we write, the local value does not move on its own
--   * another admin's change is invisible to us entirely
--   * "changed from default" is measured against a connect-time snapshot
--
-- Vanilla papers over the first of those by writing the new value into its own
-- list by hand (ISServerOptions.lua:186-189). We do the same, and say so: an
-- echoed row is marked as SENT rather than as read back, because it is a claim
-- about what we asked for and not about what the server holds. The server's
-- own reply to the command is the confirmation, and it lands in the console -
-- /reloadoptions is the button that makes the server re-read what it wrote.
--
-- AUTHORITY. `/changeoption` and `/reloadoptions` both carry
-- @RequiredCapability(Capability.ChangeAndReloadServerOptions)
-- (ChangeOptionCommand.java:23, ReloadOptionsCommand.java:22), checked by
-- CommandBase.PlayerSatisfyRequiredRights before the body runs and reported to
-- AntiCheat when it fails. The command also writes an admin-log line naming the
-- executor and the change (ChangeOptionCommand.java:44), so this surface
-- inherits an audit trail rather than needing one.

if isServer() then return end

require "DFKit"
require "DFForm"
require "ISUI/ISTextEntryBox"
require "Admin/DFSandboxModel"
require "Admin/DFSandboxView"
require "Admin/DFServerFlags"
require "Admin/DFStaged"

DFServerView = DFServerView or {}
local V = DFServerView

local FONT = DFKit.font.small

V.page    = nil
V.staged  = nil    -- DFStaged, built in attach()
V.sent    = {}     -- name -> value we asked for, echoed locally
V.filter  = ""

-- ---------------------------------------------------------------------------
-- Command construction. PURE, so the quoting rules above are testable without
-- a server - they are the part that fails silently when wrong.
-- ---------------------------------------------------------------------------

-- CommandBase strips every `"` from each token, so an embedded quote cannot
-- survive by escaping - vanilla escapes it (ISServerOptions.lua:179) and the
-- backslash arrives with the quote already gone. Dropping it here is the same
-- outcome, arrived at deliberately, and the caller is told.
function DFServerView.sanitize(value)
    local s = tostring(value)
    local cleaned = s:gsub('"', "")
    -- A newline would end the command line. Nothing legitimate carries one.
    cleaned = cleaned:gsub("[\r\n]", " ")
    return cleaned, cleaned ~= s
end

-- The exact line to send. Always quoted: an unquoted multi-word value loses
-- everything after the first word, and quoting a single word costs nothing.
function DFServerView.commandFor(name, value)
    local clean = DFServerView.sanitize(value)
    return "/changeoption " .. name .. ' "' .. clean .. '"'
end

-- ---------------------------------------------------------------------------
-- Values
-- ---------------------------------------------------------------------------

local function typeOf(name)
    local so = getServerOptions()
    local o = so and so:getOptionByName(name)
    return o and o:getType() or nil
end

-- Staged edit first, then what we last SENT (the echo), then the engine.
function DFServerView.readValue(name)
    return V.staged and V.staged:get(name) or DFServerView.liveValue(name)
end

-- The baseline a staged edit is compared against. NOT simply the engine: the
-- echo sits in front of it, because after we send a change the engine's copy
-- still holds the old value for the rest of the session and comparing against
-- it would re-stage the edit we just sent.
function DFServerView.liveValue(name)
    if V.sent[name] ~= nil then return V.sent[name] end
    local t = typeOf(name)
    if not t then return nil end
    local o = getServerOptions():getOptionByName(name)
    if t == "boolean" or t == "enum" then return o:getValue() end
    if t == "string" or t == "text" then return o:getValue() end
    if t == "integer" then return tonumber(o:getValueAsString()) end
    return o:getValueAsString()
end

-- ---------------------------------------------------------------------------
-- Apply
--
-- `send` is injected so a fixture can capture the command lines rather than
-- needing a server. Returns (true, count) or (false, reason).
--
-- Enum values go over the wire as the INTEGER INDEX: the command itself does
-- Integer.parseInt on the new value to render its reply
-- (ChangeOptionCommand.java:48), so a word would fault inside the handler.
-- DFForm's enum dial already stores an index, so nothing is converted - but the
-- moment somebody maps one to `choice` (which stores the string) that stops
-- being true, which is why it is stated here as well as in the schema mapping.
-- ---------------------------------------------------------------------------
function DFServerView.applyWith(send, pending)
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    if n == 0 then return false, "nothing staged" end

    local names = {}
    for name in pairs(pending) do names[#names + 1] = name end
    -- Sorted, so a run of changes reaches the admin log in a stable order and
    -- two applies of the same set are comparable.
    table.sort(names)

    for _, name in ipairs(names) do
        send(DFServerView.commandFor(name, pending[name]))
        -- The echo. Recorded whether or not the server accepts it, which is
        -- exactly why the row is marked SENT and not "current".
        V.sent[name] = pending[name]
    end
    return true, n
end

function DFServerView.apply()
    local ok, res = DFServerView.applyWith(SendCommandToServer,
                                           V.staged and V.staged.pending or {})
    if ok then
        V.staged:clear()
        V.status = res .. " change(s) sent. The server holds them once it "
                .. "replies in the console; this panel shows what was asked."
        print("[Dragonfly] server options: sent " .. tostring(res) .. " change(s).")
    else
        V.status = tostring(res)
    end
    DFServerView.rebuild()
    return ok
end

function DFServerView.reloadServer()
    SendCommandToServer("/reloadoptions")
    V.status = "Asked the server to re-read its options file."
end

-- ---------------------------------------------------------------------------
-- Filter. 144 options in one registry: without this the surface is a wall, and
-- the grouping only accounts for 61 of them. Matches the option NAME and its
-- label, case-insensitively, and keeps a section header only when something
-- under it survived - an empty heading reads as a missing option.
-- ---------------------------------------------------------------------------
function DFServerView.filterSchema(schema, query)
    query = tostring(query or ""):lower()
    if query == "" then return schema end

    local out = {}
    for _, e in ipairs(schema) do
        if e.group then
            out[#out + 1] = e
        else
            local hay = ((e.key or "") .. " " .. (e.label or "")):lower()
            if hay:find(query, 1, true) then out[#out + 1] = e end
        end
    end
    -- Drop headers with nothing beneath them.
    local kept = {}
    for i = 1, #out do
        local e = out[i]
        if e.group then
            local nxt = out[i + 1]
            if nxt and not nxt.group then kept[#kept + 1] = e end
        else
            kept[#kept + 1] = e
        end
    end
    return kept
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function DFServerView.rebuild()
    if not V.form then return end
    local schema = DFSandboxView.schemaFor(V.page)
    -- The restart mark rides DFForm's own `live` field, which draws the label
    -- dimmed and adds a line to the help popout. Only a VERIFIED restart entry
    -- sets it false; an unread option is left alone rather than claimed either
    -- way. See DFServerFlags' three-state note.
    for _, e in ipairs(schema) do
        if e.key and DFServerFlags.stateOf(e.key) == DFServerFlags.RESTART then
            e.live = false
        end
    end
    V.form.schema = DFServerView.filterSchema(schema, V.filter)
    V.form._helpCache = nil
    if V.form.rect then
        V.form:layout(V.form.rect.x, V.form.rect.y, V.form.rect.w, V.form.rect.h)
    end
end

local function reload()
    V.page = DFSandboxModel.buildServer()
    DFServerView.rebuild()
end

function DFServerView.attach(panel)
    V.staged = DFStaged.new(DFServerView.liveValue)

    V.form = DFForm.new{
        title      = "Server",
        inlineHelp = true,
        schema     = {},
        get        = DFServerView.readValue,
        -- Bound inline; see the same note in DFSandboxView. A named delegate
        -- per view adds nothing and reads as a copied helper.
        set        = function(k, v) V.staged:set(k, v) end,
        moved      = function(key)
            return (V.staged and V.staged:has(key)) or V.sent[key] ~= nil
        end,
        enabled    = function() return true end,
    }
    local formWidgets = V.form:attach(panel)

    V.search = ISTextEntryBox:new("", 0, 0, 160, DFKit.metrics.btnH)
    V.search:initialise(); V.search:instantiate()
    V.search.onTextChange = function()
        V.filter = V.search:getInternalText() or ""
        DFServerView.rebuild()
    end
    panel:addChild(V.search)

    V.applyBtn = DFKit.button(panel, 0, 0, 90, "Apply", panel,
        function() DFServerView.apply() end, "action",
        { tooltip = "Send each staged change as its own /changeoption command." })
    V.discardBtn = DFKit.button(panel, 0, 0, 90, "Discard", panel,
        function() V.staged:clear(); V.status = nil; DFServerView.rebuild() end)
    V.reloadBtn = DFKit.button(panel, 0, 0, 110, "Reload on server", panel,
        function() DFServerView.reloadServer() end, nil,
        { tooltip = "Runs /reloadoptions: the server re-reads its options file. "
                 .. "This does not refresh THIS panel - the engine never sends "
                 .. "server options back to a connected client." })

    reload()

    local out = { V.search, V.applyBtn, V.discardBtn, V.reloadBtn }
    for _, wdg in ipairs(formWidgets or {}) do out[#out + 1] = wdg end
    return out
end

function DFServerView.layout(panel, x, y, w, h)
    if not V.form then return end
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)

    local head = R:header(m.btnH + m.gap)
    V.search:setX(head.x); V.search:setY(head.y)
    V.search:setWidth(math.min(220, math.floor(head.w * 0.4)))
    V.searchHintX = head.x + V.search:getWidth() + m.gap
    V.searchHintY = head.y + 4
    V.searchHintW = head.w - V.search:getWidth() - m.gap

    local foot = R:footer(m.btnH + m.pad)
    V.footRect = { x = foot.x, y = foot.y, w = foot.w, h = foot.h }
    local bx = foot.x + foot.w
    for _, b in ipairs({ V.applyBtn, V.discardBtn, V.reloadBtn }) do
        if b then
            bx = bx - b:getWidth()
            b:setX(bx); b:setY(foot.y)
            bx = bx - m.gap
        end
    end
    V.footTextW = bx - foot.x - m.gap

    local body = R:rest()
    V.form:layout(body.x, body.y, body.w, body.h)
end

function DFServerView.draw(el)
    V.form:draw(el)

    local d = DFKit.col.textDim
    if V.searchHintX then
        local total = V.page and V.page.count or 0
        local shown = 0
        for _, e in ipairs(V.form.schema or {}) do if e.key then shown = shown + 1 end end
        local hint = (V.filter ~= "" and (shown .. " of " .. total .. " shown") or (total .. " options"))
        local known = DFServerFlags.coverage(total)
        hint = hint .. "   -   restart-effect verified for " .. known
            .. "; unmarked options have not been checked"
        el:drawText(DFKit.fitText(hint, FONT, V.searchHintW or 200),
                    V.searchHintX, V.searchHintY, d.r, d.g, d.b, 1, FONT)
    end

    local r = V.footRect
    if not r then return end
    local n = V.staged and V.staged:count() or 0
    local text, col
    if n > 0 then
        text = n .. " change" .. (n == 1 and "" or "s") .. " staged - not sent"
        col = DFKit.col.accent
    elseif V.status then
        text, col = V.status, d
    else
        text, col = "No changes staged.", d
    end
    el:drawText(DFKit.fitText(text, FONT, V.footTextW or r.w),
                r.x, r.y + 5, col.r, col.g, col.b, 1, FONT)
end

function DFServerView.onShow() reload() end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
