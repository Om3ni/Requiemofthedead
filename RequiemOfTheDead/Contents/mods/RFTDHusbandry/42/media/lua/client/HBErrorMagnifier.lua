-- HBErrorMagnifier - optional integration with the Error Magnifier mod.
--
-- If Error Magnifier is loaded, registers a debug-report function so users
-- can copy our diagnostic state alongside any errors via EM's UI ("Mods" tab).
-- If EM is not loaded, this file is a no-op.
--
-- DESIGN INTENT: fully modular. Deleting this file removes the integration
-- with no other changes required. The state it reads (HBKeepAlive global
-- table, HBData globals, SandboxVars) is exposed for the keep-alive's own
-- purposes; this file is a passive consumer.
--
-- To fully de-instrument once the mod is stable: delete this file, then
-- delete the `HBKeepAlive` table declaration and the four/five `HBKeepAlive.*`
-- field writes in server/HBKeepAlive.lua. Both are clearly marked.
--
-- MP NOTE: this file is client-side because Error Magnifier itself is
-- client-side. In MP, server-only state (HBKeepAlive instrumentation, the
-- live HBData.seen set) lives on the server process and is not visible to
-- the client. The report will degrade gracefully - fields read as nil and
-- are reported as such. SP and host-and-play see full state.

Events.OnGameStart.Add(function()
    -- Try to require EM's main module. pcall catches the case where EM is
    -- not installed or its module path resolves differently in some build.
    local ok, errorMagnifier = pcall(require, "errorMagnifier_Main")
    if not ok or type(errorMagnifier) ~= "table" or type(errorMagnifier.registerDebugReport) ~= "function" then
        return
    end

    local function buildReport()
        local report = {}

        -- Sandbox state
        local sv = SandboxVars and SandboxVars.RFTDHusbandry
        report.sandbox = {
            Enable = sv and sv.Enable,
        }

        -- Keep-alive instrumentation (server-side state; nil on MP client)
        if HBKeepAlive then
            report.keepAlive = {
                tickCount            = HBKeepAlive.tickCount,
                lastTickAt           = HBKeepAlive.lastTickAt,
                lastLooseRefilled    = HBKeepAlive.lastLooseRefilled,
                lastTrailerRefilled  = HBKeepAlive.lastTrailerRefilled,
                lastHutchRefilled    = HBKeepAlive.lastHutchRefilled,
                trailerOverrideCalls = HBKeepAlive.trailerOverrideCalls,
            }
        else
            report.keepAlive = "(not visible - server-only state in MP, or module not loaded)"
        end

        -- HBData state (counts of each map)
        if HBData then
            local function countTable(t)
                if type(t) ~= "table" then return 0 end
                local n = 0
                for _ in pairs(t) do n = n + 1 end
                return n
            end
            report.data = {
                seenAnimals   = countTable(HBData.seen),
                herdEntries   = countTable(HBData.herds),
                persistentIds = countTable(HBData.idMap),
            }
        else
            report.data = "(not visible - server-only state in MP, or module not loaded)"
        end

        -- Module presence detection
        report.modules = {
            HBData       = HBData       ~= nil,
            HBKeepAlive  = HBKeepAlive  ~= nil,
            HBCmd        = HBCmd        ~= nil,
            HBAPIProbe   = HBAPIProbe   ~= nil,
            HBDebugPanel = HBDebugPanel ~= nil,
        }

        return report
    end

    local ok2, err = pcall(function()
        errorMagnifier.registerDebugReport("RFTDHusbandry", buildReport, "Husbandry (Requiem)")
    end)
    if ok2 then
        print("[HB] Registered Error Magnifier debug report")
    else
        print("[HB] Error Magnifier registration failed: " .. tostring(err))
    end
end)
