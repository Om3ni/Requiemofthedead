-- DFLayout fixture - the client's copy of the layout overlay.
--
-- WHAT IS AT RISK here is not data, it is the panel telling an admin something
-- untrue about a live server. Three specific ways, all of them silent:
--
--   1. An optimistic cache. If saving wrote the local copy instead of waiting
--      for the server's push, a write the server REFUSED would leave this panel
--      showing a layout that exists nowhere else - and the admin would keep
--      arranging around an arrangement nobody else can see.
--   2. A stranded request. `asked` stops a redraw sending sixty requests a
--      second, and it is exactly the flag that pins a page forever if the reply
--      never arrives. Something has to clear it.
--   3. A missing note. A held store, or a page that has grown options since it
--      was arranged, both look EXACTLY like a normal page from the outside. The
--      note line is the whole of the observability here, so it is tested as
--      behaviour rather than as decoration.
--
-- The real DFOverlay is loaded rather than stubbed - it is pure Lua, and shape()
-- is a one-line delegate whose entire value is that it passes the right things.

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFLayout: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return false end
require = function() return true end
DFKit = {}
DFCore = { MODULE = "RFTDDragonfly" }
function getPlayer() return { name = "me" } end

local sent = {}
function sendClientCommand(_, _, command, args)
    sent[#sent + 1] = { command = command, args = args }
end

local receiver
Events = { OnServerCommand = { Add = function(fn) receiver = fn end } }

DFOverlay = nil
local okO, errO = pcall(dofile, BASE .. "/shared/DFOverlay.lua")
check(okO, "DFOverlay loads: " .. tostring(errO))

DFLayout = nil
local ok, err = pcall(dofile, BASE .. "/client/Admin/DFLayout.lua")
check(ok, "module loads: " .. tostring(err))
check(receiver ~= nil, "no OnServerCommand listener was registered")

-- ---- requesting ----------------------------------------------------------

sent = {}
check(DFLayout.request("RFTDDirge") == true, "the first request was not sent")
check(#sent == 1 and sent[1].command == "layoutGet", "the wrong command went out")
check(sent[1].args.key == "RFTDDirge", "the request did not name its page")

check(DFLayout.request("RFTDDirge") == false, "a second request went out while one was in flight")
check(#sent == 1,
    "a request repeated - rebuildForm runs on every click and draw runs sixty "
    .. "times a second, so an unguarded request is a flood")

check(DFLayout.request("has space") == false, "an invalid key was sent to the server")
check(DFLayout.request(nil) == false, "a nil key was sent")
check(#sent == 1, "an invalid key reached the wire")

-- ---- receiving -----------------------------------------------------------

check(DFLayout.receive("AdminLayout",
    { key = "RFTDDirge", entries = { "A", { h = "T" } }, by = "Kriegan", atMs = 9 }) == true,
    "a layout push was not accepted")
check(#DFLayout.entriesFor("RFTDDirge") == 2, "the layout did not land in the cache")
check(DFLayout.recordFor("RFTDDirge").by == "Kriegan", "the writer was not kept")
check(DFLayout.entriesFor("RFTDNecro") == nil, "an unrequested page has a layout")

check(DFLayout.receive("SomethingElse", {}) == false, "an unrelated command was consumed")
check(DFLayout.receive("AdminLayout", {}) == false, "a push with no key was accepted")

-- Having it cached stops the request too, not just the in-flight flag.
sent = {}
check(DFLayout.request("RFTDDirge") == false, "a cached page was re-requested")
check(#sent == 0, "a cached page reached the wire")

-- ---- listeners -----------------------------------------------------------

local fired = {}
DFLayout.onChanged(function(key) fired[#fired + 1] = tostring(key) end)
DFLayout.receive("AdminLayout", { key = "RFTDNecro", entries = { "N" } })
check(#fired == 1 and fired[1] == "RFTDNecro", "the view was not told a layout arrived")

-- Stale drops EVERYTHING, because a recover replaces the whole document and
-- there is no page-shaped correction to send.
fired = {}
check(DFLayout.receive("AdminLayoutStale", {}) == true, "the stale push was ignored")
check(DFLayout.entriesFor("RFTDDirge") == nil, "a stale push left a page cached")
check(DFLayout.entriesFor("RFTDNecro") == nil, "a stale push left another page cached")
check(#fired == 1 and fired[1] == "nil",
    "the stale push did not signal 'every page' - a view filtering on its own "
    .. "key would never rebuild and would draw the replaced layout forever")

sent = {}
check(DFLayout.request("RFTDDirge") == true, "a forgotten page was not re-requested")

-- ---- the stranded request ------------------------------------------------
-- The reply never comes: refused read, disconnect mid-request. Without a way
-- to clear `asked` that page never asks again for the rest of the session.

sent = {}
DFLayout.forget("RFTDDirge")
check(DFLayout.request("RFTDDirge") == true,
    "forget() did not clear the in-flight flag - a page whose reply was lost "
    .. "would never ask again, and the panel would draw reflected order for "
    .. "the rest of the session with no indication anything went wrong")
check(#sent == 1, "the retry did not reach the wire")

-- ---- saving is never optimistic -----------------------------------------

DFLayout.forget()
sent = {}
check(DFLayout.save("RFTDDirge", { "A", "B" }) == true, "the save was not sent")
check(sent[1].command == "layoutSet", "the wrong command went out")
check(sent[1].args.key == "RFTDDirge" and #sent[1].args.entries == 2,
    "the save did not carry its payload")
check(DFLayout.entriesFor("RFTDDirge") == nil,
    "SAVING WROTE THE LOCAL CACHE. The server may refuse the write, and this "
    .. "panel would then show a layout that exists nowhere else. The push that "
    .. "comes back is the confirmation, and it is the only one.")

check(DFLayout.save("bad key!", {}) == false, "an invalid key was sent to the server")

sent = {}
DFLayout.recover(true)
check(sent[1].command == "layoutRecover" and sent[1].args.take == true,
    "recover did not send its intent")
DFLayout.recover(false)
check(sent[2].args.take == false, "discard was sent as an import")

-- ---- shape ---------------------------------------------------------------

local function opt(n) return { name = n, short = n, label = n, type = "boolean" } end
local function page()
    return { page = "RFTDDirge", label = "Dirge", count = 3,
             sections = { { title = nil, options = { opt("A"), opt("B"), opt("C") } } } }
end

DFLayout.forget()
local p = page()
local shaped, stats = DFLayout.shape(p)
check(shaped == p,
    "an unarranged page was rebuilt rather than passed through - the common "
    .. "case must not be able to differ from the model by any amount")
check(stats.added == 0, "an unarranged page reported drift")

DFLayout.receive("AdminLayout", { key = "RFTDDirge", entries = { "C" } })
local shaped2, stats2 = DFLayout.shape(page())
local names = {}
for _, sec in ipairs(shaped2.sections) do
    for _, o in ipairs(sec.options) do names[#names + 1] = o.name end
end
check(table.concat(names, ",") == "A,B,C", "shape did not apply the layout: "
    .. table.concat(names, ","))
check(stats2.added == 2, "shape lost the fall-through count")
check(DFLayout.shape(nil) == nil, "shape(nil) invented a page")

-- ---- the note ------------------------------------------------------------
-- Everything below is a state in which the panel is showing something OTHER
-- than what the admin arranged. Each one looks completely normal without this.

DFLayout.forget()
check(DFLayout.noteFor("RFTDDirge", { added = 0, stale = 0 }) == nil,
    "a healthy page said something")

DFLayout.receive("AdminLayout", { key = "RFTDDirge", entries = { "C" }, held = "foreign" })
local heldNote = DFLayout.noteFor("RFTDDirge", { added = 2, stale = 0 })
check(heldNote ~= nil and heldNote:find("NOT been loaded", 1, true),
    "A HELD STORE SAID NOTHING. After a wipe the layout file is on disk, "
    .. "unread and unwritable, and the panel is drawing reflected order - "
    .. "which is indistinguishable from 'nobody ever arranged this page'.")
check(DFLayout.held("RFTDDirge") == "foreign", "the hold did not reach the view")

DFLayout.receive("AdminLayout", { key = "RFTDDirge", entries = { "C" }, held = "corrupt" })
check(tostring(DFLayout.noteFor("RFTDDirge", {})):find("decode", 1, true),
    "a corrupt layout file was not reported")

DFLayout.receive("AdminLayout", { key = "RFTDDirge", entries = { "C" } })
local added = DFLayout.noteFor("RFTDDirge", { added = 3, stale = 0 })
check(added ~= nil and added:find("3 option", 1, true),
    "options the layout has never seen were not reported - this is the only "
    .. "signal an admin gets that the page grew since they arranged it")

-- ...but only when there IS a layout. Every option on an unarranged page is
-- "unplaced", and saying so about a page nobody has touched is noise that
-- teaches an admin to ignore the line.
DFLayout.forget()
check(DFLayout.noteFor("RFTDDirge", { added = 9, stale = 0 }) == nil,
    "an unarranged page reported all of its options as unplaced")

DFLayout.receive("AdminLayout", { key = "RFTDDirge", entries = { "C" } })
check(tostring(DFLayout.noteFor("RFTDDirge", { added = 0, stale = 1 })):find("1 entry", 1, true),
    "a layout entry naming an option that no longer exists was not reported")
check(tostring(DFLayout.noteFor("RFTDDirge", { added = 0, stale = 2 })):find("2 entries", 1, true),
    "the stale count did not agree with itself grammatically")

print(string.format("DFLayout: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
