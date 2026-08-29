-- test_dmaudit.lua - which of the kit record's three sinks each action reaches.
--
-- WHY THIS EXISTS. DMAudit fans one call out to three places with different
-- rules, and every way of getting it wrong is silent:
--
--   * An event that is not registered in RDEvents is REJECTED by
--     RDLog.chronicle with a console line and nothing else. A typo in
--     chronicleEvent therefore loses the permanent record while the forensic
--     archive keeps working, so nothing looks broken until someone goes
--     looking for a claim a month later.
--   * latest.json.txt is the recovery point - what this player last actually
--     received. Any event allowed to overwrite it replaces that answer with
--     something else. Memoir hit exactly this in reverse, with admin restores
--     overwriting the write they were restoring.
--   * The subject decides WHOSE folder a record lands in, and on a staff grant
--     the actor and the subject are different people.
--   * The bound on both permanent sinks is that refusals never reach them.
--     KIT_CLAIM_REFUSED fires whenever a player clicks a kit they cannot have.
--
-- None of that is visible by reading: they are questions about which writer got
-- called with what. So RDLog and getFileWriter are stubbed and every call is
-- captured.
--
-- RDShared is loaded FOR REAL rather than hand-stubbed, because the pipe
-- timeline's escaping is its textSafe and a re-implementation here would be a
-- copy free to drift from the thing under test.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dmaudit.lua <repo-root>

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua"
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster"
    .. "/42/media/lua/server/Kits/DMAudit.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end

-- ---------------------------------------------------------------------------
-- Engine + Core stubs. Nothing is written and nothing is sent.
-- ---------------------------------------------------------------------------

require   = function() end
isServer  = function() return true end
isClient  = function() return false end
Events    = setmetatable({}, { __index = function(t, k)
    local e = { Add = function() end }; rawset(t, k, e); return e
end })

function getTimestamp() return 1785000000 end
function getTimestampMs() return 1785000000000 end
function getGameTime()
    return { getWorldAgeHours = function() return 72.0 end }   -- day 3.00
end

dofile(CORE)   -- the real RDShared: EXT_STREAM/EXT_DOC, textSafe, username

-- RDJson: the shape matters, not the encoding. A marker string is enough to
-- prove the record reached a file, and keeps this fixture from asserting on
-- RDJson's key order (test_rdjson owns that).
local encoded = nil
RDJson = { encode = function(t) encoded = t; return "<json>" end }

local registered = nil
RDEvents = {
    SCHEMA_V = 2,
    registerNamespace = function(prefix, mod, events)
        registered = { prefix = prefix, mod = mod, events = events }
        return true
    end,
}

local forensics, chronicles = {}, {}
RDLog = {
    forensic  = function(stream, evt, subj, payload, modId)
        forensics[#forensics + 1] = { stream = stream, evt = evt, subj = subj,
                                      payload = payload, mod = modId }
    end,
    chronicle = function(evt, subj, payload)
        chronicles[#chronicles + 1] = { evt = evt, subj = subj, payload = payload }
        return true
    end,
}

-- dirFor is the reason a subject must be an object where one exists: with a
-- string it can only mint a SteamID-less name. The stub models exactly that, so
-- a record filed under the wrong person shows up as the wrong DIRECTORY.
RDIdentity = {
    dirFor = function(subj)
        local n = RDShared.username(subj) or "unknown"
        if type(subj) == "table" and subj.sid then return n .. "." .. subj.sid end
        return n
    end,
}

local writes = {}
local refuseAll = false
function getFileWriter(path, _createIfNull, append)
    if refuseAll then return nil end
    return {
        write = function(_, s)
            writes[#writes + 1] = { path = path, line = s, append = append }
        end,
        close = function() end,
    }
end

local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s) end

-- The REAL RDFile (write mechanism since 2026-08-25).
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDFile.lua")
local okLoad, err = pcall(dofile, SRC)
print = realPrint
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

-- ---------------------------------------------------------------------------
-- Helpers over the capture
-- ---------------------------------------------------------------------------

local function reset() forensics, chronicles, writes, encoded = {}, {}, {}, nil end

local function wroteTo(suffix)
    for _, w in ipairs(writes) do
        if w.path:sub(-#suffix) == suffix then return w end
    end
    return nil
end

local function player(name, sid)
    return { sid = sid, getUsername = function() return name end }
end

local OMEN  = player("Omen", "76561198000000001")
local STAFF = player("StaffMember", "76561198000000002")

-- ---------------------------------------------------------------------------
-- 1. The closed enum. An unregistered event is silently rejected at write time.
-- ---------------------------------------------------------------------------

ok("the DM namespace was claimed at load", registered ~= nil)
eq("under the mod that owns it", registered and registered.mod, "RFTDDungeonMaster")
eq("with the DM prefix", registered and registered.prefix, "DM")

-- THE ONE THAT MATTERS: every event chronicleEvent can hand to RDLog must be in
-- the registry, or that write is dropped with nothing but a console line. This
-- catches a typo on either side of the pair, which no other assertion here can.
local ACTIONS = {
    { "KIT_CLAIMED", {} },
    { "KIT_CLAIMED", { by = "StaffMember" } },
    { "KIT_CLAIM_CLEARED", { by = "StaffMember" } },
    { "KIT_REOPENED", { by = "StaffMember" } },
}
for _, a in ipairs(ACTIONS) do
    local evt = DMAudit.chronicleEvent(a[1], a[2])
    local name = tostring(evt):match("^DM%.(.+)$")
    ok("EVERY CHRONICLE EVENT IS REGISTERED: " .. tostring(evt),
       name ~= nil and registered.events[name] ~= nil,
       "RDLog.chronicle rejects an unregistered event and the record is lost")
end

eq("re-opening is world-scope - it is about a kit, not a player",
   registered.events.KIT_REOPENED.scope, "w")
eq("a claim is per-player", registered.events.KIT_CLAIMED.scope, "p")
eq("a grant is per-player", registered.events.KIT_GRANTED.scope, "p")
eq("a cleared claim is per-player", registered.events.KIT_CLEARED.scope, "p")

-- ---------------------------------------------------------------------------
-- 2. chronicleEvent - the split, and the bound.
-- ---------------------------------------------------------------------------

eq("a self-claim chronicles as a claim",
   DMAudit.chronicleEvent("KIT_CLAIMED", {}), "DM.KIT_CLAIMED")
eq("THE SAME ACTION WITH AN ADMIN BEHIND IT IS A GRANT - the forensic name "
   .. "cannot say so and `by` is what already can",
   DMAudit.chronicleEvent("KIT_CLAIMED", { by = "StaffMember" }), "DM.KIT_GRANTED")
eq("clearing one player's claim", DMAudit.chronicleEvent("KIT_CLAIM_CLEARED", {}),
   "DM.KIT_CLEARED")
eq("re-opening a kit", DMAudit.chronicleEvent("KIT_REOPENED", {}), "DM.KIT_REOPENED")

-- The bound on both permanent sinks. A player produces refusals on demand by
-- clicking, so nothing that is never rotated may accept them.
for _, action in ipairs({ "KIT_CLAIM_REFUSED", "KIT_DEFINE_REFUSED",
                          "KIT_GRANT_FAILED", "KIT_DEFINED", "KIT_DELETED" }) do
    eq(action .. " stays forensic-only", DMAudit.chronicleEvent(action, {}), nil)
end

-- ---------------------------------------------------------------------------
-- 3. A refusal: the archive takes it, nothing permanent does.
-- ---------------------------------------------------------------------------

reset()
DMAudit.log("KIT_CLAIM_REFUSED", OMEN, { kit = "anomaly", reason = "cooling" })

eq("the archive still gets the refusal", #forensics, 1)
eq("under Core's kits stream", forensics[1].stream, "kits")
eq("namespaced on the wire", forensics[1].evt, "DM.KIT_CLAIM_REFUSED")
eq("attributed to the producing mod", forensics[1].mod, "RFTDDungeonMaster")
eq("A REFUSAL NEVER REACHES THE CHRONICLE", #chronicles, 0)
eq("and never touches the Kits tree", #writes, 0)

-- ---------------------------------------------------------------------------
-- 4. A self-claim: all three sinks, and the recovery point moves.
-- ---------------------------------------------------------------------------

reset()
DMAudit.log("KIT_CLAIMED", OMEN, { kit = "anomaly", kind = "item", landed = 2 })

eq("the archive has it", #forensics, 1)
eq("the chronicle has it", #chronicles, 1)
eq("as a claim, not a grant", chronicles[1].evt, "DM.KIT_CLAIMED")
ok("THE CHRONICLE GETS THE OBJECT, NOT A NAME - only an object carries the "
   .. "life id and mints a SteamID-bearing directory",
   chronicles[1].subj == OMEN)

local ev = wroteTo("Omen.76561198000000001/events.jsonl.log")
ok("the player's own history was appended", ev ~= nil,
   "paths: " .. tostring(#writes))
eq("history appends, never truncates", ev and ev.append, true)

local la = wroteTo("Omen.76561198000000001/latest.json.txt")
ok("the recovery point moved", la ~= nil)
eq("the recovery point is REWRITTEN, not appended - it is one record, the "
   .. "latest, and appending would make it a second history",
   la and la.append, false)

ok("the record carries the action", encoded and encoded.action == "KIT_CLAIMED")
ok("and the payload merged over the envelope", encoded and encoded.kit == "anomaly")
ok("and the schema version", encoded and encoded.v == DMAudit.SCHEMA_V)

ok("the slim timeline got a line", wroteTo("Kits/_all.log") ~= nil)

-- ---------------------------------------------------------------------------
-- 5. A staff grant. THE REGRESSION THIS FILE EXISTS FOR: the record is about
--    the recipient, and the caller is holding two different people.
-- ---------------------------------------------------------------------------

reset()
DMAudit.log("KIT_CLAIMED", OMEN, { kit = "event", by = "StaffMember", landed = 1 })

eq("an admin grant chronicles as a grant", chronicles[1].evt, "DM.KIT_GRANTED")
ok("FILED UNDER THE RECIPIENT, NOT THE ADMIN",
   wroteTo("Omen.76561198000000001/events.jsonl.log") ~= nil,
   "a grant filed under the actor writes half of every grant into the wrong "
   .. "player's permanent record")
eq("and nothing lands under the admin",
   wroteTo("StaffMember.76561198000000002/events.jsonl.log"), nil)
ok("the responsible admin is still in the record", encoded.by == "StaffMember")

-- ---------------------------------------------------------------------------
-- 6. Clearing one player's claim: history yes, recovery point NO.
-- ---------------------------------------------------------------------------

reset()
DMAudit.log("KIT_CLAIM_CLEARED", "Omen", { kit = "anomaly", by = "StaffMember",
                                           had = true })

eq("it is a permanent fact", chronicles[1].evt, "DM.KIT_CLEARED")
ok("the player's history records it",
   wroteTo("Omen/events.jsonl.log") ~= nil)
eq("A CLEARED CLAIM MUST NOT MOVE THE RECOVERY POINT - it would replace what "
   .. "the player last RECEIVED with the fact an admin let them try again",
   wroteTo("Omen/latest.json.txt"), nil)
ok("an offline subject still works - the whole point of the command",
   chronicles[1].subj == "Omen")

-- ---------------------------------------------------------------------------
-- 7. Re-opening a kit: no single player, so no per-player file.
-- ---------------------------------------------------------------------------

reset()
DMAudit.log("KIT_REOPENED", STAFF, { kit = "event", by = "StaffMember", cleared = 7 })

eq("it is a permanent fact", chronicles[1].evt, "DM.KIT_REOPENED")
eq("NOTHING LANDS IN THE ADMIN'S FOLDER - re-opening clears every claim on the "
   .. "kit, so it is about the one person it is not about",
   wroteTo("StaffMember.76561198000000002/events.jsonl.log"), nil)
ok("the slim timeline still carries it", wroteTo("Kits/_all.log") ~= nil)
eq("exactly one file was written", #writes, 1)

-- ---------------------------------------------------------------------------
-- 8. The pipe timeline. Its delimiter is inside values it does not control.
-- ---------------------------------------------------------------------------

local line = DMAudit.pipeLine(1785000000, 3.0, "KIT_CLAIMED", "Omen",
                              { kit = "anomaly", landed = 2 })
eq("stamp, day, action and user lead, in that order",
   line:match("^(%d+)|([%d%.]+)|(%u[%u_]+)|user=Omen") ~= nil, true)
ok("payload keys are sorted, so two identical states render identically",
   line:find("|kit=anomaly|landed=2", 1, true) ~= nil, line)

-- A newline forges a whole extra line attributed to whoever it names, and a
-- pipe forges a field. Both arrive from an authored catalogue and a grant
-- report, so both are escaped rather than trusted.
local nasty = DMAudit.pipeLine(1, 1.0, "KIT_CLAIMED", "Omen",
                               { summary = "axe\nuser=Someone|kit=jackpot" })
eq("a newline in a value cannot start a second line",
   nasty:find("\n", 1, true), nil)
eq("and the delimiter itself cannot be smuggled in",
   nasty:find("|kit=jackpot", 1, true), nil)
ok("both are visible rather than dropped - two payloads must not print alike",
   nasty:find("\\x0A", 1, true) ~= nil and nasty:find("\\x7C", 1, true) ~= nil,
   nasty)

-- ---------------------------------------------------------------------------
-- 9. A refused write is counted and said once, not once per line.
-- ---------------------------------------------------------------------------

reset()
printed = {}
local before = DMAudit.writeFailures()
refuseAll = true
print = function(s) printed[#printed + 1] = tostring(s) end
DMAudit.log("KIT_CLAIMED", OMEN, { kit = "anomaly" })
DMAudit.log("KIT_CLAIMED", OMEN, { kit = "anomaly" })
print = realPrint
refuseAll = false

ok("every refused write is counted", DMAudit.writeFailures() - before >= 4,
   "counted " .. tostring(DMAudit.writeFailures() - before))
-- Six, not three, since 2026-08-25: RDFile (the shared mechanism) shouts
-- once per path as the suite-wide floor, and DMAudit's own per-sink message
-- rides on top. Two voices, each once - the property is still no-flood, and
-- the second write producing ZERO new lines is what proves it.
eq("BUT SAID ONCE PER PATH - a full disk refuses the next write too, and a "
   .. "line each turns that into a flood that hides everything else",
   #printed, 6)
eq("the archive is unaffected by a file refusal", #forensics, 2)

print(string.format("DMAudit: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
