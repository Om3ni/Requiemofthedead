-- LMImportTab.lua - the paste target: Dragonfly "Zones" tab (client).
--
-- THE ADMIN STORY, three clicks, no server filesystem ceremony: copy the
-- PhunZones export text (phunzones.txt, or any {version=2,data={...}} layer)
-- to the OS clipboard, open Dragonfly -> Zones, [Read clipboard] to preview -
-- the SHARED LMImport parser runs locally, so "75 zones, 9 warnings" appears
-- before anything touches the wire - then [Import to server] ships the raw
-- TEXT in one RDNet command (one ~40KB packet against the 1MB connection
-- buffer; the engine limiter counts packets, not bytes, so one big send is
-- the cheap shape). The SERVER re-parses authoritatively - the client preview
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
local MAX_TEXT = 512 * 1024   -- matches the server's cap; the live layer is ~40KB

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
        setStatus("Clipboard is " .. math.floor(#text / 1024) .. "KB - over the "
            .. math.floor(MAX_TEXT / 1024) .. "KB cap. Wrong copy?")
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

local function sendImport()
    if not LMImportTab.pending then return end
    RDNet.send(TOKEN, "pasteImport", { text = LMImportTab.pending })
    setStatus("Sent to server - waiting for the verdict...")
    if ui and ui.importBtn then ui.importBtn.enable = false end
end

local function build(spec, panel, x, y, w, h)
    local PAD, BTN_H = 8, 24
    local cursorY = PAD

    local function mkLabel(text, ly, r, g, b)
        local l = ISLabel:new(PAD, ly, 16, text, r or 0.85, g or 0.85, b or 0.85, 1, UIFont.Small, true)
        l:initialise(); l:instantiate()
        panel:addChild(l)
        return l
    end
    local function mkBtn(label, bx, bw, handler)
        local btn = ISButton:new(bx, cursorY, bw, BTN_H, label, panel, handler)
        btn.borderColor.a = 0.4
        btn:initialise(); btn:instantiate()
        panel:addChild(btn)
        return btn
    end

    mkLabel("Zone import - paste a PhunZones custom layer (the text of phunzones.txt).", cursorY)
    cursorY = cursorY + 20
    mkLabel("Copy the export to the clipboard, preview it here, then import. The server", cursorY, 0.65, 0.65, 0.65)
    cursorY = cursorY + 16
    mkLabel("rewrites RFTDLimes.ini and every client re-syncs. Admin only.", cursorY, 0.65, 0.65, 0.65)
    cursorY = cursorY + 24

    mkBtn("Read clipboard", PAD, 140, readClipboard)
    local importBtn = mkBtn("Import to server", PAD + 150, 150, sendImport)
    importBtn.enable = false
    cursorY = cursorY + BTN_H + PAD

    local status = mkLabel("No preview yet.", cursorY, 0.75, 0.85, 0.95)
    cursorY = cursorY + 22

    local warns = {}
    for i = 1, 8 do
        warns[i] = mkLabel("", cursorY, 0.8, 0.7, 0.5)
        cursorY = cursorY + 16
    end
    cursorY = cursorY + 6

    local store = mkLabel("", cursorY, 0.75, 0.85, 0.95)

    ui = { status = status, store = store, warns = warns, importBtn = importBtn }
    LMImportTab.pending = nil
    setStoreLine()
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
        id    = "limes",
        label = "Zones",
        order = 6,
        build = build,
    }
    print("[Limes] import tab registered into Dragonfly")
end)

return LMImportTab

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
