-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMImportTab.lua - the sharing surface: Dragonfly "Zones" tab (client).
--
-- THE ADMIN STORY, three clicks, no server filesystem ceremony: copy a zone
-- setup - schema-1 JSON from the offline converter or another server's
-- export, or an RFTDLimes .ini backup - to the OS clipboard, open Dragonfly
-- -> Zones, [Read clipboard] to preview - the SHARED LMImport parser runs
-- locally, so "75 zones, 9 warnings" appears before anything touches the
-- wire - then [Import to server] ships the raw TEXT in one RDNet command
-- when it fits under CHUNK_BYTES, and in as many commands as it takes when
-- it does not - the engine caps a single command string at 32767 bytes,
-- which a full setup can exceed. The packet limiter counts packets rather
-- than bytes, so few-and-large stays the cheap shape either way. The SERVER
-- re-parses authoritatively - the client preview is UX, never trust - writes
-- RFTDLimes.ini, applies, and broadcasts the new baseline to everyone
-- including us; the status line mirrors the server's notice so the admin
-- sees the authoritative outcome, not the preview.
--
-- [Copy export] is the other half of sharing: the WHOLE store - zones,
-- tiers, profiles, loot, moon overlays - as schema-1 JSON onto the
-- clipboard, ready to paste into another server's Zones tab or a file.
-- PhunZones data no longer imports here: it converts OFFLINE
-- (tools/limes-zone-converter.html) and the JSON is what gets pasted.
--
-- Clipboard.getClipboard() is the engine's own exposed surface
-- (LuaManager setExposed(Clipboard.class); zombie/core/Clipboard.java:36) -
-- reading it here is a button press by the panel's owner, on their own
-- machine, of text they just copied.
--
-- Soft-dep on Dragonfly, the RPNecroTab pattern: no DFRegistry, no tab, and
-- Limes ships fine without it. Since 2026-08-04 this is the IMPORT VIEW of the
-- Zones tab rather than the whole of it - LMZonesTab owns the registration and
-- puts the M4 map editor beside it. Import is how a layer arrives; the editor
-- is how it is shaped afterwards, and an admin mid-migration needs both.

if isServer() then return end

require "LMCore"
require "LMIni"
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

-- EVERYTHING THE IMPORTER SAYS GOES TO DFLog, source "Limes".
--
-- The eight warning labels below are a preview, not the record: nine warnings
-- fitted and seventeen did not, and the overflow line read "... and 9 more
-- (console has all)" - which was true only because these lines were also being
-- print()ed, and print goes to the game log, not to anywhere an admin can scroll
-- or copy. Pushing them into DFLog costs one call and puts them in the suite's
-- own Console tab, in LMImportWindow's log pane, and in the clipboard-copy
-- button, all of which already existed.
local function log(text, level)
    print("[Limes] " .. tostring(text))
    if DFLog and DFLog.push then
        DFLog.push({ source = "Limes", level = level or "info", text = tostring(text) })
    end
end

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

    -- No guard: Clipboard.getClipboard (Clipboard:36) wraps the GLFW read in
    -- catch(Throwable) and returns the cached value off the main thread, so it
    -- cannot throw. Only the class being absent needs saying.
    local text = Clipboard and Clipboard.getClipboard()
    if type(text) ~= "string" or text == "" then
        setStatus("Clipboard is empty - copy the export text first.")
        return
    end
    if #text > MAX_TEXT then
        setStatus("Clipboard is " .. math.floor(#text / 1024) .. "KB - over the server's "
            .. math.floor(MAX_TEXT / 1024) .. "KB assembly cap. Put the file in the "
            .. "server's Zomboid/Lua/ and use the filename route instead.")
        log("paste refused: " .. #text .. " bytes exceeds the "
            .. MAX_TEXT .. "-byte assembly cap. Copy the file to "
            .. "<server>/Lua/limes-zones.json, then run "
            .. "LMSync.requestImport(\"limes-zones.json\") from the client "
            .. "console. Hand-editing RFTDLimes.ini also works.", "warn")
        return
    end

    -- parseAny: schema-1 JSON is the sharing dialect, and an RFTDLimes .ini
    -- is a legitimate thing to paste back (until 2026-08-05 it died on line 1).
    local ok, res = LMImport.parseAny(text)
    if not ok then
        setStatus(tostring(res))
        return
    end
    local dialect = (res.format == "ini") and "RFTDLimes .ini" or "zones JSON"

    LMImportTab.pending = text
    if ui and ui.importBtn then ui.importBtn.enable = true end
    setStatus("Preview: " .. dialect .. ", " .. res.count .. " zones, " .. #res.warnings
        .. " warnings. Review, then import.", true)
    showWarnings(res.warnings)
    log(string.format("preview: %s, %d zones, %d warnings", dialect, res.count, #res.warnings))
    for i = 1, #res.warnings do log("preview: " .. res.warnings[i], "warn") end
end

-- The door out: the whole replica as schema-1 JSON, onto the clipboard.
-- Local and instant - no wire, no capability, because the client is reading
-- what it was already sent. Clipboard.setClipboard is the write half of the
-- surface the read button already uses (zombie/core/Clipboard.java:55-62;
-- on the main thread it writes through GLFW, off it the value parks in
-- delaySetMainThread and lands on the next updateMainThread pass).
local function copyExport()
    local raw = Limes.raw()
    local n = 0
    for _ in pairs(raw) do n = n + 1 end
    if n == 0 then
        setStatus("Nothing to export - the store is empty.")
        return
    end
    if not (Clipboard and Clipboard.setClipboard) then
        setStatus("Clipboard is not available - export not copied.")
        return
    end
    local text = LMImport.exportSchema1(raw, Limes.revision)
    Clipboard.setClipboard(text)
    setStatus("Copied " .. n .. " record(s) as zones JSON ("
        .. math.floor(#text / 1024 + 0.5) .. "KB), revision "
        .. tostring(Limes.revision) .. ".", true)
    log("export: " .. n .. " records, " .. #text .. " bytes, revision "
        .. tostring(Limes.revision))
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

-- ---------------------------------------------------------------------------
-- The test rig: wipe the map, then go stand in what you drew
-- ---------------------------------------------------------------------------

-- Templates are listed but marked, because they are the one thing in the store
-- you cannot travel to - no geometry, nothing to stand in. Better to show them
-- greyed with a reason than to hide them and leave an admin wondering where
-- Hard went.
local function refreshZoneList()
    if not ui or not ui.zoneList then return end
    local sel = ui.zoneList.items[ui.zoneList.selected]
    local keep = sel and sel.item and sel.item.name
    DFKit.refillList(ui.zoneList, function(box)
        local names = Limes.zoneNames()
        for i = 1, #names do
            local z = Limes.getZone(names[i])
            local cx, cy = Limes.getZoneCenter(names[i])
            local label = names[i]
            if not cx then label = label .. "   (template - no geometry)"
            elseif z and z.disabled then label = label .. "   (disabled)" end
            box:addItem(label, { name = names[i], x = cx, y = cy })
            if names[i] == keep then box.selected = box:size() end
        end
    end)
end

local function teleportToSelected()
    if not ui or not ui.zoneList then return end
    local row = ui.zoneList.items[ui.zoneList.selected]
    local z = row and row.item
    if not z then setStatus("Select a zone first."); return end
    if not z.x then
        setStatus(z.name .. " is a template - no geometry to stand in.")
        return
    end
    if not RDTeleport then setStatus("RDTeleport missing - Core out of date?"); return end
    local ok, why = RDTeleport.toCoords(z.x, z.y, 0)
    if ok then setStatus(string.format("Teleporting to %s (%d, %d).", z.name, z.x, z.y), true)
    else       setStatus(why or "Teleport refused.") end
end

local function clearAll()
    local n = #Limes.zoneNames()
    if n == 0 then setStatus("Store is already empty."); return end
    -- No confirm dialog available means no clear. The button already holds-to-
    -- fire (DFKit's "danger" kind), but a wipe of every zone on the server
    -- should not rest on that alone.
    if not (DFConfirm and DFConfirm.ask) then
        setStatus("DFConfirm unavailable - refusing to clear without a confirmation.")
        return
    end
    DFConfirm.ask(string.format(
        "Delete all %d zones on the server?\n\nThe current store is snapshotted to %s first,"
        .. " but that is ONE level of undo - the next clear overwrites it.", n, "RFTDLimes.backup.ini"),
        function()
            RDNet.send(TOKEN, "clearAll", {})
            setStatus("Clear sent - waiting for the verdict...")
        end)
end

-- Positioning only, no widget creation. Split out from attach() so a deck
-- resize can reflow in place instead of destroying and rebuilding - a rebuild
-- would throw away the parsed preview sitting in LMImportTab.pending.
function LMImportTab.layout(panel, x, y, w, h)
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

    -- the import buttons share one row, so take the row once and place across it
    local bx, by = s:row(m.btnH + m.pad)
    ui.readBtn:setX(bx);          ui.readBtn:setY(by)
    ui.importBtn:setX(bx + 150);  ui.importBtn:setY(by)
    ui.exportBtn:setX(bx + 310);  ui.exportBtn:setY(by)
    -- Clear sits at the far right of the same row, deliberately away from
    -- Import: the two are one careless click apart and mean opposite things.
    ui.clearBtn:setX(bx + w - 130 - m.pad * 2)
    ui.clearBtn:setY(by)

    -- the diagnostics pair takes its own row under the operations
    local cx, cy = s:row(m.btnH + m.pad)
    ui.censusBtn:setX(cx);            ui.censusBtn:setY(cy)
    ui.censusAutoBtn:setX(cx + 100);  ui.censusAutoBtn:setY(cy)

    place(ui.status, 22)
    for i = 1, #ui.warns do place(ui.warns[i], 16) end
    s.y = s.y + 6
    place(ui.store, 16)

    -- The list takes whatever vertical space is left, with the teleport button
    -- parked under it - so a tall panel shows more zones rather than more gap.
    local lx, ly = s:row(0)
    local listH = math.max(60, (y + h) - ly - m.btnH - m.pad * 3)
    DFKit.sizeList(ui.zoneList, lx, ly, w - m.pad * 2, listH)
    ui.gotoBtn:setX(lx)
    ui.gotoBtn:setY(ly + listH + m.pad)
end

-- The DFViews contract: build every widget once and hand the host a flat list,
-- which it shows and hides on a switch. Never rebuilt - a rebuild on every
-- switch would drop the parsed clipboard preview and the list selection each
-- time somebody glanced at the editor.
function LMImportTab.attach(panel)
    local C = DFKit.col
    local bag = {}

    local title = DFKit.label(panel, 0, 0,
        "Zone sharing - paste a zones JSON (or an RFTDLimes .ini backup).")
    local sub1 = DFKit.label(panel, 0, 0,
        "Copy the setup to the clipboard, preview it here, then import. The server", C.textDim)
    local sub2 = DFKit.label(panel, 0, 0,
        "rewrites RFTDLimes.ini and every client re-syncs. Admin only.", C.textDim)

    local readBtn   = DFKit.button(panel, 0, 0, 140, "Read clipboard",   panel, readClipboard)
    local importBtn = DFKit.button(panel, 0, 0, 150, "Import to server", panel, sendImport, "primary")
    importBtn.enable = false
    local exportBtn = DFKit.button(panel, 0, 0, 130, "Copy export", panel, copyExport, "action",
        { tooltip = "Copy the WHOLE current store - zones, tiers, profiles, loot rules,"
                 .. " moon overlays - to the clipboard as zones JSON, ready to paste into"
                 .. " another server's Zones tab or save as a file." })

    -- THE CENSUS PAIR, moved here from the Zone Selector toolbar with the S3
    -- declutter: global diagnostics belong in the operations window, beside
    -- import/export/clear, not among per-zone gestures. They exist because
    -- zeds enforcement is SILENT by design (a corpse in a walled safe zone is
    -- worse than the spawn it replaces) - the census is the only way to watch
    -- it work, and it reports to the SERVER log, beside the .ini it explains.
    local censusBtn = DFKit.button(panel, 0, 0, 90, "Zed census", panel, function()
            if LMSync and LMSync.printCensus then
                LMSync.printCensus(false)
                setStatus("Census requested - the report is in the server log.", true)
            end
        end, "action",
        { tooltip = "Count the zombies actually standing in every zone right now and"
                 .. " print them to the SERVER log beside each zone's settings. Zones"
                 .. " on unloaded ground report 'unloaded' rather than a zero they"
                 .. " have not earned." })
    local censusAutoBtn = DFKit.button(panel, 0, 0, 110, "Census auto: off", panel, function()
            LMImportTab.censusAuto = not LMImportTab.censusAuto
            if LMSync and LMSync.setCensus then LMSync.setCensus(LMImportTab.censusAuto) end
            -- This closure can outlive the panel; the completed server toggle
            -- does not require a label to remain, so teardown is explicit.
            if ui and ui.censusAutoBtn then
                ui.censusAutoBtn:setTitle("Census auto: "
                    .. (LMImportTab.censusAuto and "on" or "off"))
            end
        end, "action",
        { tooltip = "Repeat the census every ten GAME minutes. Off by default and"
                 .. " never persisted: a diagnostic that survives a restart is one"
                 .. " somebody forgot to turn off." })
    local clearBtn  = DFKit.button(panel, 0, 0, 130, "Clear all zones", panel, clearAll, "danger",
        { tooltip = "Wipe every zone on the server, so a dial can be tested against an empty"
                 .. " map instead of 76 zones answering lookups.\n\nThe current store is"
                 .. " snapshotted to RFTDLimes.backup.ini first - ONE level of undo, overwritten"
                 .. " by the next clear. Templates are not re-seeded; the store stays empty until"
                 .. " the next server restart." })

    local status = DFKit.label(panel, 0, 0, "No preview yet.")
    local warns = {}
    for i = 1, 8 do warns[i] = DFKit.label(panel, 0, 0, "", C.warn) end
    local store = DFKit.label(panel, 0, 0, "")

    -- The drill-down: every zone, click one, go stand in it. This is the
    -- verification half of the test rig - a dial set to 100% is only proof if
    -- you can get inside the zone that carries it - and it is deliberately the
    -- plainest thing that works, because the M4 map editor replaces this panel
    -- wholesale rather than growing out of it.
    local zoneList = ISScrollingListBox:new(0, 0, 10, 10)
    zoneList:initialise()
    zoneList:instantiate()
    zoneList.itemheight = DFKit.metrics.rowH or 18
    zoneList.drawBorder = true
    zoneList.selected = 0
    panel:addChild(zoneList)

    local gotoBtn = DFKit.button(panel, 0, 0, 150, "Teleport to zone", panel, teleportToSelected,
        "action",
        { tooltip = "Teleport to the centre of the selected zone - the middle of its LARGEST"
                 .. " rectangle, so the destination is always inside the zone even when it is"
                 .. " L-shaped or split across the map.\n\nNeeds the Teleport-to-coordinates"
                 .. " capability. Templates have no geometry and cannot be visited." })

    ui = {
        title = title, sub1 = sub1, sub2 = sub2,
        readBtn = readBtn, importBtn = importBtn, exportBtn = exportBtn,
        censusBtn = censusBtn, censusAutoBtn = censusAutoBtn,
        clearBtn = clearBtn,
        status = status, store = store, warns = warns,
        zoneList = zoneList, gotoBtn = gotoBtn,
    }
    refreshZoneList()
    LMImportTab.pending = nil
    setStoreLine()

    for _, el in ipairs({ title, sub1, sub2, readBtn, importBtn, exportBtn,
                          censusBtn, censusAutoBtn,
                          clearBtn, status, store, zoneList, gotoBtn }) do
        bag[#bag + 1] = el
    end
    for i = 1, #warns do bag[#bag + 1] = warns[i] end
    return bag
end

-- Re-entering the panel is a chance to catch up with the store; the count line
-- and the drill-down list both follow onChanged anyway, so this only matters
-- after a switch that happened between broadcasts.
function LMImportTab.onShow()
    setStoreLine()
    refreshZoneList()
end

-- The authoritative outcome arrives as the server's notice; the local store
-- line moves when the broadcast baseline lands (Limes.onChanged).
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TOKEN or command ~= "notice" then return end
    if args and args.msg then
        setStatus(tostring(args.msg), true)
        log("server: " .. tostring(args.msg))
    end
end)

-- Both halves of the panel follow the store: the count line and the drill-down
-- list. onChanged fires on the baseline that lands after an import or a clear,
-- so the list is never stale against what the server actually holds.
Limes.onChanged(function()
    setStoreLine()
    refreshZoneList()
end)

-- Tab registration lives in LMZonesTab: this panel is one VIEW of the Zones tab
-- now, sitting beside the M4 editor rather than owning the tab outright.

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
