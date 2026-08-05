-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMImportTab.lua - the paste target: Dragonfly "Zones" tab (client).
--
-- THE ADMIN STORY, three clicks, no server filesystem ceremony: copy the
-- PhunZones export text (phunzones.txt, or any {version=2,data={...}} layer)
-- to the OS clipboard, open Dragonfly -> Zones, [Read clipboard] to preview -
-- the SHARED LMImport parser runs locally, so "75 zones, 9 warnings" appears
-- before anything touches the wire - then [Import to server] ships the raw
-- TEXT in one RDNet command when it fits under CHUNK_BYTES, and in as many
-- commands as it takes when it does not - the engine caps a single command
-- string at 32767 bytes, which a live ~38KB PhunZones layer exceeds. The
-- packet limiter counts packets rather than bytes, so few-and-large stays the
-- cheap shape either way. The SERVER re-parses authoritatively - the client preview
-- is UX, never trust - writes RFTDLimes.ini, applies, and broadcasts the new
-- baseline to everyone including us; the status line mirrors the server's
-- notice so the admin sees the authoritative outcome, not the preview.
--
-- Clipboard.getClipboard() is the engine's own exposed surface
-- (LuaManager setExposed(Clipboard.class); zombie/core/Clipboard.java:36) -
-- reading it here is a button press by the panel's owner, on their own
-- machine, of text they just copied.
--
-- Soft-dep on Dragonfly, the RPNecroTab pattern: no DFRegistry, no tab, and
-- Limes ships fine without it. The tab id "limes" is where the M4 map editor
-- (Longstrider-style drawing) will also land - this paste surface is the
-- first resident, not the final form; layout is deliberately plain and
-- expects iteration.

if isServer() then return end

require "LMCore"
require "LMImport"

LMImportTab = LMImportTab or {}

local TOKEN    = "RFTDLimes"

-- CHUNK_BYTES is an ENGINE ceiling, not a policy: a string inside a client
-- command carries a signed-short length (ByteBufferReader.getUTF, :52), so
-- 32767 bytes is the wall. Past it the server throws inside
-- receiveClientCommand BEFORE any Lua runs and cannot reply at all - the
-- status line hangs on "waiting for the verdict" forever. 24000 keeps
-- headroom under it. Anything larger is split and reassembled server-side
-- (LMSync "pasteChunk"), so a live layer of any realistic size goes through.
-- MAX_TEXT then only mirrors the server's assembly cap.
local CHUNK_BYTES = 24000
local MAX_TEXT    = 512 * 1024

local ui = nil   -- { status, store, warns = {labels}, importBtn }

local function setStatus(msg, good)
    if not ui or not ui.status then return end
    ui.status:setName(msg)
    if good then ui.status.r, ui.status.g, ui.status.b = 0.75, 0.95, 0.75
    else         ui.status.r, ui.status.g, ui.status.b = 0.95, 0.85, 0.65 end
end

local function setStoreLine()
    if not ui or not ui.store then return end
    ui.store:setName("Server store now: " .. #Limes.zoneNames()
        .. " zones, revision " .. tostring(Limes.revision))
end

local function showWarnings(list)
    if not ui then return end
    for i = 1, #ui.warns do
        ui.warns[i]:setName(list and list[i] or "")
    end
    if list and #list > #ui.warns then
        ui.warns[#ui.warns]:setName("... and " .. (#list - #ui.warns + 1) .. " more (console has all)")
    end
end

local function readClipboard()
    LMImportTab.pending = nil
    if ui and ui.importBtn then ui.importBtn.enable = false end
    showWarnings(nil)

    local text = nil
    pcall(function() text = Clipboard.getClipboard() end)
    if type(text) ~= "string" or text == "" then
        setStatus("Clipboard is empty - copy the export text first.")
        return
    end
    if #text > MAX_TEXT then
        setStatus("Clipboard is " .. math.floor(#text / 1024) .. "KB - over the server's "
            .. math.floor(MAX_TEXT / 1024) .. "KB assembly cap. Put the file in the "
            .. "server's Zomboid/Lua/ and use the filename route instead.")
        print("[Limes] paste refused: " .. #text .. " bytes exceeds the "
            .. MAX_TEXT .. "-byte assembly cap. Copy the export to "
            .. "<server>/Lua/phunzones.txt, then either restart the server "
            .. "(first-boot import) or run LMSync.requestImport(\"phunzones.txt\") "
            .. "from the client console. Hand-editing RFTDLimes.ini also works.")
        return
    end

    local ok, res = LMImport.parsePhunZones(text)
    if not ok then
        setStatus("Does not parse as a PhunZones layer: " .. tostring(res))
        return
    end

    LMImportTab.pending = text
    if ui and ui.importBtn then ui.importBtn.enable = true end
    setStatus("Preview: " .. res.count .. " zones, " .. #res.warnings
        .. " warnings. Review, then import.", true)
    showWarnings(res.warnings)
    for i = 1, #res.warnings do print("[Limes] preview: " .. res.warnings[i]) end
end

-- One command when it fits, N when it does not. The single-shot path is kept
-- rather than folded into the chunked one so the common case stays one packet
-- and one handler - and so a layer that fits never depends on assembly state
-- existing on the server at all.
local function sendImport()
    local text = LMImportTab.pending
    if not text then return end

    if #text <= CHUNK_BYTES then
        RDNet.send(TOKEN, "pasteImport", { text = text })
        setStatus("Sent to server - waiting for the verdict...")
    else
        local total = math.ceil(#text / CHUNK_BYTES)
        for i = 1, total do
            local from = (i - 1) * CHUNK_BYTES + 1
            RDNet.send(TOKEN, "pasteChunk", {
                seq   = i,
                total = total,
                text  = string.sub(text, from, from + CHUNK_BYTES - 1),
            })
        end
        -- Say the count out loud: if the verdict never lands, the admin can see
        -- how many pieces were owed rather than staring at a silent spinner.
        setStatus("Sent " .. math.floor(#text / 1024) .. "KB in " .. total
            .. " chunks - waiting for the verdict...")
    end

    if ui and ui.importBtn then ui.importBtn.enable = false end
end

-- Positioning only, no widget creation. Split out from build() so a deck
-- resize can reflow in place instead of destroying and rebuilding - a rebuild
-- would throw away the parsed preview sitting in LMImportTab.pending.
local function layout(panel, x, y, w, h)
    if not ui then return end
    local m = DFKit.metrics
    local s = DFKit.layout(panel, x, y, w, h):stack(0)

    local function place(el, hgt)
        local lx, ly = s:row(hgt)
        el:setX(lx)
        el:setY(ly)
    end

    place(ui.title, 20)
    place(ui.sub1, 16)
    place(ui.sub2, 24)

    -- both buttons share one row, so take the row once and place across it
    local bx, by = s:row(m.btnH + m.pad)
    ui.readBtn:setX(bx);         ui.readBtn:setY(by)
    ui.importBtn:setX(bx + 150); ui.importBtn:setY(by)

    place(ui.status, 22)
    for i = 1, #ui.warns do place(ui.warns[i], 16) end
    s.y = s.y + 6
    place(ui.store, 16)
end

local function build(spec, panel, x, y, w, h)
    local C = DFKit.col

    local title = DFKit.label(panel, 0, 0,
        "Zone import - paste a PhunZones custom layer (the text of phunzones.txt).")
    local sub1 = DFKit.label(panel, 0, 0,
        "Copy the export to the clipboard, preview it here, then import. The server", C.textDim)
    local sub2 = DFKit.label(panel, 0, 0,
        "rewrites RFTDLimes.ini and every client re-syncs. Admin only.", C.textDim)

    local readBtn   = DFKit.button(panel, 0, 0, 140, "Read clipboard",   panel, readClipboard)
    local importBtn = DFKit.button(panel, 0, 0, 150, "Import to server", panel, sendImport, "primary")
    importBtn.enable = false

    local status = DFKit.label(panel, 0, 0, "No preview yet.")
    local warns = {}
    for i = 1, 8 do warns[i] = DFKit.label(panel, 0, 0, "", C.warn) end
    local store = DFKit.label(panel, 0, 0, "")

    ui = {
        title = title, sub1 = sub1, sub2 = sub2,
        readBtn = readBtn, importBtn = importBtn,
        status = status, store = store, warns = warns,
    }
    LMImportTab.pending = nil
    setStoreLine()
    layout(panel, x, y, w, h)
end

-- The authoritative outcome arrives as the server's notice; the local store
-- line moves when the broadcast baseline lands (Limes.onChanged).
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TOKEN or command ~= "notice" then return end
    if args and args.msg then setStatus(tostring(args.msg), true) end
end)

Limes.onChanged(function() setStoreLine() end)

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id     = "limes",
        label  = "Zones",
        order  = 6,
        build  = build,
        resize = function(_, panel, w, h) layout(panel, 0, 0, w, h) end,
    }
    print("[Limes] import tab registered into Dragonfly")
end)

return LMImportTab

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
