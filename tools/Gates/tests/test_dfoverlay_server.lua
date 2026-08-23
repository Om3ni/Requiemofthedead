-- DFOverlay_Server fixture - who may rearrange what, and where it is kept.
--
-- WHAT IS AT RISK. This is a write endpoint on a live server, so the first
-- question is authority and the gate here is UNUSUAL: it is per payload, not
-- per command. DFServer's dispatcher takes one capability per action, and one
-- capability is the wrong shape for this action - the sandbox pages are gated
-- on Capability.SandboxOptions and the server page on
-- ChangeAndReloadServerOptions, and a role can hold either without the other.
-- So the check moved inside the handler, which means the DISPATCHER IS NOT
-- CARRYING IT and these tests are the only thing standing between a
-- sandbox-only moderator and the server page's layout. They are written as
-- crossed pairs for that reason: each role is asserted to be allowed its own
-- page AND refused the other, because a gate that says yes to everyone passes
-- any test that only checks the yes.
--
-- The second risk is the store. An empty layout must REMOVE the page rather
-- than store an empty list - otherwise there are two ways to say "no layout",
-- the document grows a key every time somebody opens the editor and changes
-- their mind, and a wipe restores a file full of nothing.

local ROOT = arg[1] or "."
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DFOverlay_Server: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
require = function() return true end
print = function() end

local started
Events = { OnServerStarted = { Add = function(fn) started = fn end } }

local clock = 5000
RDShared = { DIR = "RFTD/", EXT_DOC = ".json.txt", nowMs = function() return clock end }

-- A stand-in for Core's store. RDConfigStore is ours and has its own fixture,
-- so what matters here is the INTERACTION: that a write is followed by a
-- touchDefs (an unmirrored layout is lost on a hard kill), and that `held` is
-- read through report() rather than off the store's internals.
local touched, heldDefs = 0, nil
local imported, discarded = 0, 0
local fakeStore = {
    _defs = {},
    boot      = function() end,
    defs      = function(self) return self._defs end,
    touchDefs = function() touched = touched + 1; return true end,
    report    = function() return { heldDefs = heldDefs } end,
    import    = function() imported = imported + 1; heldDefs = nil; return true end,
    discard   = function() discarded = discarded + 1; heldDefs = nil; return true end,
}
local storeSpec
RDConfigStore = { new = function(spec) storeSpec = spec; return fakeStore end }

-- Capabilities, per player, as a set of names.
local caps = {}
RDAccess = {
    roleHas = function(player, capability)
        local held = player and caps[player.name]
        return (held and held[capability]) == true
    end,
}

local audits = {}
DFCore = {
    MODULE = "RFTDDragonfly",
    hasAnyCapability = function(player)
        local held = player and caps[player.name]
        if not held then return false end
        for _ in pairs(held) do return true end
        return false
    end,
    audit = function(action, player, extra)
        audits[#audits + 1] = tostring(action) .. " " .. tostring(extra)
    end,
}

local staffSends, directSends = {}, {}
RDNet = { sendStaff = function(_, command, args)
    staffSends[#staffSends + 1] = { command = command, args = args }
end }
function sendServerCommand(player, _, command, args)
    directSends[#directSends + 1] = { to = player.name, command = command, args = args }
end

local handlers = {}
DFServer = { registerHandler = function(spec) handlers[spec.action] = spec end }

local function player(name, capList)
    caps[name] = {}
    for _, c in ipairs(capList or {}) do caps[name][c] = true end
    return { name = name, getUsername = function(self) return self.name end }
end

-- ---- load ----------------------------------------------------------------

DFOverlay = nil
local okO, errO = pcall(dofile, DIR .. "/shared/DFOverlay.lua")
check(okO, "DFOverlay loads: " .. tostring(errO))

DFOverlay_Server = nil
local ok, err = pcall(dofile, DIR .. "/server/DFOverlay_Server.lua")
check(ok, "module loads: " .. tostring(err))

-- Registration is deferred: DFServer.lua sorts AFTER this file in the server's
-- own tier walk, so a handler registered at file scope would index a nil.
check(started ~= nil, "registration was not deferred to OnServerStarted")
check(handlers.layoutSet == nil,
    "a handler registered at file scope, where DFServer does not exist yet")
started()
check(handlers.layoutGet and handlers.layoutSet and handlers.layoutRecover,
    "not every handler registered")

-- Defs-only: the store must be built with no stateFile at all. A layout has no
-- hot half, and an empty state document trips the foreign hold after a wipe.
check(storeSpec ~= nil, "no store was constructed")
check(storeSpec.stateFile == nil,
    "the layout store asked for a state document it will never write into")
check(tostring(storeSpec.defsFile):sub(-4) == ".txt",
    "the defs file does not end .txt - getFileWriter refuses anything outside "
    .. "the allowlist and returns nil SILENTLY: " .. tostring(storeSpec.defsFile))

-- ---- the store, directly -------------------------------------------------

local okSet, kept, dropped = DFOverlay_Server.set("RFTDDirge", { "A", "B", 7 }, "Kriegan")
check(okSet == true and kept == 2, "set reported " .. tostring(okSet) .. "/" .. tostring(kept))
check(dropped == 1, "a malformed entry was not counted as dropped")
check(touched == 1, "a stored layout was not mirrored - a hard kill loses it")

local rec = DFOverlay_Server.get("RFTDDirge")
check(rec ~= nil and #rec.entries == 2, "the layout did not come back")
check(rec.by == "Kriegan", "the layout did not record who wrote it")
check(rec.atMs == 5000, "the layout did not record when")

-- The reset. Empty means "no layout", which is the same state as never having
-- arranged the page, so the record goes away rather than becoming an empty one.
DFOverlay_Server.set("RFTDDirge", {}, "Kriegan")
check(DFOverlay_Server.get("RFTDDirge") == nil,
    "an empty layout was STORED as an empty list - now there are two ways to "
    .. "say 'no layout' and the document grows a key per change of mind")
check(touched == 2, "clearing a layout was not mirrored")

check(DFOverlay_Server.set("has space", { "A" }, "K") == false, "a bad key was stored")
check(DFOverlay_Server.get("has space") == nil, "a bad key was read back")

-- ---- authority: the crossed pairs ---------------------------------------

local sandboxOnly = player("Sandy", { "SandboxOptions" })
local serverOnly  = player("Sergei", { "ChangeAndReloadServerOptions" })
local nobody      = player("Nobody", {})

local function setAs(who, key)
    return handlers.layoutSet.run(who, { key = key, entries = { "A", "B" } })
end

check(setAs(sandboxOnly, "RFTDDirge").ok == true,
    "a role holding Capability.SandboxOptions could not arrange a sandbox page")
check(setAs(sandboxOnly, "__server").ok == false,
    "A SANDBOX-ONLY ROLE REARRANGED THE SERVER PAGE. The engine gates the "
    .. "server options screen on ChangeAndReloadServerOptions and this endpoint "
    .. "must gate on the same thing - the dispatcher is NOT carrying this check")
check(setAs(serverOnly, "__server").ok == true,
    "a role holding ChangeAndReloadServerOptions could not arrange the server page")
check(setAs(serverOnly, "RFTDDirge").ok == false,
    "a server-options-only role rearranged a sandbox page")
check(setAs(nobody, "RFTDDirge").ok == false, "a role with no capability wrote a layout")
check(setAs(nobody, "__server").ok == false, "a role with no capability wrote the server page")

-- A refused write must not have reached the store at all.
DFOverlay_Server.set("RFTDNecro", {}, "K")
local beforeTouch = touched
handlers.layoutSet.run(nobody, { key = "RFTDNecro", entries = { "A" } })
check(touched == beforeTouch, "a refused write still touched the store")
check(DFOverlay_Server.get("RFTDNecro") == nil, "a refused write still stored a layout")

check(handlers.layoutSet.run(sandboxOnly, { key = "bad key!", entries = {} }).ok == false,
    "a bad page key was accepted by the handler")
check(handlers.layoutSet.run(sandboxOnly, {}).ok == false, "a missing key was accepted")

-- The dispatcher is deliberately given NO capability for these actions, because
-- the right gate depends on the payload. Pinned so that a later change which
-- adds one - and thereby picks the wrong single answer for half the pages -
-- has to come past this line.
check(handlers.layoutSet.capability == nil,
    "layoutSet grew a dispatcher capability; one name cannot express a gate "
    .. "that differs per page")
check(handlers.layoutGet.capability == nil, "layoutGet grew a dispatcher capability")

-- ---- reads ---------------------------------------------------------------

check(handlers.layoutGet.run(nobody, { key = "RFTDDirge" }).ok == false,
    "a non-staff caller could make the server do work")

directSends = {}
check(handlers.layoutGet.run(sandboxOnly, { key = "RFTDDirge" }).ok == true,
    "a staff read was refused")
check(#directSends == 1, "the read sent " .. #directSends .. " messages, expected 1")
check(directSends[1].command == "AdminLayout", "the read replied with the wrong command")
check(directSends[1].args.key == "RFTDDirge", "the reply did not name its page")
check(#directSends[1].args.entries == 2, "the reply carried no layout")

-- ONE PAGE PER MESSAGE. The whole document has no bound worth relying on -
-- ten pages at MAX_ENTRIES is not a ClientCommand - so a reply carrying more
-- than the page that was asked for is the defect, not an optimisation.
check(directSends[1].args.pages == nil,
    "the reply carried the whole document rather than the one page asked for")

-- ---- the broadcast -------------------------------------------------------
-- Everyone including the sender, by the same path, so there is one receive
-- route on the client and no confirmation branch that could disagree with it.

staffSends = {}
audits = {}
local res = handlers.layoutSet.run(sandboxOnly,
    { key = "RFTDDirge", entries = { "A", { h = "Tuning" }, "B", true } })
check(res.ok == true, "the write was refused")
check(#staffSends == 1, "the write broadcast " .. #staffSends .. " times, expected 1")
check(staffSends[1].command == "AdminLayout", "the broadcast used the wrong command")
check(staffSends[1].args.key == "RFTDDirge", "the broadcast did not name its page")
check(#staffSends[1].args.entries == 3, "the broadcast carried the wrong layout")
check(#audits == 1 and audits[1]:find("dropped=1", 1, true) ~= nil,
    "a partly-refused payload was accepted without saying so - the client and "
    .. "the server now hold different layouts and nobody can tell: "
    .. table.concat(audits, " | "))

-- ---- the hold ------------------------------------------------------------
-- After a wipe the file outlives the world that wrote it, so the store refuses
-- to read it AND refuses to overwrite it. That state must reach the panel, and
-- there must be a way out of it that is not a server console.

check(handlers.layoutRecover.run(serverOnly, { take = true }).ok == false,
    "recover ran with nothing held")

heldDefs = "foreign"
directSends = {}
handlers.layoutGet.run(sandboxOnly, { key = "RFTDDirge" })
check(directSends[1].args.held == "foreign",
    "a held store looks identical to a healthy one from the panel - the admin "
    .. "sees reflected order with a good layout sitting unread on disk")

check(handlers.layoutRecover.run(sandboxOnly, { take = true }).ok == false,
    "recover replaces EVERY page's layout, so it must want the stricter "
    .. "capability, not either one")
check(imported == 0, "the refused recover imported anyway")

staffSends = {}
check(handlers.layoutRecover.run(serverOnly, { take = true }).ok == true,
    "recover was refused for a role that holds the capability")
check(imported == 1, "recover did not import")
check(#staffSends == 1 and staffSends[1].command == "AdminLayoutStale",
    "recover did not tell the panels their copies are wrong - every admin "
    .. "would keep drawing the layout that was just replaced")

heldDefs = "corrupt"
check(handlers.layoutRecover.run(serverOnly, { take = false }).ok == true,
    "discard was refused")
check(discarded == 1, "discard did not reach the store")

print = realPrint
print(string.format("DFOverlay_Server: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
