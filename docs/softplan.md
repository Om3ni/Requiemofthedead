> ## ⚠ 42.20 ERRATUM - added 2026-07-29, read before trusting any engine citation below
>
> This document is part working transcript (down to "# The goal"), part authoritative spec
> (from "# The goal" onward). The transcript half is a HISTORICAL RECORD and has been left
> exactly as written, typos and stale line numbers included - do not "correct" it. The spec
> half has been updated in place.
>
> Three things below are now wrong, all from PZ **42.20** (released 2026-07-29):
>
> 1. **`getFileWriter` refuses most extensions.** Since 42.20 it returns **nil** unless the
>    extension is in `Set.of("ini","cfg","txt","log")` (LuaManager.java:9884, gate at :5514).
>    This set does not exist in 42.19.1. It killed every `.jsonl`/`.json`/`.tsv` write in the
>    family SILENTLY, because our writers all guard `if w then` - so pcall never errored and
>    `RDLog.chronicle` kept returning true. Live outage 2026-07-29.
> 2. **File names changed as a result.** `events.jsonl` → `events.jsonl.log`,
>    `latest.json` → `latest.json.txt`, `slugs.tsv` → `slugs.tsv.log`, `schema.json` →
>    `schema.json.txt`, ring segments → `NNN.jsonl.log`. `getFileExtension()` reads after the
>    LAST dot, so the compound name passes the gate while still declaring its real format.
>    Canonical definition: `RDShared.EXT_STREAM` (append-only) / `RDShared.EXT_DOC`
>    (rewritten). Pre-42.20 files are never migrated - reads are ungated, so they stay on
>    disk as history and readers fall back to them.
> 3. **Line numbers drifted.** `getFileWriter` moved :5445 → :5512. Every other engine
>    citation in this file predates 42.20 and has NOT been systematically re-checked; the
>    only tree that was is §1/§9 of `dirge-dormant-persistence-plan.md`. Current decompile:
>    `PZ_Engine_Decompiled_42.20.0-a2947723ca` (rebuild via `tools/decompile-engine.ps1`).

I feel like we shoudl refine our logging a little bit. 

What would you say to Reclamations own subfolder in LUA. In that folder we break it down per player who claims a vehicle. 

And within that folder we break it down to current claims - past claims. In current claims we keep their current vehicle data. Including all the things we otherwise log. Entry/exit/damage/who is driving, where they started, where they stopped, etc, if they removed parts. 

Each log is a snapshot of 1 vehicle over time. When a restart happens, or when the log hits n size we save it and start a new one. Old logs are saved per day
Show less
Before the design question - I found why it truncates, and it's not a design gap. It's a one-word bug.

The engine signature is getFileWriter(String filename, boolean createIfNull, boolean append) (LuaManager.java:5445). Both Reclamation audit writers pass (FILE, true, false) - that's createIfNull=true, append=**false**, with a comment next to it claiming append=true. Every call opens the file in truncate mode, writes one line, and closes. The file has only ever held the single most recent event.

Your other mods get it right - OSNLog, GuardianLogger, RQReflectLog, and BXServer all pass (FILE, true, true), with BoonBox even commenting "createIfNull, append (never truncate)". Reclamation's two audit writers are the only outliers. Fixing that now, since it's losing data independently of anything we redesign:

Edit RCAudit.lua
Modified
Edit RCDamageAudit.lua
Modified
Bash Run Lua syntax gate over mod trees
IN
cd "c:/VSCodeProjects/PZMod" && cmd /c tools\\check-lua.bat 2>&1 | tail -15

OUT
Microsoft Windows [Version 10.0.26200.8875]
(c) Microsoft Corporation. All rights reserved.

C:\VSCodeProjects\PZMod>
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
PowerShell Run Lua syntax gate
IN
& "C:\VSCodeProjects\PZMod\tools\check-lua.bat" 2>&1 | Select-Object -Last 12

OUT
All mod lua trees parse clean.
Syntax gate passes. Now, on the redesign.

First: that changes what you're fixing
The ledger design was sound - it just never appended. Worth deciding the new structure on its own merits rather than as a remedy for truncation, because the truncation is now gone either way. What you don't get back is history: everything before this fix is unrecoverable, so the Moa/Samothy question can't be settled from the ledger no matter what we build. Going forward it accumulates.

What I'd keep from your proposal
The subfolder, the per-vehicle timeline, and rotation on size are all right. getFileWriter runs File.mkdirs() on the full parent chain, so nested directories are free - Dragonfly's MMAudit already relies on that, so there's a working precedent in-repo to copy rather than invent.

Where I'd push back
Key the tree by vehicle, not by player. Your own description contains the tension: you said "break it down per player," then "each log is a snapshot of 1 vehicle over time." Those give different trees, and the second one is correct. A vehicle outlives its owners - Samothy's StepVan becoming Moa's StepVan is precisely a chain-of-custody event, and in a player-keyed tree that history splits across two folders with nothing linking the halves. You'd be rebuilding the exact blind spot that started this. The claimId is already stable, owner-independent, and deliberately preserved after unclaim for audit continuity; it's the natural filename.

Keep the player view as a thin index - one line per claim, release, or expiry pointing at a claimId - so "what does Moa own" stays a single file read without duplicating the timeline.

Current/past won't hold the interesting traffic. Fifty-six of Moa's events were on unclaimed cars, which have no owner and therefore no folder in a player-keyed scheme. Most of what you want to watch - someone driving and stripping cars nobody owns - lives outside claims entirely. A vehicle-keyed tree handles it natively; a player-keyed one has nowhere to put it. I'd also drop current-vs-past as directories and let the timeline carry ownership transitions inline, since a car can cycle owners repeatedly and moving files on each transition is a lot of failure surface for a distinction you can derive by reading the last claim event.

The event volume is a different order of magnitude. Claim mutations are rare - a handful a day. Entry/exit, damage, driver changes, positions, and part removals are continuous, and RCAudit does a full open-write-close per line. Crash events off the vanilla vehicle channel alone will dwarf everything the current ledger writes. I'd buffer in RAM and flush on the hourly RCSession pass that Janitor already rides, rather than adding a timer or fsyncing per event. Position tracking especially - "where they started, where they stopped" - should come from the existing sweep's signature sampling, not a new poll.

"Save on restart" is the one part that will fail when it matters. There's no shutdown hook that survives a force-kill, and the restart scripts on that box kill java mid-save - that's the documented cause of the mass data loss. Rotate lazily instead: check size and date at flush time and roll over then. A boot marker line gives you the restart boundary without depending on a clean shutdown.

Mark what's trustworthy. Entry/exit arrives via a client relay, and part removal is client-driven with no Lua veto. If this log is going to settle cheating disputes, each record needs to say whether the server observed it or a client asserted it - otherwise the evidence is forgeable by exactly the person you're investigating.

Switch to one JSON object per line. The current key=value format has a live collision I hit earlier: EXPIRE emits user= twice, once for the actor and once for the subject, and the owner field is variously owner=, user=, or lastUser= depending on the verb. JSONL removes the ambiguity and makes the whole tree consumable by the same Python tooling you already use for the save-file decoders.

The shape I'd recommend

Zomboid/Lua/Reclamation/
  vehicles/RC-1753-4821.jsonl     canonical timeline, spans all owners
  players/MoaKami.jsonl           index: claim/release/expiry -> claimId
  archive/2026-07-25/             rolled by size or date change
with a retention sweep on the hourly pass so the archive doesn't grow without bound.

The one thing I'd genuinely reconsider is scope: this is a decent-sized subsystem, and the vertical-slice rule says build the per-vehicle timeline end-to-end and verify it on the dedi before adding the player index, archiving, and retention. Say the word and I'll start with the timeline alone.

c:\VSCodeProjects\PZMod\Reclamation\Contents\mods\RFTDReclamation\42\media\lua\client\RCUserPanelHook.lua
The reason i wanted per player folders was specificly to make it easier to find what a player has when they submit a ticket, and to give an audit trail of vehicles they've owned over time. 

I've got an idea brewing in the back of my head. An end of season snapshot of their progress in that season 

Here is your life -

Where you started
Your stat progression
Where you chose to call home
The vehicle you made your own
The challenges (deaths/memoirs written and read)
The zombies you've killed
And this is how you died (season end)
That reframes it. Let me look at what Memoirs already has, since "here is your life" sounds like it lands there rather than in Reclamation.

Bash Inspect Memoirs tree and life-id concept
IN
cd "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua" && ls -la server/Memoirs/ && echo "=== life-id / epoch ===" && grep -rn "lifeId\|life_id\|epoch\|LIFE" server/Memoirs/*.lua | head -25

OUT
total 36
drwxr-xr-x 1 micha 197609     0 Jul 25 17:01 .
drwxr-xr-x 1 micha 197609     0 Jul 25 16:53 ..
-rw-r--r-- 1 micha 197609 15848 Jul 25 17:01 MMAudit.lua
-rw-r--r-- 1 micha 197609 12774 Jul 25 17:01 MMRestore.lua
=== life-id / epoch ===
server/Memoirs/MMAudit.lua:19:--                                    <epochSec>|<gameDay>|<EVENT>|user=<name>|k=v...
server/Memoirs/MMAudit.lua:236:--         READ_OWNER / READ_FADED / READ_SAMELIFE / READ_RECALLED / READ_APPLYFAIL /
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
Bash Read MMAudit header and rotation logic
IN
cd "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua" && sed -n '1,60p' server/Memoirs/MMAudit.lua && echo "=== rotation/retention ===" && grep -n "rotate\|MAXSIZE\|MAX_SIZE\|retention\|prune\|os.date\|DIR" server/Memoirs/MMAudit.lua | head -25

OUT
-- MMAudit.lua - Memoir write/read audit trail (server-only, removable).
-- Why: memoir tickets can't be reconstructed from player memory, and the season
-- deserves a record. Every write/read ATTEMPT (refusals included) becomes a
-- SCHEMA'D record (JSONL) so the log is machine-consumable three ways:
--   * a player-facing progression sheet (parse events.jsonl, plot snapshots)
--   * oversight/forensics (full snapshot on every write and successful read)
--   * disaster recovery (snap in the record IS MMSnapshotCodec's snapshot table -
--     feed it back through applyToCharacter to rebuild a character after a wipe
--     or DB corruption; restore command lands as a Players-tab row action)
-- MMServer calls MMAudit.log(...) behind `if MMAudit then` guards, so deleting
-- the Memoirs/ folder disables auditing with no other edit.
--
-- Output (under the server cachedir, Lua/):
--   Memoirs/<SafeName>/events.jsonl  append-only full history, one JSON obj/line
--   Memoirs/<SafeName>/latest.json   newest snapshot-bearing record (overwritten;
--                                    derived convenience - rebuildable from the
--                                    last events.jsonl line; restore reads this)
--   Memoirs/_all.log                 slim human pipe timeline (no heavy payloads):
--                                    <epochSec>|<gameDay>|<EVENT>|user=<name>|k=v...
-- Nested dirs are ENGINE-GUARANTEED: getFileWriter runs File.mkdirs() on the
-- full parent chain (LuaManager.getFileWriter, verified in the 42.19 decompile),
-- and only ".." paths are refused (safeName can't emit dots). The flat fallback
-- below is retained as free insurance only - it should never fire.
--
-- getFileWriter is the ONLY server-side I/O that works in B42 (raw io.open is
-- silently blocked); open-append-close per line, so a hard-killed server loses
-- nothing already logged.
--
-- JSON: hand-rolled encoder - safe because we control every shape (strings,
-- numbers, bools, string-keyed maps, string arrays). Object keys sorted, sets
-- flattened to sorted lists, so identical states encode identically (diffable).

if not isServer() then return end

MMAudit = MMAudit or {}

MMAudit.SCHEMA_V = 1

local DIR = "Memoirs/"

-- ─────────────────────────────────────────────────────────────────────────
-- Small helpers
-- ─────────────────────────────────────────────────────────────────────────

-- filesystem-safe per-player file/dir name (usernames may hold anything)
local function safeName(name)
    name = tostring(name or "unknown")
    return (name:gsub("[^%w%-_]", "_"))
end

-- %.2f then trim keeps Kahlua doubles out of scientific notation (tostring on a
-- large number can yield "1.78E9", which is useless in a log and invalid-ish JSON)
local function fmtNum(n)
    return (string.format("%.2f", n):gsub("%.00$", ""))
end

local function isArray(v)
    local n = 0
    for k in pairs(v) do
        if type(k) ~= "number" then return false end
=== rotation/retention ===
39:local DIR = "Memoirs/"
158:    pcall(function() w = getFileWriter(DIR .. path, true, append) end)
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
Bash Check what the Memoirs snapshot captures
IN
cd "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua" && grep -n "perk\|xp\|Xp\|XP\|trait\|weight\|kill\|hours\|Zombie" shared/MMSnapshotCodec.lua | head -30

OUT
7:--   * OVERWRITE -> applyToCharacter(p, snap, {profession=..., traits=...}, "overwrite")
8:--                  identity/body/faith = snapshot; XP = memoir restore + this life's earnings
13:--   * XP transfer = 5-arg AddXP(type, amount, callLua=false, doXPBoost=false,
14:--     remote=false); doXPBoost=false bypasses every multiplier so the raw number
16:--   * Profession boosts live on SurvivorDesc.xpBoostMap (getPerkBoost reads it live):
17:--     setProfessionSkills(def) = clear()+putAll(boosts); it wipes the WHOLE map. Apply
18:--     order must mirror creation: strip old traits (their boosts subtract from the
19:--     LIVE map), then profession, then add new traits (boosts re-stack on top).
20:--   * A fresh spawn CARRIES raw XP for its granted levels: creation ends with
21:--     setXPToLevel(perk, level) (IsoGameCharacter.applyTraits), so a never-trained
22:--     skill's snapshot XP is pure grant XP - indistinguishable from earned XP unless
24:--   * getPerkBoost()/XPBoostMap is NOT the starting level: creation stores
27:-- THE GRANT RULE: grants follow the build being restored; only earned XP carries, and
28:-- only MEMOIR-earned XP is taxed by the restore knob:
29:--     savedEarned = max(0, savedXP - grantXP(saved build))    -- recovered from the book, taxed
30:--     newEarned   = max(0, curXP  - grantXP(respawn build))   -- this life's play, untaxed (never lost)
31:--     target      = grantXP(saved build) + savedEarned * pct + newEarned
33:-- starting XP is dismissed with the build (write-at-spawn -> die -> remake cycles net
54:-- The 5 weight traits (Underweight/Very Underweight/Emaciated/Overweight/Obese) are
55:-- DYNAMIC labels the engine adds/removes from body weight, not identity: Nutrition
57:-- weight bracket. So we never snapshot them as traits - on restore they re-derive from the
58:-- restored weight (see capture / identityMatches / applyBodyState). Names are resolved from
60:local weightTraitNames
62:    if not weightTraitNames then
63:        weightTraitNames = {}
68:            if ok and nm then weightTraitNames[nm] = true end
71:    return weightTraitNames[name] == true
82:        perks   = {},
83:        traits  = {},
85:        kills   = {},
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
Your reasoning holds, and better than that - the exact structure you just described already exists in this repo and is working. Memoirs built it.

You've already got the pattern
MMAudit.lua writes Memoirs/<SafeName>/events.jsonl (per-player, append-only, one JSON object per line), plus latest.json as a derived convenience snapshot, plus a slim _all.log global timeline. It has a safeName() sanitizer for usernames, a hand-rolled JSON encoder with sorted keys so records diff cleanly, and open-append-close per line so a hard-killed server loses nothing already written. Its header states three intended consumers, and the first one listed is "a player-facing progression sheet (parse events.jsonl, plot snapshots)."

You had this idea already and shipped half of it. Reclamation should adopt that layout verbatim rather than invent a parallel one - same directory shape, same encoder, same naming - so a single harvester can walk both mods at season end.

The one place I'd still split from per-player
Keep a vehicle-keyed file alongside the player folders, not instead of them. Ticket support and the season story both want per-player; chain of custody wants per-vehicle, and neither view reconstructs the other cheaply. Since every write is already open-append-close, writing a record into both Reclamation/<SafeName>/events.jsonl and Reclamation/_vehicles/RC-xxxx.jsonl costs one extra file handle per event and no schema duplication. That gets you "what does this player own" in one read for the ticket queue, and "who has had this StepVan" in one read for the next Moa.

The actually-new work is rotation
MMAudit has no rotation and no retention - I checked, there's nothing. And its records embed full character snapshots, so events.jsonl grows without bound with heavy payloads inside. That's the shape of the 74MB Deadband audit log that contributed to the save-time data loss. So the rotation and daily-archive part of your proposal isn't just right for Reclamation, it's a latent fix Memoirs needs too. I'd build it once as a shared helper both mods call.

Rotate lazily at flush time on size or date change, not on restart - the restart scripts force-kill java, so any shutdown hook fires exactly never when it matters most.

On the season retrospective
The load-bearing constraint: you cannot derive a season story from a log you rotate and prune. A season is months; a verbose forensic log with snapshots in it can't be kept that long. So the two products need different streams - verbose and rotating for forensics, slim and permanent for the story. MMAudit's _all.log is already exactly that slim shape; it just needs to be per-player and kept.

Mapping your chapters to what exists today:

Stat progression is the one I'd have expected to be hardest and it's already solved. MMSnapshotCodec captures perks, traits, and kills, and - critically - it already implements the grant-versus-earned split (savedEarned = max(0, savedXP - grantXP(build))). That matters because a fresh spawn carries real raw XP from setXPToLevel, so a naive progression chart would credit players for levels character creation handed them. The distinction between what you were given and what you earned is the entire emotional weight of that chapter, and the math for it is written.

Deaths and memoirs written/read are already logged - MMAudit records every write and read attempt including refusals.

The vehicle you made your own is the chapter Reclamation owns, and it's the one thing on your list nothing currently records. It's also the one that needs the claim timeline to survive the whole season, which argues for putting claim/release events in the slim permanent stream and entry/exit/damage telemetry in the rotating one.

Where you started needs a life-start snapshot specifically - not the first snapshot that happens to exist, since a memoir restore would overwrite the baseline. Where you called home can come off the vanilla SafeHouse API, which Reclamation's janitor already queries. How you died needs a death hook that fires before the character is torn down.

What I'd say overall
Build the rotation helper first, in Dragonfly, since both mods need it and Memoirs is currently accumulating unbounded files. Then Reclamation's vehicle timeline on top of it, verified on the dedi. The retrospective is a harvester over those streams and should be written last, in Memoirs, once there's a season of data to harvest - it's a reader, not a writer, so it can't be tested before the streams exist anyway.

One flag: the Memoirs folder is still untracked in git and per your own notes hasn't been dedi-verified yet. If it's about to become shared infrastructure for a season-long feature, I'd get it committed and verified before anything depends on it.

Okay, rq. 

We have a lot of interdependence between the RFTD family of mods. And Im wondering if we are structuring this wrong. Should we just be shipping all of these inside one mod as submods?
Good question to ask now rather than after building shared infrastructure. Let me check how the items are actually packaged.

Bash Survey workshop items and mods per item
IN
cd "c:/VSCodeProjects/PZMod" && for d in */; do if [ -f "$d/workshop.txt" ]; then echo "--- $d"; grep -i "^id=\|^title=\|^tags=" "$d/workshop.txt" 2>/dev/null | head -3; ls "$d/Contents/mods/" 2>/dev/null | tr '\n' ' '; echo; fi; done 2>/dev/null | head -60

OUT
--- Cookbook/
id=3766834532
title=Requiem of the Dead: Cookbook
tags=Build 42
RFTDCookbook 
--- Dirge/
id=3701543539
title=Requiem of the Dead: Dirge
tags=Build 42
RFTDDirge 
--- Dragonfly/
id=3728273142
title=Requiem of the Dead: Dragonfly
tags=Build 42
BBLibrary Dragonfly 
--- DragonflyTest/
id=3747454190
title=zTest Dragonfly (DEV FORK - DO NOT SUBSCRIBE)
tags=Build 42
BBLibrary DragonflyTest 
--- Husbandry/
id=3711156499
title=Requiem of the Dead: Husbandry
tags=Build 42
RFTDHusbandry 
--- HusbandryTest/
id=3745075676
title=Requiem of the Dead: Husbandry (Test)
tags=Build 42
RFTDHusbandryTest 
--- Last Rites/
id=3748797439
title=Requiem of the Dead: Last Rites
tags=Build 42
RFTDLastRites 
--- OddsAndEnds/
id=
title=Requiem of the Dead: Odds & Ends (Testing)
tags=Build 42
RFTDOddsandEnds 
--- OmenSpyNetwork/
id=3747461064
title=Omen's Spy Network
tags=Build 42
OmenSpyNetwork 
--- Reaper/
id=3730287596
title=Requiem of the Dead: Reaper
tags=Build 42
RFTDReaper 
--- Reclamation/
id=3752878504
title=Requiem of the Dead: Reclaimation
tags=Build 42
RFTDReclamation 
--- Sector7/
id=3769280064
title=Requiem of the Dead: Map Fixes
tags=Build 42;Map
Sector-7 Breach Sector-7 Breach Highway
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
Bash Check mod ids and declared requires
IN
cd "c:/VSCodeProjects/PZMod" && echo "=== mod.info require/id ===" && for f in Dragonfly/Contents/mods/*/mod.info Reclamation/Contents/mods/*/mod.info "Last Rites/Contents/mods/"*/mod.info; do echo "-- $f"; grep -i "^id=\|^require=\|^name=" "$f" 2>/dev/null; done

OUT
=== mod.info require/id ===
-- Dragonfly/Contents/mods/BBLibrary/mod.info
name=BBLibrary
id=BBLibrary
require=Dragonfly
-- Dragonfly/Contents/mods/Dragonfly/mod.info
name=Requiem of the Dead: Dragonfly
id=Dragonfly
-- Reclamation/Contents/mods/RFTDReclamation/mod.info
name=Requiem of the Dead: Reclaimation
id=RFTDReclamation
-- Last Rites/Contents/mods/RFTDLastRites/mod.info
name=Requiem of the Dead: Last Rites
id=RFTDLastRites
Shell cwd was reset to c:\VSCodeProjects\PZMod\Reclamation
Grep "DFRegistry|DFBanBox|DF[A-Z]\w+\s*(and|~=|then)" (in c:/VSCodeProjects/PZMod, glob: *.lua)
31 lines of output
Short answer: you're not structured wrong, and you're already doing the thing you're asking about - but you're doing it in one place and not the others.

You already ship submods
The Dragonfly Workshop item (3728273142) contains two mod ids: BBLibrary and Dragonfly, with BBLibrary/mod.info declaring require=Dragonfly. Sector-7 ships two map mods in one item the same way. Contents/mods/ is plural by design - one Workshop item can carry as many mod ids as you want, each independently enableable, with require= controlling load order between them.

So the choice isn't "nine separate mods" versus "one mega-mod." Those are two separate decisions that you've been treating as one: how many Workshop items you publish, and how many mod ids you define. You can collapse the first without touching the second.

The coupling is thinner than it feels
I grepped the actual integration surface. Sibling mods touch Dragonfly through exactly one seam - DFRegistry tab registration - in five files: RCVehicleTab, RPNecroTab, RQAdmin, BXClient, and the BXShim_DFCompat shim. Every one is soft-guarded and deferred to OnGameStart, so each mod runs headless when Dragonfly is absent. That's a clean, well-behaved dependency. What you're feeling as "a lot of interdependence" is one seam repeated five times, which is the good version of this problem.

The real problem is version skew, not structure
Here's what actually bites: the server runs published Workshop builds while your client symlinks the dev tree. The moment Reclamation depends on a shared rotation helper living in Dragonfly, you can have Reclamation 0.6 and Dragonfly 0.5 live simultaneously, and nothing in require= catches a version mismatch - only presence. That's a genuine hazard the current layout has been sheltered from only because the mods don't share code yet, and the logging work would end that.

Co-packaging fixes it directly: mods in the same Workshop item update atomically, so they can never be out of step with each other.

What I'd do
One Workshop item - "Requiem of the Dead" - containing every mod id, plus a new thin RFTDCore holding the shared pieces (the rotation/retention helper, the JSON encoder, the getFileWriter idiom, safeName, the audit conventions). Everything else declares require=RFTDCore. That's the BBLibrary pattern scaled up, and it's already proven on your own live item.

I'd specifically not fold everything into a single mod id. Three reasons: the Kahlua 200-local bug silently fails an entire mod's load from one oversized function, so a monolith maximizes blast radius on a failure mode you've already been bitten by; server admins lose per-feature disable, which matters when one mod misbehaves on a live box; and your sandbox options all merge into one unmanageable list. Your own vertical-slice rule argues the same way - a monolith makes "verify one slice on the dedi" much harder.

Keep RFTDCore genuinely thin, and don't make Dragonfly the base everything requires. Dragonfly is a heavy admin-facing panel; a headless server running only Reclamation shouldn't have to load it.

One timing constraint
Mod ids are the key that save data hangs off, and PZ never self-cleans ModData from a removed mod id. Restructuring ids on a live server orphans state. If you consolidate, do it at a wipe boundary - and you already have one penciled in after 42.20 for the Sector-7 rehost. That's the window.

Practically: the packaging change can wait, but the RFTDCore decision can't, because the logging work is the first thing that would live in it. If you want the rotation helper shared, it should be born in RFTDCore rather than in Dragonfly and moved later.

Alright, I think you are on to something, but im not sure that you are fully expanding what can be done. 

We should enter plan mode.  Because this is a refactor, hopefully not a big one - because Ive done my best to keep everything modular as hell. 

Im thinking one master mod. Requiem of the Dead. 

This is where our core and our logging mastermind should live. This is our orchestrator that will eventually house Reqiuem of the Dead: Reflections. 

A season will be ideally between 3 and 4 months, or however long we can get away with before a wipe becomes necessary. 

I want to track initial player spawn. Where that is, location wise. There are maps online that we can use to snapshot the house that they spawn in https://map.projectzomboid.com/ via this. 

Core is going to be more than an orchestrator for LUA though. It's also going to house some parsing logic that is going to help build out html Reflection pages for players, taking those logs and informing the schema.
This is a good moment to plan it properly. Let me explore the family structure, the Memoirs logging pattern, and the existing telemetry surface in parallel before designing.

Agent:Inventory RFTD shared code
IN
Explore the RFTD mod family at c:\VSCodeProjects\PZMod (a Project Zomboid Build 42 Lua mod monorepo). Search breadth: very thorough.

The owner is planning a refactor: create a new master mod "Requiem of the Dead" (RFTDCore) that holds shared infrastructure, with all other mods declaring require=RFTDCore. I need a precise inventory of what is ALREADY duplicated or near-duplicated across mods so we know what should move into Core.

Top-level mod directories include: Reclamation, Dragonfly, Dirge, Reaper, Husbandry, "Last Rites", OddsAndEnds, Cookbook, OmenSpyNetwork, Sector7. IGNORE the *Test dev forks (DragonflyTest, HusbandryTest, ReclaimTest, JoiurnalTest) except to note they exist as file-level clones.

Report on:
1. **Shared helper duplication.** Each mod has a <Px>Shared.lua (RCShared, DFShared?, RQShared?, BXShared, LRShared?, HBShared?). Compare them. List functions that appear in 3+ mods with near-identical bodies (e.g. isAdmin/getAccessLevel ladders, halo/notify helpers, cfg() sandbox readers, dbg/trace loggers, safeName sanitizers, JSON encoders, file writers, isWreck/isTrailer-style predicates, rate limiters). Quote the function signature and which mods contain it.
2. **The OnClientCommand dispatcher pattern.** Each mod has a <Px>Server.lua single dispatcher with a rate limiter. Compare the rate-limit implementations and dispatch scaffolding - how similar are they?
3. **The Dragonfly integration contract.** Exactly how sibling mods register admin tabs: the DFRegistry global, what functions/args, where registration is deferred to, and how the soft-dependency guard is written. Files that do this: Reclamation RCVehicleTab.lua, Reaper RPNecroTab.lua, Dirge RQAdmin.lua, OddsAndEnds BXClient.lua/BXShim_DFCompat.lua.
4. **mod.info conventions.** For every mod.info under */Contents/mods/*/mod.info, report: id, name, require=, and any versioning field. Note which declare requires at all.
5. **Version/constant conventions.** How each mod declares its VERSION and MODULE (command-module token) constants.
6. **Sandbox options.** How each mod ships media/sandbox-options.txt and Translate/EN/Sandbox.json, and whether there is any shared reader pattern.

Return a structured report with concrete file paths and short code quotes. Do not propose a design - just inventory what exists and flag the strongest consolidation candidates.
Agent:Deep dive Memoirs logging
IN
Explore the Dragonfly "Memoirs" subsystem in a Project Zomboid Build 42 Lua mod monorepo. Search breadth: very thorough.

Key files:
- c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\Memoirs\MMAudit.lua
- c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\Memoirs\MMRestore.lua
- c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\shared\MMSnapshotCodec.lua
- c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\MMServer.lua
- c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\client\MMClient.lua, MMContext.lua

Context: the owner wants to build a season-long "Reflections" feature - an end-of-season per-player retrospective ("here is your life": where you spawned, stat progression, where you called home, the vehicle you made your own, deaths/memoirs, zombies killed, how you died). MMAudit's existing per-player JSONL layout is the intended model to generalize into a shared Core logging library.

Report in detail on:
1. **MMAudit's full architecture**: the exact on-disk layout (directories, filenames), the record schema (every field emitted, SCHEMA_V), the JSON encoder implementation (how it handles arrays/maps/numbers/escaping), safeName(), the write path (getFileWriter args, append semantics, the flat fallback), and the complete list of EVENT names it emits.
2. **What is NOT there**: confirm whether there is any log rotation, size cap, retention/pruning, or archiving. Confirm whether any file is ever truncated vs appended.
3. **MMSnapshotCodec's capture shape**: the exact fields of the snapshot table (perks, traits, kills, body, identity, faith, etc.) - enumerate them. How is XP captured? Explain the grant-vs-earned XP distinction and the exact helper functions that compute it (quote them). Is there a spawn/life-start baseline captured anywhere?
4. **Life/season identity**: search for any concept of a life id, epoch, generation counter, or season marker across the Memoirs files and the wider Dragonfly mod. How does the system know one life from the next? How does it detect a player died and respawned?
5. **Hooks used**: what events do MMServer/MMClient bind to (OnClientCommand handlers, player death hooks, login hooks)? Is there any death detection, and does anything capture data at the moment of death?
6. **Zombie kill / stat data availability**: anywhere in the monorepo that reads zombie kill counts, hours survived, or similar career stats off IsoPlayer.

Return concrete file:line references and code quotes. Do not propose a design - inventory what exists and explicitly flag the gaps relevant to a season retrospective.
Bash Find all mod.info files
IN
find "c:/VSCodeProjects/PZMod" -name "mod.info" -not -path "*Test*" 2>/dev/null

OUT
c:/VSCodeProjects/PZMod/Cookbook/Contents/mods/RFTDCookbook/42/mod.info
c:/VSCodeProjects/PZMod/Cookbook/Contents/mods/RFTDCookbook/mod.info
c:/VSCodeProjects/PZMod/Dirge/Contents/mods/RFTDDirge/42/mod.info
c:/VSCodeProjects/PZMod/Dirge/Contents/mods/RFTDDirge/mod.info
c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/BBLibrary/42/mod.info
c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/BBLibrary/mod.info
c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/mod.info
c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/mod.info
c:/VSCodeProjects/PZMod/Husbandry/contents/mods/RFTDHusbandry/42/mod.info
c:/VSCodeProjects/PZMod/Husbandry/contents/mods/RFTDHusbandry/mod.info
c:/VSCodeProjects/PZMod/Last Rites/Contents/mods/RFTDLastRites/42/mod.info
c:/VSCodeProjects/PZMod/Last Rites/Contents/mods/RFTDLastRites/mod.info
c:/VSCodeProjects/PZMod/OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/mod.info
c:/VSCodeProjects/PZMod/OddsAndEnds/Contents/mods/RFTDOddsandEnds/mod.info
c:/VSCodeProjects/PZMod/OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/mod.info
c:/VSCodeProjects/PZMod/OmenSpyNetwork/Contents/mods/OmenSpyNetwork/mod.info
c:/VSCodeProjects/PZMod/Reaper/Contents/mods/RFTDReaper/42/mod.info
c:/VSCodeProjects/PZMod/Reaper/Contents/mods/RFTDReaper/mod.info
c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/42/mod.info
c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/mod.info
c:/VSCodeProjects/PZMod/Sector7/Contents/mods/Sector-7 Breach/42/mod.info
c:/VSCodeProjects/PZMod/Sector7/Contents/mods/Sector-7 Breach/common/mod.info
c:/VSCodeProjects/PZMod/Sector7/Contents/mods/Sector-7 Breach Highway/42/mod.info
c:/VSCodeProjects/PZMod/Sector7/Contents/mods/Sector-7 Breach Highway/common/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Bumblebee/Contents/mods/Bumblebee/42/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Bumblebee/Contents/mods/Bumblebee/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Ladybug/Contents/mods/Ladybug/42/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Ladybug/Contents/mods/Ladybug/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Sandman/Contents/mods/RFTDSandman/42/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Sandman/Contents/mods/RFTDSandman/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Z_Scaffold/Contents/mods/RFTDOddsandEnds/42/mod.info
c:/VSCodeProjects/PZMod/zz_Archived/Z_Scaffold/Contents/mods/RFTDOddsandEnds/mod.info
Bash List lua files per mod
IN
cd "c:/VSCodeProjects/PZMod" && for d in Reclamation Dragonfly Dirge Reaper Husbandry "Last Rites" OddsAndEnds Cookbook OmenSpyNetwork Sector7; do echo "=== $d ==="; find "$d" -name "*.lua" | head -80; done

OUT
=== Reclamation ===
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimGUI.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimItemLock.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimLock.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimMenu.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCDismantleMenu.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEngineLock.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCMyVehicles.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCNotify.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCSpawnWindow.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCUsage.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCUserPanelHook.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCAudit.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCJanitor.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCRegistry.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCRVGate.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCServer.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCSession.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCSpawn.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCClaim.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCDismantleAction.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCPhunZones.lua
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCShared.lua
=== Dragonfly ===
Dragonfly/Contents/mods/BBLibrary/42/media/lua/server/BBLibrary_BanList.lua
Dragonfly/Contents/mods/BBLibrary/42/media/lua/server/BBLibrary_Example.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFBanBox_Notice.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFColumns.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConfirm.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFCoordOverlay.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFDebugGate.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFErrorPoller.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFFeedback.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFItemEditor.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFLog.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFMedicalCheck.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPatch_CleanUI.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPatch_Greenport.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayerInventoryModal.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRoleEditorUnlock.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRolesTab.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFSafehouseDestroyPatch.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFScoreboard.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSGridOverlay.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSMap.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTab.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTour.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTours.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/MMClient.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/MMContext.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/MMStatsView.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFEngineLock_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFInventory_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_AntiCheatLogNoise.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Greenport_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_JM3Archery.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_PhunLewt.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_RVInterior.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_SOTO.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Spongies.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayersTab_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFZombiesTab_Server.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/MMServer.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFActionSpeed.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFItemProbes.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_BetterHutches.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_SpecialLootSpawns.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Turn180Noise.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSnapshotCodec.lua
Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua
=== Dirge ===
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQBoss.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQCastBar.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQConfig.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQCore.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQEMP.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQGlutton.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQHealthBar.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQHighlight.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQJuggernaut.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQLoot.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReconcile.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQRegistry.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQRing.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQScavenger.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQScreamer.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQServer.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvEating.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvEMP.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvGlutton.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvJuggernaut.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvScavenger.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvScreamer.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQDirgeLog.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQEatLog.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQPhunZones.lua
Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua
=== Reaper ===
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPContextMenu.lua
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua
Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPCore.lua
Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPServer.lua
=== Husbandry ===
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBContextMenu.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBErrorMagnifier.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchContextMenu.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchUI.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBAPIProbe.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBKeepAlive.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBLifespan.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBSexCheck_Server.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBData.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBSexCheck.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/TimedActions/HBAddHayAction.lua
=== Last Rites ===
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDanger.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerHUD.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerMoodle.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerPanel.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerQuips.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRHub.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua
Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRUserPanelHook.lua
=== OddsAndEnds ===
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/BXClient.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_AutoEquipSafety.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_FatStateReplacement.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_HomemadeBleachVoid.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_PicnicBasketLoot.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_WashingServer.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShim_DFCompat.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Butchering.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Crafting.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Distributions.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua
=== Cookbook ===
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/client/RFTDCBClient.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/server/RFTDCBServer.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/OC_BaseballBatCostsOneNotepad.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/OC_RemoveAluminumFromBatScrap.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/RFTDCBShared.lua
=== OmenSpyNetwork ===
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianTestEmit.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNHooks_Server.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNServer.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNConfig.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNCrypto.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNMeter.lua
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNSizer.lua
=== Sector7 ===
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/ALICEPacks_HotbarAttachDefinition.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/Meiya_TweakItem.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/S7_Merit_Display.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/VaccinesZMenu.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/items/Meiya'CityDistributions.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/items/Meiya'sCityWorldFiller.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaCityCommand.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaFreeSpawnsCar.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/AZ_InjectBackpackAttachments.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/MeiyaCitySpawns.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/MYBackpackPlusOverride.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/NPCs/ALICEPacks_AttachedLocations.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/S7_Merit_ServerEvents.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/maps/Sector-7 Breach/objects.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/maps/Sector-7 Breach/roomtones.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/maps/Sector-7 Breach/spawnpoints.lua
Sector7/Contents/mods/Sector-7 Breach Highway/common/media/maps/Sector-7 Breach Highway/objects.lua
Agent:Telemetry, spawn/death hooks, HTML
IN
Explore a Project Zomboid Build 42 Lua mod monorepo at c:\VSCodeProjects\PZMod. Search breadth: very thorough.

Context: the owner is designing a season-long per-player telemetry + retrospective system. I need to inventory three things.

**1. Every logging/file-writing implementation in the monorepo.** Find all uses of getFileWriter and getFileReader across all mods (ignore the *Test dev forks except to note them). For each, report: file path, the exact args passed (filename, createIfNull, append), whether it truncates or appends, the output filename/directory, the line format (JSONL? pipe-delimited? key=value?), and any buffering. Known ones to cover: Reclamation RCAudit.lua + RCDamageAudit.lua, OmenSpyNetwork OSNLog.lua + GuardianLogger.lua, Dirge RQReflectLog.lua, OddsAndEnds BXServer.lua, Dragonfly DFRoleEdit_Server.lua + DFPlayerRoles_Server.lua + Memoirs/MMAudit.lua, "Last Rites" LRPrefs.lua, Longstrider LSTours.lua. Flag any that pass append=false but are clearly intended as append-only logs.

**2. Player lifecycle hooks already in use.** Search every mod for how they detect: a player spawning/first entering the world for a new character, a player logging in, a player dying, and a player respawning. Look for OnCreatePlayer, OnNewGame, OnPlayerDeath, OnCharacterDeath, OnPlayerUpdate, OnTick login polls, getOnlinePlayers polling, etc. Note especially any SERVER-side login detection (there is a documented B42 problem where OnPlayerUpdate never fires server-side and connect events are unreliable, with a standing OnTick poll gated on getSquare()+getInventory() as the workaround - find that implementation if it exists). Report file:line and the approach used.

**3. HTML/report generation precedent.** Look at C:\Users\micha\Downloads\pzsurvey.py - a Python tool that decodes PZ player.db blobs and renders an HTML survey. Report: how it structures the decode->dataset->render pipeline (the build_dataset and render functions), what player fields it can already extract (stats, XP, traits, perks, kills, hours survived), and how the HTML is emitted (template strings? CSS approach?). Also check c:\VSCodeProjects\PZMod\tools\ for any other parsing/reporting tooling and report what's there.

Return concrete file:line references and code quotes. Do not propose a design - inventory only.
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\shared\MMSnapshotCodec.lua
Bash Dump mod.info batch 1
IN
cd "c:/VSCodeProjects/PZMod" && for f in Cookbook/Contents/mods/RFTDCookbook/mod.info Cookbook/Contents/mods/RFTDCookbook/42/mod.info Dirge/Contents/mods/RFTDDirge/mod.info Dirge/Contents/mods/RFTDDirge/42/mod.info Dragonfly/Contents/mods/BBLibrary/mod.info Dragonfly/Contents/mods/BBLibrary/42/mod.info Dragonfly/Contents/mods/Dragonfly/mod.info Dragonfly/Contents/mods/Dragonfly/42/mod.info; do echo "--- $f"; cat "$f"; echo; done

OUT
--- Cookbook/Contents/mods/RFTDCookbook/mod.info
name=Requiem of the Dead: Cookbook
id=RFTDCookbook
modversion=0.2.0
description=Something to test
pzversion=42

--- Cookbook/Contents/mods/RFTDCookbook/42/mod.info
name=Requiem of the Dead: Cookbook
id=RFTDCookbook
modversion=0.2.0
description=Something to test
pzversion=42

--- Dirge/Contents/mods/RFTDDirge/mod.info
name=Requiem of the Dead: Dirge
id=RFTDDirge
modversion=1.0.3
description=Dirge - Special zombie variants with unique abilities. Screamers, Juggernauts, EMP zombies, Gluttons, Scavengers, and admin-spawnable Bosses.
pzversion=42

--- Dirge/Contents/mods/RFTDDirge/42/mod.info
name=Requiem of the Dead: Dirge
id=RFTDDirge
modversion=1.0.3
description=Dirge - Special zombie variants with unique abilities. Screamers, Juggernauts, EMP zombies, Gluttons, Scavengers, and admin-spawnable Bosses.
pzversion=42

--- Dragonfly/Contents/mods/BBLibrary/mod.info
name=BBLibrary
id=BBLibrary
modversion=0.1.0
description=Ban-list library for Dragonfly's item BanBox engine. Enable this mod to apply its bundled ban list (the Requiem of the Dead server's defaults): the listed item types are stripped from loot distribution at server start so no new copies spawn (prevention, not a world sweep - items already placed are left alone), and with confiscate-on-login enabled any carried banned items are removed when a player connects. Requires Dragonfly. Leave it disabled to run the BanBox engine with no built-in bans, or copy the bundled example file into your own mod to ban your own items.
pzversion=42
require=Dragonfly

--- Dragonfly/Contents/mods/BBLibrary/42/mod.info
name=BBLibrary
id=BBLibrary
modversion=0.1.0
description=Ban-list library for Dragonfly's item BanBox engine. Enable this mod to apply its bundled ban list (the Requiem of the Dead server's defaults): the listed item types are stripped from loot distribution at server start so no new copies spawn (prevention, not a world sweep - items already placed are left alone), and with confiscate-on-login enabled any carried banned items are removed when a player connects. Requires Dragonfly. Leave it disabled to run the BanBox engine with no built-in bans, or copy the bundled example file into your own mod to ban your own items.
pzversion=42
require=Dragonfly

--- Dragonfly/Contents/mods/Dragonfly/mod.info
name=Requiem of the Dead: Dragonfly
id=Dragonfly
modversion=0.6.3
description=Admin command center for the Requiem of the Dead mod family. Tabbed admin panel (default Shift+U keybind) plus an ESC scoreboard extension, with an unlocked built-in role editor so admins can grant/revoke capabilities on existing roles (User, Moderator, etc.) without creating custom roles and reassigning players. Other RFTD mods (Reaper, Husbandry, Dirge) register tabs and per-row actions into Dragonfly when installed; each mod still works standalone. Includes the SledgehammerOnlyInSafehouse anti-grief fix (formerly the standalone Ladybug mod) and the Memoir, a craftable character snapshot/restore journal that records your skills, traits, and recipes and recalls them after death, with a server-tunable XP restore percentage. Also includes per-family timed-action speed scaling (reading, foraging, cleaning, repair, dismantle), a keybindable gate that hides admin/debug right-click options to declutter the context menu, and a server-side item BanBox: a neutral engine that strips banned item types from loot at startup and can optionally confiscate carried banned items when a player logs in, with the ban list itself supplied by the bundled opt-in BBLibrary submod or your own. Designed for dedicated multiplayer servers.
pzversion=42

--- Dragonfly/Contents/mods/Dragonfly/42/mod.info
name=Requiem of the Dead: Dragonfly
id=Dragonfly
modversion=0.6.3
description=Admin command center for the Requiem of the Dead mod family. Tabbed admin panel (default Shift+U keybind) plus an ESC scoreboard extension, with an unlocked built-in role editor so admins can grant/revoke capabilities on existing roles (User, Moderator, etc.) without creating custom roles and reassigning players. Other RFTD mods (Reaper, Husbandry, Dirge) register tabs and per-row actions into Dragonfly when installed; each mod still works standalone. Includes the SledgehammerOnlyInSafehouse anti-grief fix (formerly the standalone Ladybug mod) and the Memoir, a craftable character snapshot/restore journal that records your skills, traits, and recipes and recalls them after death, with a server-tunable XP restore percentage. Also includes per-family timed-action speed scaling (reading, foraging, cleaning, repair, dismantle), a keybindable gate that hides admin/debug right-click options to declutter the context menu, and a server-side item BanBox: a neutral engine that strips banned item types from loot at startup and can optionally confiscate carried banned items when a player logs in, with the ban list itself supplied by the bundled opt-in BBLibrary submod or your own. Designed for dedicated multiplayer servers.
pzversion=42
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\shared\MMSvShared.lua
Grep "getFileWriter|getFileReader" (in c:\VSCodeProjects\PZMod)
58 lines of output
Read c:\VSCodeProjects\PZMod\Reclamation\Contents\mods\RFTDReclamation\42\media\lua\shared\RCShared.lua
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\client\MMStatsView.lua
Read c:\VSCodeProjects\PZMod\Husbandry\contents\mods\RFTDHusbandry\42\media\lua\shared\HBData.lua
Grep "OnPlayerDeath|OnCharacterDeath|isDead\(\)|OnPlayerUpdate|OnCreatePlayer|OnPlayerConnect|OnServerStarted|EveryHours|EveryDays|OnNewGame|OnPlayerDies" (in c:\VSCodeProjects\PZMod)
121 lines of output
Read c:\VSCodeProjects\PZMod\Dirge\Contents\mods\RFTDDirge\42\media\lua\shared\RQReflectLog.lua
Grep "HaloTextHelper\.addText" (in c:\VSCodeProjects\PZMod, glob: *.lua)
4 lines of output
Read c:\VSCodeProjects\PZMod\Last Rites\Contents\mods\RFTDLastRites\42\media\lua\client\LRPrefs.lua
Grep "function .*(dbg|trace|log|Log|Dbg|Trace)\s*\(" (in c:\VSCodeProjects\PZMod, glob: *.lua)
25 lines of output
Grep "getFileWriter|getFileReader" (in c:\VSCodeProjects\PZMod, glob: *.lua)
44 lines of output
Grep "LOGFILE" (in c:\VSCodeProjects\PZMod\OddsAndEnds)
2 lines of output
Bash Find all OnClientCommand registrations
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "OnClientCommand" --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua:126:    -- zombies. sendClientCommand works on host too - routes to OnClientCommand.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQServer.lua:757:Events.OnClientCommand.Add(function(module, command, player, args)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFEngineLock_Server.lua:36:Events.OnClientCommand.Add(onClientCommand)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Greenport_Server.lua:213:Events.OnClientCommand.Add(onClientCommand)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Spongies.lua:8:-- OnPlayerJoin -> OnClientCommand path.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:249:-- "hello" over OnClientCommand (which this mod already uses) the instant the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:135:Events.OnClientCommand.Add(onClientCommand)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:97:Events.OnClientCommand.Add(onClientCommand)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/MMServer.lua:308:Events.OnClientCommand.Add(onClientCommand)
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBSexCheck_Server.lua:18:Events.OnClientCommand.Add(function(module, command, player, args)
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua:30:Events.OnClientCommand.Add(function(module, command, player, args)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_WashingServer.lua:6:if Events and Events.OnClientCommand and SoapZ.Washing.handleClientCommand and not SoapZ.Washing.serverCommandsRegistered then
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_WashingServer.lua:8:    Events.OnClientCommand.Add(SoapZ.Washing.handleClientCommand)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua:12:-- Command-module token used for sendClientCommand/sendServerCommand/OnClientCommand routing.
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShim_DFCompat.lua:90:    Events.OnClientCommand.Add(onClientCommand)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua:1411:if Events and Events.OnClientCommand and isServer and isServer() and not SoapZ.Washing.serverCommandsRegistered then
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua:1413:    Events.OnClientCommand.Add(SoapZ.Washing.handleClientCommand)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:5:-- daemon that reads these files. Lua couldn't veto the command anyway (OnClientCommand return value is
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:9:-- CCFilter. The Lua OnClientCommand event fires OUTSIDE that filter and WITH the args, server-side.
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:168:    Events.OnClientCommand.Add(function(module, command, player, args)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianTestEmit.lua:82:    Events.OnClientCommand.Add(function(module, command, player, args)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNHooks_Server.lua:67:    Events.OnClientCommand.Add(function(module, command, player, args)
./Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPServer.lua:149:Events.OnClientCommand.Add(onClientCommand)
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua:6:-- commands with our own OnClientCommand listener and write a durable line.
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua:16:-- "player" in OnClientCommand is the command SENDER = the attacker.
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua:113:Events.OnClientCommand.Add(onClientCommand)
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCJanitor.lua:269:Events.OnClientCommand.Add(onVehicleCommand)
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCRVGate.lua:13:-- `GetInToRV(player, vehicle)` (its `enterRV` OnClientCommand handler resolves the
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCServer.lua:1:-- RCServer - the SINGLE OnClientCommand dispatcher (RFTD house rule).
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCServer.lua:547:Events.OnClientCommand.Add(onClientCommand)
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/S7_Merit_Display.lua:31:Events.OnClientCommand.Add(onMeritCommand)
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaCityCommand.lua:21:function MeiyaCityCommand.OnClientCommand(_module, _command, _player, _args)
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaCityCommand.lua:35:Events.OnClientCommand.Add(MeiyaCityCommand.OnClientCommand)
Bash Inspect snapshot.txt sample log
IN
head -c 3000 "c:/VSCodeProjects/PZMod/Dragonfly/snapshot.txt"; echo; echo "=== wc ==="; wc -l "c:/VSCodeProjects/PZMod/Dragonfly/snapshot.txt"

OUT
1784948536|33.39|WRITE|user=Nikki|itemId=1970206219|first=true|lifeId=1784729125-77406583
1784965716|34.02|WRITE|user=Nikki|itemId=1970206219|first=false|lifeId=1784729125-77406583
1784979605|34.56|WRITE|user=Nikki|itemId=1970206219|first=false|lifeId=1784729125-77406583|snap={epoch=1,firstWrittenAt=1784948536,kills={Survivor=0,Zombie=2029},lifeId=1784729125-77406583,nutrition={calories=-196.24,carbs=-377.54,lipids=12.93,proteins=-99.69,weight=78.18},perks={Aiming=2703.41,Art=153.12,Blacksmith=17343.12,Blunt=1393.30,Carving=907.12,Cooking=508.38,Doctor=96.25,Electricity=213.50,Farming=262.50,Fishing=437.50,Fitness=487500,Husbandry=515.38,Lightfoot=408.04,LongBlade=3831.83,Maintenance=7606.81,Mechanics=612.50,Meditation=4.01,MetalWelding=1647.62,Music=32775,Nimble=2004.20,Pottery=525,Reloading=2957.76,SmallBlunt=115.81,Sneak=33.69,Spear=75,Sprinting=1850.12,Strength=487500,Tailoring=16705.50,Woodwork=563.50},profession=dancer,recipes=[3rdGenChevyCKseriesMakeBackSideWindow,3rdGenChevyCKseriesMakeFrontDoor,3rdGenChevyCKseriesMakeFrontSideWindow,3rdGenChevyCKseriesMakeFrontWindshield,3rdGenChevyCKseriesMakeRearDoor,3rdGenChevyCKseriesMakeRearSideWindow,3rdGenChevyCKseriesMakeRearWindshield,3rdGenChevyCKseriesMakeSplitRearWindshield,63beetleMakeFrontDoor,63beetleMakeFrontSeat,63beetleMakeFrontSideWindow,63beetleMakeFrontWindshield,63beetleMakeHood,63beetleMakeRearSeat,63beetleMakeRearSideWindow,63beetleMakeRearWindshield,63beetleMakeRoofrack,63beetleMakeSidesteps,63beetleMakeTrunkLid,76chevyCKMakeSidesteps,76chevyCKMakeSidestepsLong,76chevyCseriesMakeLeftMount,76chevyCseriesMakeMudflaps,76chevyCseriesMakeRightMount,76chevyCseriesMakeRoofrack,76chevyCseriesMakeStorageLid,76chevyCseriesMakeTrunkLid,76chevyCseriesMakeVisor,76chevyK10MakeBedCover,76chevyK10MakeBedOpenCover,76chevyK20MakeBedCover,76chevyK20MakeBedOpenCover,76chevyKseriesFDMakeMudflaps,76chevyKseriesFDMakeStorageLids,76chevyKseriesFDMakeTrunkLid,76chevyKseriesMakeFrontSeat,76chevyKseriesMakeHood,76chevyKseriesMakeRearSeat,76chevyKseriesMakeRollbar,76chevyKseriesMakeRollbarT2,76chevyKseriesMakeRoofrack,76chevyKseriesMakeToolbox,76chevyKseriesMakeTrunkLid,76chevySuburbanMakeTrunkLid,76chevySuburbanSplitMakeTrunkLid,80sPickupMakeFrontSeat,80sPickupMakeRearSeat,80sPickupMakeRoofrack,83amgeneralM923.MakeFrontDoor,83amgeneralM923.MakeFrontSideWindow,83amgeneralM923.MakeFrontWindshield,83amgeneralM923.MakeHardCover,,83amgeneralM923.MakeHood,83amgeneralM923.MakeMudflaps,83amgeneralM923.MakeMuffler,83amgeneralM923.MakeTailgate,83amgeneralM923.MakeTrunkLid,86fordE150MakeFrontDoor,86fordE150MakeFrontSeat,86fordE150MakeFrontSideWindow,86fordE150MakeFrontWindshield,86fordE150MakeHood,86fordE150MakeRearDoor,86fordE150MakeRearDoorWin,86fordE150MakeRearSideWindow,86fordE150MakeRearWindshield,86fordE150MakeRoofrack,86fordE150MakeTrunkLid,88ChevyS10MakeBedCap,88ChevyS10MakeFrontDoor,88ChevyS10MakeFrontSideWindow,88ChevyS10MakeFrontWindshield,88ChevyS10MakeHood,88ChevyS10MakeRearWindshield,88ChevyS10MakeTop
=== wc ===
4 c:/VSCodeProjects/PZMod/Dragonfly/snapshot.txt
Read c:\VSCodeProjects\PZMod\Reaper\Contents\mods\RFTDReaper\42\media\lua\server\RPServer.lua
Grep "OnCreatePlayer|OnNewGame|OnPlayerDeath|OnCharacterDeath|OnPlayerUpdate|OnPlayerDies|OnSpawnRegionsLoaded|OnCreateLivingCharacter|OnPostSave|OnServerStarted|OnConnected|OnDisconnect|OnPlayerConnect|OnClientConnect|EveryTenMinutes|OnTick" (in c:\VSCodeProjects\PZMod, glob: *.lua)
18 lines of output
Bash Find rate limiter implementations
IN
cd "c:/VSCodeProjects/PZMod" && grep -rni "rate.limit\|rateLimit\|allow(player\|rlBucket\|windowMs\|throttl\|cooldown" --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived | head -60

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQConfig.lua:54:local E_BOSS_COOLDOWN       = {5, 10, 15, 20, 30, 60}            -- default idx=3 -> 15s
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQConfig.lua:154:        bossSkillCooldown      = ev(E_BOSS_COOLDOWN, sv and sv.BossSkillCooldown, 3) * 1000,
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:9:--   damage    - local player takes any damage (8s cooldown). If an unseen
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:38:-- event-driven + cooldown-limited, so a quiet session writes ~nothing.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:49:local DAMAGE_COOLDOWN_MS = 8000
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:50:local MANUAL_COOLDOWN_MS = 2000
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:51:local AUTOPING_COOLDOWN_MS = 15000
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:170:        if t - lastDamageDump < DAMAGE_COOLDOWN_MS then return end
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:187:    if t - lastManualDump < MANUAL_COOLDOWN_MS then return end
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:231:                    if t - lastAutoPing >= AUTOPING_COOLDOWN_MS then
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQServer.lua:753:-- reflectPing per-player rate limit (username-keyed: exact SteamIDs are lossy
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua:6:--   2) Coin-flip skill rotation between Scream and EMPulse, 40s cooldown.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua:24:local BOSS_SKILL_COOLDOWN = 40000   -- (ms) hardcoded 40s between Scream/EMPulse casts. Overrides cfg.bossSkillCooldown.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua:86:    -- passive buff aura sweep, throttled. runs regardless of whether a cast is active -
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua:140:    -- 40s cooldown is hardcoded here, not pulled from cfg.bossSkillCooldown. Tweak BOSS_SKILL_COOLDOWN above if you need a different cadence.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvBoss.lua:141:    if now - state.lastSkillTime < BOSS_SKILL_COOLDOWN then return end
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:37:local PROBE_LOG_GAP  = 60000        -- per-record throttle for probe spam (ms)
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:41:-- Non-persistent probe-log throttle (pidStr -> last log ms). Deliberately a
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:226:-- per-record throttle keeps a lingering record near a horde from spamming
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:103:local SE_BOSS_COOLDOWN      = {5, 10, 15, 20, 30, 60}
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:170:        bossSkillCooldown = sev(SE_BOSS_COOLDOWN, sv and sv.BossSkillCooldown, 3) * 1000,
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:190:    if not now or (now - lastPoll) < POLL_INTERVAL_MS then return end  -- throttle to ~1s
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:211:                -- Throttled visibility while waiting (every ~5s): shows what the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:27:-- Per-player command rate limit. 20 commands/sec is far above any human
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:36:local function noteThrottled(player)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:43:        print("[Dragonfly] rate-limit: dropping commands from " .. name)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:50:        "[Dragonfly] rate-limit: dropping excess commands from %s (> %d per %dms)",
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:64:    if not DFCore.allow(player, RATE_MAX, RATE_WINDOW_MS) then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:65:        noteThrottled(player)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:123:-- Prune rate-limit state when a player leaves so the per-username tables don't
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFServer.lua:135:    DFCore.forgetRateLimit(name)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:17:                           -- 0.6.0: command rate-limiter + auditOnly staff-gate; BanBox engine + login confiscation
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:51:-- Per-player command rate limiter (server-side defense-in-depth).
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:57:-- keyed by username: at most `max` commands per `windowMs`. It FAILS OPEN -
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:61:local rlBuckets = {}   -- username -> { count, windowStart }
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:74:-- if they've exceeded `max` commands inside the current `windowMs` window.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:75:function DFCore.allow(player, max, windowMs)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:81:    windowMs = windowMs or 1000
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:82:    local b = rlBuckets[name]
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:83:    if not b or (now - b.windowStart) >= windowMs then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:84:        rlBuckets[name] = { count = 1, windowStart = now }
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:93:function DFCore.forgetRateLimit(name)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:94:    if name then rlBuckets[name] = nil end
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua:30:HBBedding.CLEAN_PER_PASS = 5    -- max dirt absorbed per pass (rate limit, for visuals)
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua:125:-- wall-clock. Absorption is rate-limited to CLEAN_PER_PASS dirt/pass so a coop
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:109:-- Command handlers (registered on DFServer; capability + rate limit + reply
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:249:-- Throttled poll: log manual in/out, and self-destruct a box once it's emptied
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShim_DFCompat.lua:42:    function DFCore.allow() return true end -- no rate limiting needed for testing
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:388:    -- Once every soap recipe is known, stamp a flag so the per-tick throttle can skip the
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:409:function SoapZ.TraitRecipes.learnForPlayerThrottled(player)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:416:    -- Already learned everything? Skip the throttle bookkeeping and the 27-recipe loop forever.
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:456:Events.OnPlayerUpdate.Add(SoapZ.TraitRecipes.learnForPlayerThrottled)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNServer.lua:1:-- OSNServer.lua - Omen's Spy Network: server bootstrap + throttled dump loop.
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNServer.lua:3:-- Pulls in the shared modules and the capture hooks, then runs a wall-clock-throttled top-N dump on
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/OSNServer.lua:4:-- OnTick (matching the RFTD Reaper/Dirge OnTick + getTimestampMs throttle pattern). The only periodic
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNMeter.lua:4:-- instant alert (storm-guarded). dump(now) writes a throttled top-N offenders table and resets the
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCClaimItemLock.lua:47:-- every check (throttled) so we can see whether the item resolved to a vehicle
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua:7:-- be wrapped from Lua, so this is a REFILL engine: a throttled tick keeps
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua:16:-- and only for staff - an opt-in, bounded, self-throttled cheat, not a scan
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua:39:-- Light per-(attacker,vehicle) throttle so a melee flurry doesn't write
Bash Git history for MMAudit
IN
cd "c:/VSCodeProjects/PZMod/Dragonfly" && git log --oneline -15 -- "Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua" 2>/dev/null | head -20; echo "=== ls repo root ==="; ls "c:/VSCodeProjects/PZMod/Dragonfly"

OUT
=== ls repo root ===
Contents
Poster.jpg
mods (2).zip
preview.png
snapshot.txt
workshop.txt
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\DFServer.lua
Grep "getInventory\(\)" (in c:\VSCodeProjects\PZMod, glob: *.lua)
121 lines of output
Read c:\VSCodeProjects\PZMod\Dirge\Contents\mods\RFTDDirge\42\media\lua\server\RQSvShared.lua (lines 2-201)
Bash List Reclamation lua dirs
IN
ls "c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/" "c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/" 2>/dev/null

OUT
c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/:
RCAudit.lua
RCDamageAudit.lua
RCJanitor.lua
RCRVGate.lua
RCRegistry.lua
RCServer.lua
RCSession.lua
RCSpawn.lua

c:/VSCodeProjects/PZMod/Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/:
RCClaim.lua
RCDismantleAction.lua
RCPhunZones.lua
RCShared.lua
Translate
Grep "OnPlayerDeath|OnCharacterDeath|isDead\(\)|:isDead|OnZombieDead|respawn|Respawn|OnPlayerGetDamage|OnPlayerAttackFinished" (in c:\VSCodeProjects\PZMod, glob: *.lua)
70 lines of output
Bash Find DFRegistry usages
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "DFRegistry" --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:13:-- DFRegistry check happens inside the OnGameStart callback below, not here.
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:53:    if not DFRegistry or not Capability then return end
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:55:        DFRegistry.registerRowAction{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua:6:-- through DFRegistry just like consumer-mod tabs do.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua:123:-- Defer registration to OnGameStart so DFRegistry is guaranteed loaded
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua:126:    print("[Dragonfly] DFConsoleTab OnGameStart fired; DFRegistry=" .. tostring(DFRegistry ~= nil))
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua:127:    if not DFRegistry then return end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFConsoleTab.lua:133:        DFRegistry.registerTab{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua:129:    if DFRegistry and DFRegistry.registerStatusBadge then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua:130:        DFRegistry.registerStatusBadge{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:1:-- DFPanel - F10 admin window. Hosts tabs registered via DFRegistry.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:5:-- all come in via DFRegistry. Window title is "Dragonfly Admin Panel".
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:63:    local badges = DFRegistry.getStatusBadges()
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:106:    local tabs = DFRegistry.getTabs()
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:145:    local spec = DFRegistry.tabs[id]
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:185:        local spec = DFRegistry.tabs[btn.internal]
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:229:    if DFRegistry and DFRegistry.getTabs then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:230:        local tabs = DFRegistry.getTabs()
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:236:        print("[Dragonfly] DFPanel.open: DFRegistry not loaded!")
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPatch_CleanUI.lua:101:    if applied and DFRegistry and DFRegistry.registerStatusBadge then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPatch_CleanUI.lua:102:        DFRegistry.registerStatusBadge{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua:17:-- DFRegistry.getRowActions("players") for consumer-mod extension.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua:514:    if not DFRegistry then return end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua:516:        DFRegistry.registerTab{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:1:-- DFRegistry - tab/action/badge registration for consumer mods.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:13:DFRegistry = DFRegistry or {
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:19:function DFRegistry.registerTab(spec)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:24:    DFRegistry.tabs[spec.id] = spec
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:28:function DFRegistry.registerRowAction(spec)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:30:    local list = DFRegistry.rowActions[spec.tabId]
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:31:    if not list then list = {}; DFRegistry.rowActions[spec.tabId] = list end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:35:function DFRegistry.registerStatusBadge(spec)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:37:    DFRegistry.statusBadges[spec.id] = spec
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:40:function DFRegistry.getTabs()
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:42:    for _, spec in pairs(DFRegistry.tabs) do
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:45:        local hide = spec.supersededBy and DFRegistry.tabs[spec.supersededBy] ~= nil
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:57:function DFRegistry.getRowActions(tabId)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:58:    return DFRegistry.rowActions[tabId] or {}
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:61:function DFRegistry.getStatusBadges()
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:63:    for _, spec in pairs(DFRegistry.statusBadges) do out[#out + 1] = spec end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:69:-- rather than `DFRegistry.registerTab{...}`; reads cleaner from outside.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:71:Dragonfly.registerTab         = DFRegistry.registerTab
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:72:Dragonfly.registerRowAction   = DFRegistry.registerRowAction
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua:73:Dragonfly.registerStatusBadge = DFRegistry.registerStatusBadge
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRolesTab.lua:384:    if not DFRegistry then return end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRolesTab.lua:386:        DFRegistry.registerTab{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFSafehouseDestroyPatch.lua:136:    if DFRegistry and DFRegistry.registerStatusBadge then
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFSafehouseDestroyPatch.lua:137:        DFRegistry.registerStatusBadge{
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTab.lua:394:    if not DFRegistry then return end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTab.lua:396:        DFRegistry.registerTab{
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:3:-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry isn't
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:14:-- DFRegistry check happens inside the OnGameStart callback below, not here.
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:386:    if not DFRegistry then return end
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:387:    DFRegistry.registerTab{
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:913:    if DFPanel and DFRegistry and DFRegistry.tabs and DFRegistry.tabs["animals"] then
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:9:-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry is absent.
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:307:    if not DFRegistry then return end
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:308:    DFRegistry.registerTab{
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:13:-- DFRegistry check happens inside the OnGameStart callback below, not here.
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:239:    local actions = DFRegistry.getRowActions("necro")
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:510:    if not DFRegistry then return end
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:511:    DFRegistry.registerTab{
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:4:-- OnGameStart and bails if the DFRegistry global is absent, so Reclamation
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:268:-- Deferred registration: DFRegistry may not exist (no Dragonfly) and load
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:271:    if not DFRegistry then return end
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:273:        DFRegistry.registerTab{
Read c:\VSCodeProjects\PZMod\Reclamation\Contents\mods\RFTDReclamation\42\media\lua\server\RCSession.lua
Bash Read Husbandry/Dirge registration blocks
IN
cd "c:/VSCodeProjects/PZMod" && echo "===== HBAnimalsTab reg"; sed -n '375,420p' "Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua"; echo "===== HBHutchesTab reg"; sed -n '298,340p' "Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua"; echo "===== RQNecroActions"; sed -n '1,90p' "Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua"

OUT
===== HBAnimalsTab reg
    -- Row 5: stats line
    local stats = ISLabel:new(PAD, cursorY, 16, "Loaded animals: -",
        0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    AnimalsTab.statsLabel = stats

    refresh()
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id    = "animals",
        label = "Animals",
        order = 6,
        build = build,
    }
    print("[Husbandry] HBAnimalsTab registered into Dragonfly")
end)
===== HBHutchesTab reg
        0.75, 0.85, 0.95, 1, UIFont.Small, true)
    stats:initialise(); stats:instantiate()
    panel:addChild(stats)
    HutchesTab.statsLabel = stats

    refresh()
end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    DFRegistry.registerTab{
        id    = "hutches",
        label = "Hutches",
        order = 7,  -- just after the Animals tab (order 6)
        build = build,
    }
    print("[Husbandry] HBHutchesTab registered into Dragonfly")
end)
===== RQNecroActions
-- RQNecroActions - registers Dirge "Convert to Type" actions on the Necro
-- tab when both Dragonfly and Reaper are installed. Soft-depends on both;
-- without Dragonfly, Dirge's existing right-click admin menu still works
-- as the only conversion surface.
--
-- Each action handler sends Dirge's existing adminConvert command. The
-- server-side svMarkZombie path runs unchanged, so type-specific behavior
-- (Screamer summoning, Juggernaut aura, etc.) initializes the same way it
-- does from the in-world right-click menu.

if isServer() then return end

-- DFRegistry check happens inside the OnGameStart callback below, not here.
-- Top-of-file early return would prevent the OnGameStart hook from ever
-- being registered if Dirge loads before DragonflyAdmin.

-- TYPES is built inside OnGameStart so Capability (defined by Dragonfly Admin)
-- isn't dereferenced at file-load time. Without that guard, any client without
-- Dragonfly installed errors out with "attempted index of nil" the moment this
-- file loads, breaking everything else in the mod.
local TYPE_IDS = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger", "Boss" }

local function convertHandler(zType)
    return function(rowData)
        if not rowData or not rowData.id then return end
        sendClientCommand(getPlayer(), "RQ", "adminConvert", {
            onlineID = rowData.id,
            x        = rowData.x or 0,
            y        = rowData.y or 0,
            z        = rowData.z or 0,
            zType    = zType,
        })
        if DFFeedback then
            DFFeedback.good(string.format("Convert request sent: id=%d -> %s",
                rowData.id, zType))
        end
        -- Local audit echo so the action shows up in the Console tab even
        -- before Dirge replies. Server-side svMarkZombie doesn't emit a
        -- LogBroadcast on its own; if it ever does we'll see a duplicate
        -- here, which is acceptable.
        if DFLog then
            DFLog.push{
                source = "Mod:RFTDDirge",
                level  = "audit",
                text   = string.format("Convert id=%d -> %s by %s",
                    rowData.id, zType, getPlayer():getUsername()),
            }
        end
    end
end

Events.OnGameStart.Add(function()
    if not DFRegistry or not Capability then return end
    for _, id in ipairs(TYPE_IDS) do
        DFRegistry.registerRowAction{
            tabId      = "necro",
            label      = "Convert → " .. id,
            capability = Capability.CanZombify,
            handler    = convertHandler(id),
        }
    end
    print("[Dirge] RQNecroActions: " .. #TYPE_IDS .. " Convert actions registered")
end)
Read c:\VSCodeProjects\PZMod\Reclamation\Contents\mods\RFTDReclamation\42\media\lua\server\RCDamageAudit.lua
Read C:\Users\micha\Downloads\pzsurvey.py
Read c:\VSCodeProjects\PZMod\OddsAndEnds\Contents\mods\RFTDOddsandEnds\42\media\lua\shared\BXShim_DFCompat.lua
Grep "Memoir|Reflections|MMAudit|Retrospective" (in c:\VSCodeProjects\PZMod\_Review)
3 lines of output
Read C:\Users\micha\Downloads\pzsurvey.py (lines 131-370)
Bash Outline HTML template structure
IN
sed -n '370,560p' "/c/Users/micha/Downloads/pzsurvey.py" | grep -n "^<\|^\.\|function \|const \|__DATA__\|<script\|</style>\|id=\|class T\b" | head -80

OUT
19:.wrap{max-width:1160px;margin:0 auto;padding:0 18px 90px}
21:.tabnum,.num{font-variant-numeric:tabular-nums}
22:.mast{border-top:3px solid var(--amber);padding:24px 0 14px}
23:.mast .kicker{color:var(--amber);letter-spacing:.32em;font-size:11px;text-transform:uppercase}
24:.mast h1{font-size:25px;margin:6px 0 4px;letter-spacing:.05em;color:var(--ink-face);text-transform:uppercase;font-weight:700;text-wrap:balance}
25:.mast .lede{color:var(--ink-dim);max-width:78ch}
26:.mast .lede b{color:var(--ink)}
27:.eyebrow{font-size:10.5px;letter-spacing:.2em;text-transform:uppercase;color:var(--ink-dim)}
28:.mt{margin-top:12px}
29:.muted{color:var(--ink-dim);font-size:11.5px}
30:.kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:1px;background:var(--line);border:1px solid var(--line);margin:18px 0}
31:.kpi{background:var(--panel);padding:11px 12px}
32:.kpi .n{font-size:19px;color:var(--ink-face)}
33:.kpi .l{font-size:10px;color:var(--ink-dim);text-transform:uppercase;letter-spacing:.13em}
34:.kpi.inf .n{color:var(--inf)} .kpi.alive .n{color:var(--alive)} .kpi.dead .n{color:var(--dead)}
35:.dash{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:8px 0 6px}
36:.pan{background:var(--panel);border:1px solid var(--line);padding:14px 15px}
37:.pan h3{margin:0 0 10px;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-face);font-weight:700}
38:.brow{display:grid;grid-template-columns:150px 1fr 66px 44px;align-items:center;gap:9px;font-size:11.5px;margin-bottom:3px}
39:.brow .bl{color:var(--ink-dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
40:.btrack{height:9px;background:var(--panel2);border:1px solid var(--line)}
41:.bfill{display:block;height:100%}
42:.brow .bb{text-align:right;color:var(--ink-face)} .brow .bp{text-align:right;color:var(--ink-dim)}
43:.seg-inv{background:var(--inv)} .seg-rec{background:var(--rec)} .seg-med{background:var(--med)}
44:.seg-mod{background:var(--mod)} .seg-oth{background:var(--oth)}
45:.callout{border-left:3px solid var(--med);background:var(--panel2);padding:9px 12px;margin-top:10px;font-size:12px;color:var(--ink)}
46:.callout b{color:var(--med)}
47:.hist{display:flex;align-items:flex-end;gap:3px;height:110px;margin-top:6px}
48:.hbar{flex:1;background:var(--amber);min-height:2px;opacity:.85}.hbar:hover{opacity:1}
49:.hlabels{display:flex;gap:3px;margin-top:4px}
50:.hlabels span{flex:1;font-size:8.5px;color:var(--ink-dim);text-align:center;overflow:hidden;white-space:nowrap}
51:.controls{position:sticky;top:0;z-index:5;background:var(--bg);padding:14px 0 10px;border-bottom:1px solid var(--line);margin-top:26px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
52:.controls input,.controls select{background:var(--panel);border:1px solid var(--line);color:var(--ink);font-family:inherit;font-size:13px;padding:6px 9px}
53:.controls input{flex:1;min-width:180px}
54:.fbtns{display:flex;gap:1px;border:1px solid var(--line)}
55:.fbtn{background:var(--panel);color:var(--ink-dim);border:none;font-family:inherit;font-size:11px;letter-spacing:.1em;text-transform:uppercase;padding:6px 11px;cursor:pointer}
56:.fbtn.on{background:var(--amber);color:#141613}
57:.count{color:var(--ink-dim);font-size:11.5px;white-space:nowrap}
58:.tablewrap{border:1px solid var(--line);border-top:none;background:var(--panel)}
64:.rk{color:var(--amber-dim);width:38px;text-align:right}
65:.pn b{color:var(--ink-face);font-weight:700}
66:.pn .ac{display:block;font-size:10.5px;color:var(--ink-dim)}
68:.bar{display:flex;height:10px;width:150px;background:var(--panel2);border:1px solid var(--line);overflow:hidden}
69:.bar .seg{height:100%;display:block}
70:.pill{font-size:9.5px;letter-spacing:.1em;padding:2px 7px;border:1px solid;text-transform:uppercase;white-space:nowrap}
71:.st-alive{color:var(--alive);border-color:var(--alive)} .st-inf{color:var(--inf);border-color:var(--inf)} .st-dead{color:var(--dead);border-color:var(--dead)}
73:.detail{padding:16px 18px}
74:.metrics{display:grid;grid-template-columns:repeat(5,1fr);gap:1px;background:var(--line);border:1px solid var(--line);margin-bottom:14px}
75:.m{background:var(--panel);padding:7px 9px}
76:.m .ml{display:block;font-size:9.5px;text-transform:uppercase;letter-spacing:.1em;color:var(--ink-dim)}
77:.m .mv{color:var(--ink-face);font-size:13px}
78:.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
79:.block .eyebrow{margin-bottom:7px;display:block}.block.wide{grid-column:1/-1}
80:.chips{display:flex;flex-wrap:wrap;gap:5px}
81:.chip{font-size:11px;padding:2px 7px;border:1px solid var(--line);background:var(--panel);color:var(--ink)}
82:.chip.mod{border-color:var(--mod);color:var(--mod)}
83:.skills{display:grid;gap:4px}
84:.skill{display:grid;grid-template-columns:108px 1fr 20px;align-items:center;gap:8px;font-size:11.5px}
85:.sk-name{color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
86:.sk-bar{height:6px;background:var(--panel);border:1px solid var(--line)}.sk-fill{display:block;height:100%;background:var(--amber)}
87:.sk-lvl{text-align:right;color:var(--ink-face)}
88:.kvlist{display:grid;gap:2px}
89:.kv{display:flex;justify-content:space-between;gap:10px;font-size:11px;border-bottom:1px dotted var(--line);padding-bottom:2px}
90:.kv .k{color:var(--ink-dim)} .kv .v{color:var(--ink);text-align:right}
91:.inv{display:grid;grid-template-columns:1fr 1fr;gap:2px 20px}
92:.irow{display:flex;gap:7px;align-items:baseline;font-size:11.5px;border-bottom:1px dotted var(--line);padding:2px 0}
93:.itype{color:var(--ink-face)} .ix{color:var(--amber);font-size:10.5px} .icust{color:var(--ink-dim)}
94:.worn{display:grid;gap:2px}
95:.wrow{display:flex;gap:7px;font-size:11px;padding:1px 0}
96:.slot{color:var(--ink-dim);min-width:118px} .arrow{color:var(--amber-dim)} .witem{color:var(--ink)}
97:.fbrow{display:grid;grid-template-columns:150px 1fr 60px 42px;align-items:center;gap:9px;font-size:11px}
98:.fbl{color:var(--ink-dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
99:.fbt{height:7px;background:var(--panel);border:1px solid var(--line)}.fbf{display:block;height:100%}
100:.fbb{text-align:right;color:var(--ink-face)} .fbp{text-align:right;color:var(--ink-dim)}
103:.footer{margin-top:40px;padding-top:14px;border-top:1px solid var(--line);color:var(--ink-dim);font-size:11px;max-width:80ch}
106:</style></head><body>
107:<div class="wrap">
115: <div id="kpis" class="kpis"></div>
117:  <div class="pan"><h3>What the whole database is made of</h3><div id="aggSec"></div><div id="callout"></div></div>
118:  <div class="pan"><h3>Heaviest mod tables (server-wide)</h3><div id="aggMod"></div></div>
Bash Read getFileWriter implementation
IN
grep -n "getFileWriter" "c:/VSCodeProjects/PZMod/PZ_Engine_Decompiled/zombie/Lua/LuaManager.java" | head; echo "---"; sed -n '/public static BufferedWriter getFileWriter/,/^   }/p' "c:/VSCodeProjects/PZMod/PZ_Engine_Decompiled/zombie/Lua/LuaManager.java" | head -60

OUT
5444:        @LuaMethod(name="getFileWriter", global=true)
5445:        public static LuaFileWriter getFileWriter(String filename, boolean createIfNull, boolean append) {
---
Bash Compare UserPanelHook files
IN
cd "c:/VSCodeProjects/PZMod" && echo "=== RCUserPanelHook"; cat "Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCUserPanelHook.lua"; echo; echo "=== LRUserPanelHook"; cat "Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRUserPanelHook.lua"

OUT
=== RCUserPanelHook
-- RCUserPanelHook.lua (client)
--
-- Adds a "My Vehicles" button to the TOP of the vanilla Client panel
-- (ISUserPanelUI) - the owner-specced entry point for the fleet panel
-- (management lives here, NOT on the vehicle right-click menu).
--
-- WHY the top (not above Close): the bottom of the panel is its most contested
-- region - vanilla's two ISTickBox controls resize TALLER than a standard button
-- (ISTickBox:addOption sets height = itemHgt, which includes an extra gap) while
-- create() only advances y by the standard button height, so its accounting
-- under-counts there, AND other mods append their own controls in the same spot.
-- A button inserted into that zone overlapped the tick-boxes. The top row is
-- uncontested, so we insert there and push every existing control down one row.
--
-- MP-only by design: the Client button that opens ISUserPanelUI only exists for
-- network clients (matches Reclamation's dedicated-MP scope).
--
-- Post-hooks create() (no vanilla edits) with our own onclick closure. Mirrors
-- Last Rites' LRUserPanelHook, which does the identical top-insert - when both
-- mods are present they simply stack at the top, in load order.

if isServer() and not isClient() then return end

require "ISUI/UserPanel/ISUserPanelUI"

local UI_BORDER_SPACING = 10

local _create = ISUserPanelUI.create
function ISUserPanelUI:create()
    _create(self)

    if not RCShared.cfg().claimsEnabled then return end

    -- cancel (Close) is a reliable, width-normalized standard button we borrow
    -- dimensions from.
    local cancel = self.cancel
    if not cancel then return end

    if not self.rcBtn then
        local w, h = cancel:getWidth(), cancel.height
        local ROW = h + UI_BORDER_SPACING

        -- current topmost control (all controls sit below the title text, which
        -- is drawn in render(), not a child, so it never moves)
        local topY
        for _, c in pairs(self:getChildren()) do
            local cy = c:getY()
            if topY == nil or cy < topY then topY = cy end
        end
        if not topY then return end

        -- free the top row: push every existing control (incl. any other mod's
        -- button already inserted here) down by one row
        for _, c in pairs(self:getChildren()) do
            c:setY(c:getY() + ROW)
        end

        local btn = ISButton:new(cancel.x, topY, w, h, getText("IGUI_RC_MyVehicles"), self,
            function(target) RCMyVehicles.open(target.player or getPlayer()) end)
        btn.internal    = "RCMYVEHICLES"
        btn.borderColor = self.buttonBorderColor
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)   -- added AFTER the push, so it stays at topY
        self.rcBtn = btn
    end

    -- Grow the panel to fit its lowest control (robust vs. the other hook + the
    -- taller-than-accounted tick-boxes), so nothing spills past the background.
    local maxBottom = 0
    for _, c in pairs(self:getChildren()) do
        local b = c.getBottom and c:getBottom()
        if b and b > maxBottom then maxBottom = b end
    end
    if maxBottom > 0 then self:setHeight(maxBottom + UI_BORDER_SPACING + 1) end
end

=== LRUserPanelHook
-- LRUserPanelHook.lua  (client)
--
-- Adds a "Last Rites" button to the TOP of the vanilla Client panel
-- (ISUserPanelUI). The button opens the LRHub window.
--
-- WHY the top (not above Close): the bottom of the panel is contested - vanilla's
-- ISTickBox controls resize taller than a standard button while create() only
-- advances y by the standard height (so its accounting under-counts there), and
-- other mods append their own controls in the same spot. A button inserted there
-- overlapped the tick-boxes. The top row is uncontested: we insert there and push
-- every existing control down one row. Reclamation's RCUserPanelHook does the
-- identical top-insert, so when both mods are present they simply stack.
--
-- MP-only by design: the on-screen Client button that opens ISUserPanelUI only
-- exists for network clients (see vanilla ISEquippedItem.lua, the whole button
-- stack is gated by `if isClient()`). Matches the intended scope.
--
-- We post-hook create() (no vanilla file edits) with our own onclick closure.

require "ISUI/UserPanel/ISUserPanelUI"

local UI_BORDER_SPACING = 10

local _create = ISUserPanelUI.create
function ISUserPanelUI:create()
    _create(self)

    -- cancel (Close) is a reliable, width-normalized standard button we borrow
    -- dimensions from.
    local cancel = self.cancel
    if not cancel then return end

    if not self.lrBtn then
        local w, h = cancel:getWidth(), cancel.height
        local ROW = h + UI_BORDER_SPACING

        -- current topmost control (all controls sit below the title text, which
        -- is drawn in render(), not a child, so it never moves)
        local topY
        for _, c in pairs(self:getChildren()) do
            local cy = c:getY()
            if topY == nil or cy < topY then topY = cy end
        end
        if not topY then return end

        -- free the top row: push every existing control (incl. any other mod's
        -- button already inserted here) down by one row
        for _, c in pairs(self:getChildren()) do
            c:setY(c:getY() + ROW)
        end

        local btn = ISButton:new(cancel.x, topY, w, h, getText("IGUI_LR_Panel"), self,
            function(target) LRHub.toggle(target.player or getPlayer()) end)
        btn.internal    = "LASTRITES"
        btn.borderColor = self.buttonBorderColor
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)   -- added AFTER the push, so it stays at topY
        self.lrBtn = btn
    end

    -- Grow the panel to fit its lowest control (robust vs. the other hook + the
    -- taller-than-accounted tick-boxes), so nothing spills past the background.
    local maxBottom = 0
    for _, c in pairs(self:getChildren()) do
        local b = c.getBottom and c:getBottom()
        if b and b > maxBottom then maxBottom = b end
    end
    if maxBottom > 0 then self:setHeight(maxBottom + UI_BORDER_SPACING + 1) end
end
Bash Head of tools scripts
IN
echo "=== pzbasements.py head ==="; sed -n '1,30p' "/c/VSCodeProjects/PZMod/tools/pzbasements.py"; echo; echo "=== pzbasements_inject.py head ==="; sed -n '1,25p' "/c/VSCodeProjects/PZMod/tools/pzbasements_inject.py"; echo; echo "=== cmdscan.py head ==="; sed -n '1,40p' "/c/VSCodeProjects/PZMod/tools/cmdscan/cmdscan.py"

OUT
=== pzbasements.py head ===
#!/usr/bin/env python3
r"""pzbasements.py - parse a PZ B42 map_basements.bin (basement placements + building/room defs).

Format per zombie/basements/Basements.java (loadSavefile/writeSavefile), all big-endian
DataOutputStream primitives:

  4 bytes  magic "BSMT"
  i32      world version (written 247, ignored on load)
  i32      savefile version (written 1, ignored on load)
  i32      placementCount
    per placement: i32 x, i32 y, i32 z, i16 w, i16 h, javaUTF name
  i32      buildingCount
    per building: i16 roomCount
      per room: javaUTF name, i8 level, i16 rectCount
        per rect: i16 x, i16 y, i16 w, i16 h

Rect coords in building defs are world-absolute (createBasementBuildingDefs adds the
placement origin before writing); room level is world z (placement z + room level).

Usage:
  python pzbasements.py <path\to\map_basements.bin> [--json]
  python pzbasements.py <bin> --find 9698,9668,-1 [--find x,y,z ...]
  python pzbasements.py <bin> --remove 9698,9668,-1 [...] --out new.bin

--find locates a placement by its exact origin and reports: the placement, its
paired surface-access placement (the entry written immediately after it by
calculateBasementPlacements), the building defs whose rects fall inside the
footprints, and the save chunk files (map/<wx>/<wy>.bin, chunk = 8x8 tiles)
covering the footprints at the engine's own w+1/h+1 wall margin.


=== pzbasements_inject.py head ===
#!/usr/bin/env python3
r"""pzbasements_inject.py - additively inject a map mod's procedural basements into an
existing map_basements.bin, so their rooms register (restoring power) on a world where
the bin was written before the mod went procedural.

Reproduces the engine's own math (zombie.basements.Basements):
  placement.x = spawn.x - def.stairx        (spawn w=h=1 => the 'else' branch)
  placement.y = spawn.y - def.stairy
  placement.z = spawn.z(0) - header.levels
  placement.w/h = building bounding box (getW/getH) from the .pzby
  building def room:  level = placement.z + room.level  (absolute z)
                      rect  = (placement.x+rx, placement.y+ry, rw, rh)  (absolute)
  (rooms named exactly "emptyoutside" would be excluded; none here.)

STRICTLY ADDITIVE: existing placements/defs are copied verbatim; the mod's basements are
appended. Writes to a NEW file and parse-back-verifies. Never touches the input bin.

Usage:
  python pzbasements_inject.py <in.bin> <mod_map_dir> <out.bin>
    mod_map_dir = ...\Clover Lake\common\media\maps\Clover Lake  (has basements.lua)
    binmap .pzby resolved as <mod_map_dir>\..\..\binmap\<name>.pzby
"""
import os
import re
import struct

=== cmdscan.py head ===
#!/usr/bin/env python3
"""
cmdscan - forensic scanner for Project Zomboid B42 server client-command logs.

WHY THIS EXISTS
---------------
PZ has no way to *veto* a client command in Lua: the engine's
GameServer.receiveClientCommand() fires OnClientCommand to EVERY registered
handler unconditionally (Event.trigger wraps each callback in its own
try/catch and discards the return value), so a mod cannot stop another mod's
handler from running. A player who installs a local Lua mod can therefore
call any admin-facing function that trusts the client (e.g.
AdminVehicleSpawner.spawnVehicle, ParanormalZ.* admin ops, mod teleport
handlers) and the vulnerable handler WILL execute.

But every one of those calls is logged, server-side, tamper-proof, at the
receive point BEFORE any Lua runs:

    LoggerManager.getLogger("cmd").write(
        connIDStr + " \"" + username + "\" " + module + "." + command
        + " @ " + x + "," + y + "," + z)

That produces <date>_<time>_cmd.txt in the server Logs dir. This tool reads
those files and flags:

  1. SENSITIVE - an admin-only action (curated glob list) issued by a
                   SteamID that is not on the admin allowlist. Highest signal.
  2. FLOOD - the same (SteamID, action) repeated past a rate threshold
                   inside a time window (catches griefing / spam even for
                   actions not on the sensitive list). 1957x spawnVehicle
                   trips this by three orders of magnitude.
  3. UNKNOWN - (optional, needs --baseline) an action never seen in a
                   known-good baseline. Catch-all for unknown-unknowns.

It is DETECTIVE, not preventive: it runs on server restart (or live-tailed)
and tells you who to kick/ban. Prevention isn't available to us in Lua.

Stdlib only. Python 3.8+.
"""
Bash Find file writers / json / sanitizers
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "getFileWriter\|getFileReader\|safeName\|sanitize\|jsonEncode\|encodeJSON\|json\b" --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived | head -60

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:73:local function sanitize(t)
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:98:    if dropped > 0 then dbg("sanitize dropped " .. dropped .. " malformed record(s)") end
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:104:        store = sanitize(ModData.getOrCreate("RQDormant"))
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:112:    store = sanitize(ModData.getOrCreate("RQDormant"))
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua:8:--   2. getFileWriter is the only file API that works on BOTH sides in B42
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua:38:        local writer = getFileWriter(FILE, true, true)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua:306:    -- (Lua/Memoirs/<player>/latest.json). Lives on row 1 because row 2 is full.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTours.lua:163:        local w = getFileWriter(FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTours.lua:174:        local r = getFileReader(FILE, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:45:    -- the file is on disk and getFileReader can open it. Trust the reader.
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:46:    local reader = getFileReader(OVERRIDES_FILE, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:63:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:67:    -- can return false even when the file is on disk and getFileReader can open
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:69:    local reader = getFileReader(OVERRIDES_FILE, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:96:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:15:--   Memoirs/<SafeName>/latest.json   newest snapshot-bearing record (overwritten;
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:20:-- Nested dirs are ENGINE-GUARANTEED: getFileWriter runs File.mkdirs() on the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:21:-- full parent chain (LuaManager.getFileWriter, verified in the 42.19 decompile),
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:22:-- and only ".." paths are refused (safeName can't emit dots). The flat fallback
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:25:-- getFileWriter is the ONLY server-side I/O that works in B42 (raw io.open is
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:46:local function safeName(name)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:103:local function jsonEncode(v)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:111:            for i, item in ipairs(v) do out[i] = jsonEncode(item) end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:119:            out[#out + 1] = '"' .. jsonEscape(k) .. '":' .. jsonEncode(v[k])
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:154:local layoutByUser = {}   -- safeName -> "nested" | "flat"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:158:    pcall(function() w = getFileWriter(DIR .. path, true, append) end)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:248:    local safe = safeName(user)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:256:    local jsonLine = jsonEncode(rec)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:259:    -- 2) latest.json - overwritten whenever this event carries a snapshot; the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:262:        writeLine(userWriter(safe, "latest.json", false), jsonLine)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:3:-- PROGRESSION. MMAudit's per-player archive (latest.json) carries the full
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:19:-- JSON decoder: parses OUR OWN encoder's output only (MMAudit.jsonEncode -
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:32:-- must mirror MMAudit's safeName so we find the same files
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:33:local function safeName(name)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:142:        local br = getFileReader(DIR .. path, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:158:    return readAll(safe .. "/latest.json") or readAll(safe .. ".latest.json")
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:193:    local content = readLatest(safeName(targetUsername))
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMRestore.lua:202:    -- safeName collisions map two usernames onto one file; the envelope's user
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua:18:--      but B42's Translator loads .json only (the one path template in
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua:19:--      zombie.core.Translator is "%s/media/lua/shared/Translate/%s/%s.json"),
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua:22:--      Print_Media.json + Print_Text.json (the Translator merges every active
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua:36:-- REMOVABLE: delete this file plus Translate/EN/Print_Media.json and
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFPatch_Frogtown.lua:37:-- Print_Text.json to drop the patch. If Frogtown fixes the key upstream,
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua:6:-- B42 only exposes getFileWriter/getFileReader for Lua file I/O (io.open is
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua:46:    local r = getFileReader(FILE, false)  -- false = don't create if missing
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua:59:    local w = getFileWriter(FILE, true, false)  -- create, don't append
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:11:-- recording every fill/in/out/destroy with quantities, via getFileWriter (the only file I/O that
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:34:        local w = getFileWriter(BX.LOGFILE, true, true) -- createIfNull, append (never truncate)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua:27:-- Audit log filename, written to Zomboid/Lua/ via getFileWriter (the only file I/O that works in
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:6:-- writing its own encrypted OSN-Debug.txt into Zomboid/Lua/ (client sandbox: getFileWriter, no luajava).
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:17:    -- getFileReader reads from Zomboid/Lua/ ; returns nil when the file is absent.
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:18:    local ok, r = pcall(getFileReader, Config.CLIENT_SENTINEL, false)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:16:--   * getFileWriter is the only file I/O that works server-side in B42; open-write-close per row so each
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:19:-- Row format: "|"-delimited, fixed columns, every field sanitized (strips "|", tab, CR, LF) so a crafted
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:123:        local w = getFileWriter(fileName, true, true)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:3:-- Uses the engine-blessed getFileWriter API on BOTH sides (server + client). The old RQDirgeLog
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:6:-- getFileWriter works on the dedicated server too (cf. Bumblebee_FastMoveWhitelist) and writes to
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:30:        local w = getFileWriter(fileName, true, true)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:87:-- No-op: getFileWriter open-write-close per line means every line is already flushed to disk.
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNSizer.lua:5:-- modeled on Deadband's sanitizeForWire walker. Good enough to RANK offenders, never exact.
Bash Read getFileWriter body
IN
sed -n '5440,5490p' "c:/VSCodeProjects/PZMod/PZ_Engine_Decompiled/zombie/Lua/LuaManager.java"

OUT
        public static String lineSeparator() {
            return System.lineSeparator();
        }

        @LuaMethod(name="getFileWriter", global=true)
        public static LuaFileWriter getFileWriter(String filename, boolean createIfNull, boolean append) {
            File outFile;
            if (GlobalObject.hasRelativePath(filename)) {
                return null;
            }
            Object str = LuaManager.getLuaCacheDir() + File.separator + filename;
            str = ((String)str).replace("/", File.separator);
            str = ((String)str).replace("\\", File.separator);
            String dir = ((String)str).substring(0, ((String)str).lastIndexOf(File.separator));
            File f = new File(dir = dir.replace("\\", "/"));
            if (!f.exists()) {
                f.mkdirs();
            }
            if (!(outFile = new File((String)str)).exists() && createIfNull) {
                try {
                    outFile.createNewFile();
                }
                catch (IOException ex) {
                    Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                }
            }
            PrintWriter output = null;
            try {
                FileOutputStream fos = new FileOutputStream(outFile, append);
                OutputStreamWriter osw = new OutputStreamWriter((OutputStream)fos, StandardCharsets.UTF_8);
                output = new PrintWriter(osw);
            }
            catch (IOException ex) {
                Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                return null;
            }
            return new LuaFileWriter(output);
        }

        @LuaMethod(name="getSandboxFileWriter", global=true)
        public static LuaFileWriter getSandboxFileWriter(String filename, boolean createIfNull, boolean append) {
            File outFile;
            if (GlobalObject.hasRelativePath(filename)) {
                return null;
            }
            Object str = LuaManager.getSandboxCacheDir() + File.separator + filename;
            str = ((String)str).replace("/", File.separator);
            str = ((String)str).replace("\\", File.separator);
            String dir = ((String)str).substring(0, ((String)str).lastIndexOf(File.separator));
            File f = new File(dir = dir.replace("\\", "/"));
            if (!f.exists()) {
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\DFPlayerRoles_Server.lua (lines 186-245)
Bash Read RCAudit and OSNLog
IN
cd "c:/VSCodeProjects/PZMod" && echo "===== RCAudit"; cat "Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCAudit.lua"; echo "===== OSNLog head 60"; sed -n '1,60p' "OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua"

OUT
===== RCAudit
-- RCAudit - durable append-only ledger (server only).
--
-- getFileWriter is the ONLY working B42 server-side file I/O (raw io.open is
-- silently blocked). Every authoritative claim mutation writes one
-- bracket-stamped key=value line here, so cheating / disputes are resolved by
-- the ledger rather than by fragile server-veto.

if not isServer() then return end

RCAudit = RCAudit or {}

local FILE = "RFTDReclamation_Dismantle.txt"

local function stamp()
    local ok, s = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok and s then return s end
    return tostring(os.time())
end

-- log(action, player|nil, kv|nil)
--   action : short verb, e.g. "CLAIM", "UNCLAIM", "CLAIM-DENY", "EXPIRE"
--   player : the actor (nil for system events like expiry)
--   kv     : table of extra fields (sorted for stable output) or a string
function RCAudit.log(action, player, kv)
    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
    if not ok or not writer then return end

    local user = (player and player.getUsername and player:getUsername()) or "-"
    local parts = { string.format("[%s] action=%s user=%s", stamp(), tostring(action), tostring(user)) }

    if type(kv) == "table" then
        local keys = {}
        for k in pairs(kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(kv[k]))
        end
    elseif kv ~= nil then
        parts[#parts + 1] = tostring(kv)
    end

    pcall(function()
        writer:write(table.concat(parts, " ") .. "\n")
        writer:close()
    end)
end
===== OSNLog head 60
-- OSNLog.lua - Omen's Spy Network: dedicated, self-archiving log writer (plaintext by default).
--
-- Uses the engine-blessed getFileWriter API on BOTH sides (server + client). The old RQDirgeLog
-- pattern (getHomeDir + luajava java.io.FileWriter, io.open fallback) is dead in B42: the Lua
-- sandbox blocks raw java.io / io.open server-side, so that path silently wrote nothing for ages.
-- getFileWriter works on the dedicated server too (cf. Bumblebee_FastMoveWhitelist) and writes to
-- the Zomboid/Lua/ folder; we open-write-close per line so each line is flushed to disk immediately.
--
-- SELF-ARCHIVING (GuardianLogger-style, so tuning history is never lost):
--   * Own subfolder: Lua/<LOG_DIR>/ .
--   * Timestamped, SIDE-tagged filenames: <date>_<LOG_BASENAME>_<SIDE>_<time>.txt (collisions get _N).
--   * A fresh file per session (OnGameStart) AND a roll to a new file past LOG_MAX_BYTES. Old files are
--     NEVER reopened, appended across sessions, or truncated -- once rolled off, a file is frozen history.
--   * Each line carries a human-readable date+time and the precise ts_ms; a "# ..." header names the file.
-- Encryption is opt-in via Config.CRYPTO_ENABLED (default OFF -> plaintext, no tools/osn.py needed).

OmenSpyNetwork = OmenSpyNetwork or {}
OmenSpyNetwork.Log = OmenSpyNetwork.Log or {}
local Log    = OmenSpyNetwork.Log
local Config = OmenSpyNetwork.Config or require("OSNConfig")
local Crypto = OmenSpyNetwork.Crypto or require("OSNCrypto")

local SIDE = isServer() and "SV" or "CL"

-- Append one already-finished wire line to a file (createIfNull=true, append=true -- NEVER truncates, so
-- older logs stay frozen). open-write-close per line flushes immediately. Returns bytes written (line+CRLF).
local function append(fileName, line)
    local wrote = 0
    pcall(function()
        local w = getFileWriter(fileName, true, true)
        if w then
            w:write(line .. "\r\n")
            w:close()
            wrote = #line + 2
        end
    end)
    return wrote
end

-- A fresh, unique, timestamped filename inside the OSN subfolder (never collides/overwrites). SIDE-tagged
-- so a co-located client + server never share a file. Mirrors GuardianLogger's newFileName().
local function newFileName()
    local d, t
    if os and os.date then d = os.date("%Y-%m-%d"); t = os.date("%H-%M-%S") end
    local stem = (Config.LOG_BASENAME or "OSN-Debug") .. "_" .. SIDE
    local base = (d and t) and (d .. "_" .. stem .. "_" .. t)
                 or (stem .. "_" .. tostring(getTimestampMs and getTimestampMs() or 0))
    local dir  = Config.LOG_DIR or "OSN"
    local name, n = dir .. "/" .. base .. ".txt", 1
    while cacheFileExists and cacheFileExists(name) do
        n = n + 1
        name = dir .. "/" .. base .. "_" .. n .. ".txt"
    end
    return name
end

local HEADER = "# OmenSpyNetwork OSN-Debug v2 side=" .. SIDE ..
               " enc=" .. (Config.CRYPTO_ENABLED and "minstd-add -- decrypt with tools/osn.py" or "none -- plaintext")

-- Live rotating writer: opens a new timestamped file on first use or past LOG_MAX_BYTES, header first.
Bash List Dragonfly lua tree and mod.info
IN
ls -R "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/" | head -60; echo "=== mod.info ==="; cat "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/mod.info" 2>/dev/null

OUT
c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/:
client
server
shared

c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/client:
DFBanBox_Notice.lua
DFColumns.lua
DFConfirm.lua
DFConsoleTab.lua
DFCoordOverlay.lua
DFDebugGate.lua
DFEngineLock.lua
DFErrorPoller.lua
DFFeedback.lua
DFItemEditor.lua
DFLog.lua
DFMedicalCheck.lua
DFPanel.lua
DFPatch_CleanUI.lua
DFPatch_Greenport.lua
DFPlayerInventoryModal.lua
DFPlayersTab.lua
DFRegistry.lua
DFRoleEditorUnlock.lua
DFRolesTab.lua
DFSafehouseDestroyPatch.lua
DFScoreboard.lua
Longstrider
MMClient.lua
MMContext.lua
MMStatsView.lua

c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider:
LSGridOverlay.lua
LSMap.lua
LSTab.lua
LSTour.lua
LSTours.lua

c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/server:
DFBanBox.lua
DFEngineLock_Server.lua
DFInventory_Server.lua
DFPatch_AntiCheatLogNoise.lua
DFPatch_Greenport_Server.lua
DFPatch_JM3Archery.lua
DFPatch_PhunLewt.lua
DFPatch_RVInterior.lua
DFPatch_SOTO.lua
DFPatch_Spongies.lua
DFPlayerRoles_Server.lua
DFPlayersTab_Server.lua
DFRoleEdit_Server.lua
DFServer.lua
DFZombiesTab_Server.lua
MMServer.lua
Memoirs

c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs:
=== mod.info ===
name=Requiem of the Dead: Dragonfly
id=Dragonfly
modversion=0.6.3
description=Admin command center for the Requiem of the Dead mod family. Tabbed admin panel (default Shift+U keybind) plus an ESC scoreboard extension, with an unlocked built-in role editor so admins can grant/revoke capabilities on existing roles (User, Moderator, etc.) without creating custom roles and reassigning players. Other RFTD mods (Reaper, Husbandry, Dirge) register tabs and per-row actions into Dragonfly when installed; each mod still works standalone. Includes the SledgehammerOnlyInSafehouse anti-grief fix (formerly the standalone Ladybug mod) and the Memoir, a craftable character snapshot/restore journal that records your skills, traits, and recipes and recalls them after death, with a server-tunable XP restore percentage. Also includes per-family timed-action speed scaling (reading, foraging, cleaning, repair, dismantle), a keybindable gate that hides admin/debug right-click options to declutter the context menu, and a server-side item BanBox: a neutral engine that strips banned item types from loot at startup and can optionally confiscate carried banned items when a player logs in, with the ban list itself supplied by the bundled opt-in BBLibrary submod or your own. Designed for dedicated multiplayer servers.
pzversion=42
Bash Find translate json files
IN
cd "c:/VSCodeProjects/PZMod" && find . -path ./PZ_Engine_Decompiled -prune -o -name "*.json" -print | grep -i translate | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived | sort

OUT
./Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/Translate/EN/IG_UI.json
./Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/Translate/EN/Recipes.json
./Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/Translate/EN/Sandbox.json
./Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/Translate/EN/Tooltip.json
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/Translate/EN/IG_UI.json
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/Translate/EN/Sandbox.json
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/Translate/EN/ItemName.json
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/Translate/EN/Print_Media.json
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/Translate/EN/Print_Text.json
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/Translate/EN/Recipes.json
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/Translate/EN/Sandbox.json
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/Translate/EN/Sandbox.json
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/shared/Translate/EN/IG_UI.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/Fluids.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/ItemName.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/Recipes.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/Sandbox.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/Tooltip.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/EN/UI.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/Fluids.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/ItemName.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/Recipes.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/Sandbox.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/Tooltip.json
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/Translate/ES/UI.json
./Reaper/Contents/mods/RFTDReaper/42/media/lua/shared/Translate/EN/Sandbox.json
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/Translate/EN/IG_UI.json
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/Translate/EN/Sandbox.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/ContextMenu.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/Fluids.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/IG_UI.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/ItemName.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/Recipes.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/Sandbox.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/Tooltip.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/CN/UI.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/Fluids.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/IG_UI.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/ItemName.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/Recipes.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/Sandbox.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/Tooltip.json
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/Translate/EN/UI.json
Grep "newCharacter|firstSpawn|new life|lifeId|sameLife|SAMELIFE|isNewCharacter|hoursSurvived|getHoursSurvived" (in c:\VSCodeProjects\PZMod, glob: *.lua)
15 lines of output
Bash Check BanBox login hooks
IN
grep -n "OnClientConnect\|OnPlayerConnect\|OnConnected\|OnCreatePlayer\|login\|Login" "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua" | head -20

OUT
85:-- Login confiscation (opt-in, server-side).
95:-- Gated by SandboxVars.RFTDDragonfly.BanBoxConfiscateOnLogin (default OFF) AND
107:    return cfg().BanBoxConfiscateOnLogin == true   -- default OFF
116:        dbg("scrub skip: confiscate-on-login is OFF (" .. tostring(who) .. ")")
167:-- player), and OnConnected/OnCreatePlayer BIND but don't fire on a remote join
195:        dbg("OnTick poll active (confiscate ON; scanning logins)")
234:        dbg("login scrub armed (standing OnTick poll, %dms interval, %d-min per-player cap)",
237:        print("[DFBanBox] login scrub: OnTick unavailable - scrub disabled")
Bash Sandbox options headers
IN
cd "c:/VSCodeProjects/PZMod" && for f in Cookbook/Contents/mods/RFTDCookbook/42/media/sandbox-options.txt Dirge/Contents/mods/RFTDDirge/42/media/sandbox-options.txt Dragonfly/Contents/mods/Dragonfly/42/media/sandbox-options.txt Husbandry/contents/mods/RFTDHusbandry/42/media/sandbox-options.txt OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/sandbox-options.txt Reaper/Contents/mods/RFTDReaper/42/media/sandbox-options.txt Reclamation/Contents/mods/RFTDReclamation/42/media/sandbox-options.txt; do echo "=== $f ($(wc -l < "$f") lines)"; head -28 "$f"; echo; done

OUT
=== Cookbook/Contents/mods/RFTDCookbook/42/media/sandbox-options.txt (2 lines)
-- sandbox-options for RFTDCookbook
-- VERSION = 1,

=== Dirge/Contents/mods/RFTDDirge/42/media/sandbox-options.txt (580 lines)
VERSION = 1,

/* =====================================================================
   Dirge sandbox options
   ---------------------------------------------------------------------
   All options live on a single "Dirge" sandbox tab. PZ B42 doesn't expose
   subpages to mod-declared options, so we use decoy boolean options as
   visual section headers. Toggling a header checkbox does nothing - the
   underscored label is what makes them read as dividers in the panel.
   ---------------------------------------------------------------------
   Order within the tab:
     1. Mod Settings  (Enabled, DebugMode, SpawnChance)
     2. Visuals       (Show... toggles for HUD/cast bar)
     3. Boss          (boss-specific + ShowBossRing)
     4. EMP           (EMP-specific + ShowEMPRing)
     5. Glutton       (Glutton-specific + DevourTime + ShowGluttonRing)
     6. Juggernaut    (Jugg-specific + aura values shared with boss/scav)
     7. Scavenger     (Scav-specific, sparse - reuses jugg + screamer values)
     8. Screamer      (Screamer-specific + scream values shared with boss/scav rage)
   Per-section options are alphabetized.
   ---------------------------------------------------------------------
   Eventual home: Dragonfly Admin panel will get a proper sectioned UI
   for these. The sandbox pattern here is the portable fallback.
   ===================================================================== */

/* ====================== Mod Settings ====================== */

option RFTDDirge.ModSettingsHeader

=== Dragonfly/Contents/mods/Dragonfly/42/media/sandbox-options.txt (528 lines)
VERSION = 1,

option RFTDDragonfly.Enabled
{
    type = boolean,
    default = true,
    page = RFTDDragonfly,
    translation = DF_Enabled,
}

option RFTDDragonfly.OpenKeybind
{
    type = integer,
    min = 0,
    max = 256,
    default = 22,
    page = RFTDDragonfly,
    translation = DF_OpenKeybind,
}

option RFTDDragonfly.OpenKeyRequiresShift
{
    type = boolean,
    default = true,
    page = RFTDDragonfly,
    translation = DF_OpenKeyRequiresShift,
}


=== Husbandry/contents/mods/RFTDHusbandry/42/media/sandbox-options.txt (56 lines)
VERSION = 1,

option RFTDHusbandry.Enable
{
    type = boolean,
    default = true,
    page = RFTDHusbandry,
    translation = RQHB_Enable,
}

option RFTDHusbandry.AnimalLifespanMode
{
    type = enum,
    numValues = 3,
    default = 2,
    page = RFTDHusbandry,
    translation = RQHB_AnimalLifespanMode,
}

option RFTDHusbandry.AnimalLifespanMultiplier
{
    type = integer,
    min = 1,
    max = 20,
    default = 4,
    page = RFTDHusbandry,
    translation = RQHB_AnimalLifespanMultiplier,
}

=== OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/sandbox-options.txt (33 lines)
VERSION = 1,

/* ============================================================
   Chandler - artisan soap & candle crafting, body odor, etc.
   ============================================================ */

option RFTDOddsandEnds.ChandlerEnable
{
    type = boolean,
    default = true,
    page = OE_Chandler,
    translation = RQOE_ChandlerEnable,
}

option RFTDOddsandEnds.ChandlerOdorAttraction
{
    type = boolean,
    default = true,
    page = OE_Chandler,
    translation = RQOE_ChandlerOdorAttraction,
}

/* ============================================================
   BoonBox - admin-spawned bottomless stash box
   ============================================================ */

option RFTDOddsandEnds.BoonBoxEnable
{

=== Reaper/Contents/mods/RFTDReaper/42/media/sandbox-options.txt (113 lines)
VERSION = 1,

option RFTDReaper.Enabled
{
    type = boolean,
    default = true,
    page = RFTDReaper,
    translation = RP_Enabled,
}

option RFTDReaper.CullEnabled
{
    type = boolean,
    default = true,
    page = RFTDReaper,
    translation = RP_CullEnabled,
}

option RFTDReaper.LogCulls
{
    type = boolean,
    default = true,
    page = RFTDReaper,
    translation = RP_LogCulls,
}

option RFTDReaper.DebugContextMenu
{

=== Reclamation/Contents/mods/RFTDReclamation/42/media/sandbox-options.txt (197 lines)
VERSION = 1,

/* =====================================================================
   Reclamation sandbox options (claim system + dismantle/engine-lock)
   ===================================================================== */

option RFTDReclamation.Enabled
{
    type = boolean,
    default = true,
    page = RFTDReclamation,
    translation = RC_Enabled,
}

option RFTDReclamation.Debug
{
    type = boolean,
    default = false,
    page = RFTDReclamation,
    translation = RC_Debug,
}

option RFTDReclamation.ClaimsEnabled
{
    type = boolean,
    default = true,
    page = RFTDReclamation,
    translation = RC_ClaimsEnabled,
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\server\MMServer.lua (lines 86-145)
Grep "function MMSnapshotCodec.capture" (in c:\VSCodeProjects\PZMod\Dragonfly)
71 lines of output
Bash Find SandboxVars readers
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "SandboxVars\." --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived | grep -v PZ_Engine | head -50

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQConfig.lua:68:    local sv = SandboxVars and SandboxVars.RFTDDirge
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:115:    local sv = SandboxVars and SandboxVars.RFTDDirge
./Dragonfly/Contents/mods/BBLibrary/42/media/lua/server/BBLibrary_Example.lua:19:-- Master toggle: SandboxVars.RFTDDragonfly.BanBoxEnabled (default ON) gates the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFDebugGate.lua:12:-- Config (SandboxVars.RFTDDragonfly):
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFDebugGate.lua:30:    return SandboxVars.RFTDDragonfly or {}
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua:17:-- Gated by SandboxVars.RFTDDragonfly.EngineLockEnabled (default ON).
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua:38:local function cfg() return SandboxVars.RFTDDragonfly or {} end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPanel.lua:283:    local s = SandboxVars.RFTDDragonfly or {}
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:20:-- Master toggle: SandboxVars.RFTDDragonfly.BanBoxEnabled (default ON). With the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:27:local function cfg() return SandboxVars.RFTDDragonfly or {} end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:95:-- Gated by SandboxVars.RFTDDragonfly.BanBoxConfiscateOnLogin (default OFF) AND
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFEngineLock_Server.lua:17:local function cfg() return SandboxVars.RFTDDragonfly or {} end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Spongies.lua:35:            local sv = SandboxVars and SandboxVars.SPNCharCustom
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFActionSpeed.lua:50:local function cfg() return SandboxVars.RFTDDragonfly or {} end
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:62:    local sv = SandboxVars and SandboxVars.RFTDDragonfly
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:86:    local sv = SandboxVars and SandboxVars.RFTDDragonfly
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:101:    local sv = SandboxVars and SandboxVars.RFTDDragonfly
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:704:    local enabled = SandboxVars and SandboxVars.RFTDHusbandry and SandboxVars.RFTDHusbandry.Enable
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBErrorMagnifier.lua:34:        local sv = SandboxVars and SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBKeepAlive.lua:19:-- Both gated by SandboxVars.RFTDHusbandry.Enable. When the toggle is off,
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBKeepAlive.lua:247:    local sv = SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBKeepAlive.lua:294:        local sv = SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBLifespan.lua:248:    local sv = SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua:37:    local sv = SandboxVars and SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua:52:    local sv = SandboxVars and SandboxVars.RFTDHusbandry
./Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBBedding.lua:62:    local sv = SandboxVars and SandboxVars.RFTDHusbandry
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_FatStateReplacement.lua:270:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_HomemadeBleachVoid.lua:199:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/SoapZ/SZ_PicnicBasketLoot.lua:247:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua:46:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Butchering.lua:191:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Crafting.lua:126:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua:196:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:363:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua:346:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua:378:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_Washing.lua:385:    local sv = SandboxVars and SandboxVars.RFTDOddsandEnds
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPContextMenu.lua:10:    local s = SandboxVars.RFTDReaper or {}
./Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPCore.lua:31:    local s = SandboxVars.RFTDReaper or {}
./Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPServer.lua:92:    local s = SandboxVars.RFTDReaper or {}
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCShared.lua:46:    local sv = SandboxVars and SandboxVars.RFTDReclamation or {}
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/MYBackpackPlusOverride.lua:16:    if SandboxVars and SandboxVars.MeiyaBackpack then
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/MYBackpackPlusOverride.lua:17:        return SandboxVars.MeiyaBackpack
Grep "notePresence|function RCRegistry.stampSeen" (in c:\VSCodeProjects\PZMod\Reclamation)
69 lines of output
Bash Find VERSION and MODULE constants
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "VERSION\s*=\|MODULE\s*=\|\.CMD\s*=\|local MODULE\|MOD_VERSION" --include=*.lua . | grep -v "Test/" | grep -v "_rollback" | grep -v zz_Archived | grep -v PZ_Engine | head -60

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua:33:local SCHEMA_VERSION = 1
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFEngineLock.lua:28:local LOG_MODULE = "DFEngineLock" -- client->server log mirror channel
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFItemEditor.lua:21:local MODULE = "RFTDDragonfly"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPatch_Greenport.lua:35:local MODULE = "DFGreenport"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayerInventoryModal.lua:20:local MODULE = "RFTDDragonfly"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFPlayersTab.lua:26:local MODULE = "RFTDDragonfly"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRoleEditorUnlock.lua:21:local MODULE = "Dragonfly_RoleEdit"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRoleEditorUnlock.lua:102:DFRoleEdit.MODULE = MODULE
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTab.lua:19:local MODULE_TAG = "[Dragonfly] LSTab"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFEngineLock_Server.lua:15:local LOG_MODULE = "DFEngineLock" -- must match client/DFEngineLock.lua
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPatch_Greenport_Server.lua:44:local MODULE = "DFGreenport"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:16:local MODULE = "Dragonfly_RoleEdit"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:14:DFCore.MODULE  = "RFTDDragonfly"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/DFCore.lua:15:DFCore.VERSION = "0.6.2"   -- 0.6.2: panel gate falls back to getAccessLevel (isAdmin() flaky on dedi clients)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:32:MMShared.MODULE = "RFTDDragonflyMemoir"
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:35:MMShared.CMD = {
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua:42:MMShared.SCHEMA_VERSION = 4 -- v4 adds snap.lifeId (same-life read guard); v3 faith; v2 nutrition
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/BXClient.lua:16:local MODULE = (DFCore and DFCore.MODULE) or "RFTDDragonfly"
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua:7:local CONTEXT_PATCH_VERSION = 3
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua:8:local TANK_WATER_PATCH_VERSION = 1
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua:14:BX.CMD = "RFTDBoonBox"
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShim_DFCompat.lua:14:if not DFCore.MODULE then DFCore.MODULE = "RFTDDragonfly" end
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPContextMenu.lua:7:local MODULE = "RFTDReaper"
./Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:23:local MODULE = "RFTDReaper"
./Reaper/Contents/mods/RFTDReaper/42/media/lua/server/RPServer.lua:20:local MODULE = "RFTDReaper"
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCShared.lua:12:RCShared.MODULE  = "RFTDReclamation"
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCShared.lua:13:RCShared.VERSION = "0.6.0"
./Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/items/Meiya'sCityWorldFiller.lua:3:overlayMap.VERSION = 1
Bash Check RQ token collision
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn '"RQ"' --include=*.lua Dirge Husbandry | head -20; echo "--- OSN/Cookbook/LR module"; grep -rn "MODULE\|CMD_\|sendClientCommand" --include=*.lua OmenSpyNetwork Cookbook "Last Rites" | head -20

OUT
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua:127:    sendClientCommand("RQ", "adminConvert", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua:179:    sendClientCommand("RQ", "adminInspect", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua:188:    if module ~= "RQ" then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQCore.lua:52:        sendClientCommand("RQ", "zombieKilled", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQCore.lua:204:    if module ~= "RQ" then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQGlutton.lua:154:            sendClientCommand("RQ", "eaterArrived", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:26:        sendClientCommand(getPlayer(), "RQ", "adminConvert", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReconcile.lua:146:    if module ~= "RQ" or command ~= "zombieDelta" then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:73:    sendClientCommand("RQ", "reflectPing", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQReflect.lua:280:    if module ~= "RQ" or command ~= "reflectTruth" then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQServer.lua:758:    if module ~= "RQ" then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:229:    sendServerCommand("RQ", "applyZombieHP", {
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:277:    sendServerCommand("RQ", cmd, args)
Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua:281:    sendServerCommand(player, "RQ", cmd, args)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:263:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_PROBE, { id = tostring(row.oid) })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:268:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.0, label = "refill" })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:298:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.9, label = "starve" })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:306:    if module ~= "RQ" then return end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBContextMenu.lua:25:            sendClientCommand(player, "RQ", HBCmd.ADD_SEEN, { id = tostring(oid) })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:734:    sendClientCommand(player, "RQ", HBCmd.DEBUG_REFILL, {
--- OSN/Cookbook/LR module
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:5:-- it to disarm. When armed it wraps sendClientCommand (outbound) and hooks OnServerCommand (inbound),
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:32:    if sendClientCommand and not OmenSpyNetwork._wrapSCC then
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:34:        local orig = sendClientCommand
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:35:        sendClientCommand = function(...)
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianTestEmit.lua:77:--   sendClientCommand("OSNGuardianTest", "emit", { access = "none",
OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNSizer.lua:42:-- sendClientCommand / sendServerCommand are overloaded with an OPTIONAL leading player arg.
Bash Show OnCreatePlayer usage contexts
IN
cd /c/VSCodeProjects/PZMod && grep -rn "OnCreatePlayer" --include=*.lua Dirge OddsAndEnds Dragonfly "Last Rites" Husbandry Reclamation Cookbook Sector7 Reaper -A 8 | head -70

OUT
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua:184:Events.OnCreatePlayer.Add(function(playerNum)
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-185-    createInstance(playerNum)
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-186-end)
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-187-
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-188-Events.OnGameStart.Add(clearInstances)
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-189-
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-190--- ========================
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-191--- Public API (called by RQScreamer)
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQMoodle.lua-192--- ========================
--
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua:503:    if Events and Events.OnCreatePlayer then
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua:504:        Events.OnCreatePlayer.Add(function()
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua-505-            tryPatchTankWaterAction()
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua-506-        end)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua-507-    end
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/client/SoapZ/SZ_WashingContext.lua-508-end
--
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua:364:if Events and Events.OnCreatePlayer then
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua:365:    Events.OnCreatePlayer.Add(onCreatePlayer)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-366-end
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-367-if Events and Events.OnGameStart then
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-368-    Events.OnGameStart.Add(learnForLocalPlayers)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-369-end
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-370-if Events and Events.OnPlayerUpdate then
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-371-    Events.OnPlayerUpdate.Add(Compat.learnCoffeeSoapForPlayer)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_LastCupCoffeeCompat.lua-372-end
--
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua:451:Events.OnCreatePlayer.Add(onCreatePlayer)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua-452-Events.OnGameStart.Add(learnForLocalPlayers)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua-453-if Events.OnLoad then
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua-454-    Events.OnLoad.Add(learnForLocalPlayers)
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua-455-end
OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/SoapZ/SZ_TraitRecipes.lua-456-Events.OnPlayerUpdate.Add(SoapZ.TraitRecipes.learnForPlayerThrottled)
--
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua:167:-- player), and OnConnected/OnCreatePlayer BIND but don't fire on a remote join
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-168--- here (the bounded "arm on connect" watcher printed "armed" then went silent
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-169--- forever - nothing ever armed it). The only event proven to fire server-side is
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-170--- OnTick (see DFPatch_RVInterior). So this is a STANDING OnTick poll - but kept
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-171--- cheap: it does real work at most once a second, skips already-handled players
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-172--- instantly, and gives up on any one player after WATCH_MAX_MS so a stuck loader
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-173--- never causes repeated scans. Time-based (getTimestampMs); keyed by onlineID so
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-174--- a relog (fresh id) is re-scrubbed.
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua-175-local WATCH_MAX_MS     = 5 * 60 * 1000  -- give up waiting for one player to load in
--
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:237:tryBind("OnCreatePlayer")     -- last-resort: fires on player object creation
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-238-
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-239--- Connect-only by design: we apply on server start and on the connect events
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-240--- above, and NOT on any recurring timer. Binding several connect events spans
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-241--- the join sequence, so whichever one fires after the player is ready triggers
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-242--- the (idempotent, cache-only) sweep. The old EveryOneMinute net is gone - it
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-243--- re-read the file and re-ran setRole on every in-game minute, which was
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-244--- needless overhead and re-introduced the mid-session desync assign() avoids.
Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua-245---
Bash Compare notify clients
IN
cd "c:/VSCodeProjects/PZMod" && echo "== RCNotify"; cat "Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCNotify.lua"; echo; echo "== DFFeedback"; cat "Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFFeedback.lua"

OUT
== RCNotify
-- RCNotify - server -> client halo feedback channel.
--
-- The server sends { key, error } under a "Notify" command; we resolve the
-- translation key and float it over the local player. Green for success, red
-- for a denial. This is the only feedback path for claim/deny/expiry results.

if isServer() and not isClient() then return end

RCNotify = RCNotify or {}

local function onServerCommand(module, command, args)
    if module ~= RCShared.MODULE then return end
    if command ~= "Notify" then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local key = (args and args.key) or "IGUI_RC_Generic"
    RCShared.halo(player, getText(key), args and args.error)
end

Events.OnServerCommand.Add(onServerCommand)

== DFFeedback
-- DFFeedback - HaloText wrappers for action feedback.
--
-- Result events from the server route through here so admins see whether an
-- action landed. addBadText for failures, addGoodText for successes. The
-- ChunkAdminControl reference mod was silent on both, which made debugging
-- impossible; this is the fix for that.

if isServer() then return end

DFFeedback = DFFeedback or {}

local function localPlayer()
    return getPlayer()
end

function DFFeedback.good(text)
    local p = localPlayer()
    if p and HaloTextHelper then
        HaloTextHelper.addGoodText(p, tostring(text or ""))
    end
end

function DFFeedback.bad(text)
    local p = localPlayer()
    if p and HaloTextHelper then
        HaloTextHelper.addBadText(p, tostring(text or ""))
    end
end

-- Server replies via sendServerCommand(module, "Result", {ok, action, reason}).
-- Consume it here so every command has visible feedback by default.
local function onServerCommand(module, command, args)
    if module ~= DFCore.MODULE or command ~= "Result" then return end
    args = args or {}
    if args.ok then
        if args.message then DFFeedback.good(args.message) end
    else
        DFFeedback.bad(args.reason or ("Action failed: " .. tostring(args.action or "?")))
    end
end

Events.OnServerCommand.Add(onServerCommand)
Read c:\VSCodeProjects\PZMod\Husbandry\contents\mods\RFTDHusbandry\42\media\lua\shared\HBData.lua (lines 101-150)
Bash Find byte-identical lua files across mods
IN
cd "c:/VSCodeProjects/PZMod" && echo "== identical-file scan across mods (by md5)"; find Reclamation Dragonfly Dirge Reaper Husbandry "Last Rites" OddsAndEnds Cookbook OmenSpyNetwork -name "*.lua" -type f -exec md5sum {} \; 2>/dev/null | sort | awk '{print $1}' | uniq -d | head -20

OUT
== identical-file scan across mods (by md5)
Bash Inspect scorecards HTML and RCEternalTorch
IN
cd /c/VSCodeProjects/PZMod && head -c 900 _Review/Scorecards/index.html; echo; echo "=== card count ==="; ls _Review/Scorecards/cards | wc -l; echo "=== RCEternalTorch ==="; sed -n '55,75p' Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua

OUT
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RFTD / Dragonfly - Source Mod Review</title><style>
:root{--bg:#0d1117;--panel:#161b22;--panel2:#1c2330;--bd:#2a3240;--tx:#e6edf3;--mut:#8b949e;
--red:#f85149;--orange:#e3873c;--yellow:#d9b043;--green:#3fb950;--blue:#58a6ff;
--redb:#3a1518;--orangeb:#3a2410;--yellowb:#332c12;--greenb:#122a17;}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:900px;margin:0 auto;padding:24px 20px 80px}.idxwrap{max-width:1100px;margin:0 auto;padding:0 20px 80px}
.bar{height:6px;border-radius:6px 6px 0 0}
.bgred{background:var(--red)}.bgorange{background:va
=== card count ===
14
=== RCEternalTorch ===
        end
    end
end

local acc = 0
local function onPlayerUpdate(playerObj)
    if not RCEternalTorch.cheat then return end
    if playerObj ~= getPlayer() then return end
    acc = acc + 1
    if acc < REFILL_TICKS then return end
    acc = 0
    if not RCShared.isAdmin(playerObj) then return end
    pcall(refillTorches, playerObj)
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- ---------------------------------------------------------------------------
-- Admin Powers panel registration + persistence
-- ---------------------------------------------------------------------------
local function setCheat(playerObj, selected)
    RCEternalTorch.cheat = selected == true
Bash Look for docs and review folder
IN
cd "c:/VSCodeProjects/PZMod" && ls -1 _Review tools 2>/dev/null | head -40; echo "--- JoiurnalTest"; ls -R JoiurnalTest 2>/dev/null | head -20; echo "--- md files at root of mods"; find . -maxdepth 3 -name "*.md" | grep -v PZ_Engine | head -40

OUT
_Review:
Scorecards

tools:
Remove-HighwayCells.ps1
__pycache__
check-lua.bat
cmdscan
delete-basement-chunks.ps1
fakeclient
luacheck.exe
netprobe
pzbasements.py
pzbasements_inject.py
--- JoiurnalTest
--- md files at root of mods
./Dirge/DORMANT_PERSISTENCE_PLAN.md
./Dirge/phunzones.md
./HusbandryTest/CLAUDE.md
./HusbandryTest/debug.md
./HusbandryTest/debug2.md
./HusbandryTest/FEATURES.md
./HusbandryTest/serverlogdumpselect.md
./ReclaimTest/_FORK_NOTES.md
./SaveValidator/FORMATS.md
./SaveValidator/README.md
./tools/cmdscan/README.md
./tools/fakeclient/RUNBOOK.md
./tools/netprobe/RUNBOOK.md
./zz_Archived/Sandman/DESIGN.md
./zz_Archived/xforge/SPEC-DRAFT.md
./zz_Archived/xforge/SPEC-EMISSIVE.md
./zz_Archived/xforge/SPEC-SCAN.md
./_rollback/README.md
Bash List per-mod top-level contents
IN
cd "c:/VSCodeProjects/PZMod" && for d in Reclamation Dragonfly Dirge Reaper Husbandry "Last Rites" OddsAndEnds Cookbook OmenSpyNetwork; do echo "--- $d"; ls -1 "$d" | head -20; done

OUT
--- Reclamation
Contents
preview.png
workshop.txt
--- Dragonfly
Contents
Poster.jpg
mods (2).zip
preview.png
snapshot.txt
workshop.txt
--- Dirge
Contents
DORMANT_PERSISTENCE_PLAN.md
phunzones.md
poster.png
preview.png
workshop.txt
--- Reaper
Contents
poster.png
preview.png
summary.csv
workshop.txt
--- Husbandry
contents
poster.png
preview.png
workshop.txt
--- Last Rites
Contents
art
content.png
content.png.bak
preview.png
preview.png.bak
workshop.txt
--- OddsAndEnds
Contents
preview.png
workshop.txt
--- Cookbook
Contents
poster.png
preview.png
workshop.txt
--- OmenSpyNetwork
Contents
preview.png
tools
workshop.txt
Bash Read LRPrefs and a workshop.txt
IN
cd "c:/VSCodeProjects/PZMod" && echo "== LRPrefs"; sed -n '1,80p' "Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua"; echo; echo "== workshop.txt Reclamation"; cat Reclamation/workshop.txt | head -20

OUT
== LRPrefs
-- LRPrefs.lua  (client)
--
-- Tiny persistence layer for *client-side cosmetic preferences* (the LRHub
-- toggles). Outcome-affecting config is sandbox options and never lives here.
--
-- B42 only exposes getFileWriter/getFileReader for Lua file I/O (io.open is
-- silently blocked), so we persist a flat key=value file. Values are limited to
-- booleans and numbers - all this UI needs - which keeps the (de)serializer
-- trivial and robust. The file lives in the per-user Zomboid dir, so prefs are
-- per-install (not per-save, not synced) - exactly right for cosmetic prefs.

LRPrefs = LRPrefs or {}

local FILE = "RFTDLastRites_clientprefs.txt"

-- In-memory cache. nil until first load(); always a table afterwards.
local cache = nil

-- ── (de)serialize ─────────────────────────────────────────
-- Format: one "key=value" per line. value is "true"/"false" or a number.
local function deserialize(line, store)
    local eq = string.find(line, "=", 1, true)
    if not eq then return end
    local key = string.sub(line, 1, eq - 1)
    local val = string.sub(line, eq + 1)
    if key == "" then return end
    if val == "true" then
        store[key] = true
    elseif val == "false" then
        store[key] = false
    else
        local n = tonumber(val)
        if n ~= nil then store[key] = n end
    end
end

local function serializeValue(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return tostring(v) end
    return nil  -- unsupported types are skipped, never written
end

-- ── load / save ───────────────────────────────────────────
function LRPrefs.load()
    cache = {}
    local r = getFileReader(FILE, false)  -- false = don't create if missing
    if not r then return cache end
    while true do
        local line = r:readLine()
        if line == nil then break end
        if line ~= "" then deserialize(line, cache) end
    end
    r:close()
    return cache
end

function LRPrefs.save()
    if not cache then return end
    local w = getFileWriter(FILE, true, false)  -- create, don't append
    if not w then return end
    for k, v in pairs(cache) do
        local s = serializeValue(v)
        if s then w:write(k .. "=" .. s .. "\r\n") end
    end
    w:close()
end

-- ── accessors ─────────────────────────────────────────────
-- get(key, default): returns the stored value, or `default` if unset.
function LRPrefs.get(key, default)
    if not cache then LRPrefs.load() end
    local v = cache[key]
    if v == nil then return default end
    return v
end

-- set(key, value): updates the cache and persists immediately. Cheap - the
-- file is a handful of lines and writes only happen on a settings change.
function LRPrefs.set(key, value)
    if not cache then LRPrefs.load() end

== workshop.txt Reclamation
version=1
id=3752878504
title=Requiem of the Dead: Reclaimation
description=[h1]Requiem of the Dead: Reclaimation[/h1]
description=
description=Reclaimation is a full vehicle lifecycle suite: claim the cars you earn, lock them down to keep them yours, and put the wrecks and rust-buckets nobody wants back to work as scrap. Built from the ground up for dedicated multiplayer servers.
description=
description=[b]Your vehicles stay yours. Everything else is fair game for the torch.[/b]
description=
description=[hr][/hr]
description=
description=[h2]Claiming Vehicles[/h2]
description=
description=Claim a vehicle to make it yours. A claimed vehicle is fully locked to anyone not on its access list:
description=
description=[list]
description=[*]Doors, interior, and seats
description=[*]Trunk and glovebox loot
description=[*]Mechanics (part install / uninstall)
description=[*]Siphoning fuel, smashing, and towing
Bash Find sibling mods reaching into DF globals
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "DFColumns\|DFConfirm\|DFLog\.\|DFFeedback\.\|DFPanel\|Capability\." --include=*.lua Reclamation Reaper Dirge Husbandry OddsAndEnds "Last Rites" | head -40

OUT
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua:94:    ISAdminPowerUI.AddOption("EternalTorch", "right", Capability.UseMechanicsCheat,
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:190:-- Tab build (DFPanel calls build(spec, panel, x, y, w, h) at panel-open)
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:276:            capability = Capability.ChangeWeather,
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:7:-- Columnar layout (DFColumns) - this is a dense inspector, not a visual
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:182:            DFFeedback.good(string.format("Culled %d of %d requested.",
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:188:            DFFeedback.good(string.format("Threshold %s = %s applied.",
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:212:    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:275:        DFColumns.drawHeader(self_, COLS, listX, headerY, FONT)
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:326:            if DFFeedback then DFFeedback.bad("No zombies selected.") end
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:353:            DFFeedback.good("Selected " .. n .. " siblings.")
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:363:            if DFFeedback then DFFeedback.bad("Pick a zombie first.") end
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:369:            DFFeedback.good(string.format("Teleported to %d,%d,%d.",
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:378:    -- DFConfirm.askIfOthersOnline since they affect everyone's world.
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:384:        if DFConfirm then
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:385:            DFConfirm.askIfOthersOnline(label, send)
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:433:                if DFFeedback then DFFeedback.good("Dirge reroll requested.") end
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:435:            if DFConfirm then
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:436:                DFConfirm.askIfOthersOnline(
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:514:        capability = Capability.ChangeWeather,
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQAdmin.lua:222:        if DFFeedback then DFFeedback.good(msg) end
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:34:            DFFeedback.good(string.format("Convert request sent: id=%d -> %s",
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:42:            DFLog.push{
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:58:            capability = Capability.CanZombify,
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:6:-- Columnar layout via DFColumns - same idiom as HBDebugPanel itself uses
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:125:    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:167:        DFColumns.drawHeader(self_, COLS, listX, headerY, FONT)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:232:        if DFFeedback then DFFeedback.bad("No animal selected.") end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:237:        if DFFeedback then DFFeedback.bad("Animal no longer resolvable.") end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:253:        DFFeedback.good(string.format("Teleported to %s.", row.name or row.species or "animal"))
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:279:        if DFFeedback then DFFeedback.bad("Log is empty.") end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:290:            DFFeedback.good(string.format("Copied %d log line(s) to clipboard.", #buf))
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:293:        if DFFeedback then DFFeedback.bad("Clipboard call failed.") end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:312:        DFLog.push{ source = "Mod:RFTDHusbandry", level = "info", text = line }
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:913:    if DFPanel and DFRegistry and DFRegistry.tabs and DFRegistry.tabs["animals"] then
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:914:        DFPanel.open()
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:915:        if DFPanel.instance then DFPanel.instance:showTab("animals") end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:10:-- Mirrors HBAnimalsTab's structure (DFColumns layout, "RQ" command module,
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:97:    DFColumns.drawRow(self, COLS, row, 4, y, FONT, { 0.92, 0.92, 0.92 }, 4, self.itemheight)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:119:        DFColumns.drawHeader(self_, COLS, listX, headerY, FONT)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:227:        if DFFeedback then DFFeedback.bad("No hutch selected.") end
Bash Check CI and recent commits
IN
cd "c:/VSCodeProjects/PZMod" && ls .github .github/workflows 2>/dev/null; echo "---"; git -C . log --oneline -12

OUT
.github:
modernize
---
20a6a3e Dirge: dormant registry debt cleanup + audit hardening
ad0f666 Dirge 1.0.3: Dormant Persistence Phase 1 - inert registry + zombieKilled isDead guard
83c177f Sweeping checkpoint: capture full working tree before next project
9afd46b Reclamation 0.5.2: the Presence Law - janitor abandonment is about the player, not the object
2ce0a58 Reclamation 0.5.1: janitor safehouse shield + 14-day default window
a73abf1 Reclamation 0.5.0: the Janitor - abandoned-vehicle reclamation feeding the token pools
cd7774f Reclamation: entire 0.4.x surface dedi-verified 2026-07-03; Janitor is next
d7a824b Reclamation: record Eternal Torch 0.4.5 in-game verification
eed938a Reclamation 0.4.5: Eternal Torch reworked to Unlimited-Ammo semantics
71cee7e Reclamation 0.4.4: engine-block message is an admin-customizable in-character thought
1badf28 Reclamation 0.4.3: Eternal Torch admin cheat on the vanilla Admin Powers panel
1943e55 Reclamation 0.4.2: split claim caps - MaxClaims (vehicles) vs MaxClaimTrailers
Bash Read RCSession and BXServer handler registration
IN
cd "c:/VSCodeProjects/PZMod" && echo "== RCSession"; sed -n '1,40p' "Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCSession.lua"; echo; echo "== BXServer 20-120"; sed -n '20,130p' "OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua"

OUT
== RCSession
-- RCSession - the lifecycle wiring (server only).
--
-- All of the registry's TIME behaviour lives here, kept bounded and
-- event/timer-driven (never WG's per-tick all-vehicles scan):
--   * heartbeat + activity stamping (so an online owner never expires)
--   * server-downtime credit on boot
--   * an hourly bounded pass that reconciles the index TOWARD loaded vehicles'
--     modData (self-heals the index, then applies inactivity expiry on
--     positive evidence). modData is the source of truth - this pass never
--     deletes a claim just because the index lacks it.

if not isServer() then return end

RCSession = RCSession or {}

-- Stamp every currently-online player's activity: claim rows (expiry clock)
-- AND the all-players presence map (the janitor's "player logged in" gate).
-- getOnlinePlayers() is a Java ArrayList (size/get, NOT the crash-prone
-- vehicle Set), bounded by the player count.
local function stampOnline()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getUsername then
            local name = p:getUsername()
            RCRegistry.stampSeen(name)
            RCRegistry.notePresence(name)
        end
    end
end

-- Iterate loaded vehicles safely. getCell():getVehicles() is a Set - iterating
-- it with get(i) crashes; :iterator() is the supported path. This runs at most
-- hourly, so it is NOT the banned per-tick scan.
local function forEachLoadedVehicle(fn)
    local cell = getCell and getCell()
    if not cell then return end
    local vs = cell:getVehicles()
    if not vs then return end

== BXServer 20-120
--   { obj = IsoObject, x,y,z, snap = {fulltype=count}, filled = bool }
-- Repopulated on LoadGridsquare, so it survives restarts (boxes persist in the chunk).
local boxes = {}

-- ---------------------------------------------------------------------------
-- Dedicated file audit log (separate from DFCore's in-game broadcast)
-- ---------------------------------------------------------------------------

local function stamp()
    return tostring(getTimestampMs and getTimestampMs() or 0)
end

local function flog(action, actor, key, detail)
    pcall(function()
        local w = getFileWriter(BX.LOGFILE, true, true) -- createIfNull, append (never truncate)
        if w then
            w:write("[" .. stamp() .. "] " .. action ..
                    " actor=" .. tostring(actor or "?") ..
                    " box=" .. tostring(key) ..
                    "  " .. tostring(detail or "") .. "\r\n")
            w:close()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end

-- Snapshot a container's contents as {fulltype = count}.
local function snapshot(cont)
    local snap, items = {}, cont:getItems()
    for i = 0, items:size() - 1 do
        local ft = items:get(i):getFullType()
        snap[ft] = (snap[ft] or 0) + 1
    end
    return snap
end

-- Best-effort actor for a manual in/out: nearest online player within 3 tiles on the same level.
local function nearestPlayer(x, y, z)
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return nil end
    local best, bestD = nil, 9.0
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and math.floor(p:getZ()) == z then
            local dx, dy = p:getX() - (x + 0.5), p:getY() - (y + 0.5)
            local d = dx * dx + dy * dy
            if d < bestD then best, bestD = p, d end
        end
    end
    return best and best:getUsername() or nil
end

-- Find the BoonBox IsoObject (and its modData) on a square, or nil.
local function findBox(sq)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local d = BX.getData(o)
        if d then return o, d end
    end
    return nil
end

local function squareFor(args)
    return getCell() and getCell():getGridSquare(args.x, args.y, args.z) or nil
end

local function register(obj, x, y, z)
    if not BX.getData(obj) then return end
    local key = BX.keyFor(x, y, z)
    local cont = obj:getContainer()
    local d = BX.getData(obj)
    boxes[key] = {
        obj = obj, x = x, y = y, z = z,
        filled = d.filled and true or false,
        snap = cont and snapshot(cont) or {},
    }
end

-- ---------------------------------------------------------------------------
-- Command handlers (registered on DFServer; capability + rate limit + reply
-- are all enforced by the dispatcher). Each returns { ok, message }.
--
-- Registration is deferred to OnServerStarted because DFServer may load after
-- this file alphabetically (BX < DF), so it's nil at top-of-file execution.
-- This mirrors Dragonfly's own sub-feature convention (cf. DFPlayersTab_Server)
-- and is the gate that makes the file drop straight into Dragonfly.
-- ---------------------------------------------------------------------------

Events.OnServerStarted.Add(function()
    if not BX.isEnabled() then
        print("[BoonBox] disabled via sandbox (RFTDOddsandEnds.BoonBoxEnable); handlers not registered")
        return
    end
    if not DFServer or not DFServer.registerHandler then
        print("[BoonBox] DFServer missing, handlers not registered")
        return
    end

DFServer.registerHandler{
    action = "BoonBoxSpawn",
    capability = Capability.AddItem, -- same gate Dragonfly uses for item-spawn handlers
Bash Check duplicate notify and send helpers
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '30,45p' "Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCRVGate.lua"; echo "== RQSvShared send helpers 270-290"; sed -n '265,290p' "Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQSvShared.lua"

OUT
-- pass through `canDo` automatically. Change this one constant to retier (e.g.
-- "passenger" if riding should grant interior access).
local ENTER_PERM = "inventory"

local function notify(player, key, isError)
    if player and sendServerCommand then
        sendServerCommand(player, M, "Notify", { key = key, error = isError and true or false })
    end
end

local function applyGate()
    if type(GetInToRV) ~= "function" then return end   -- RV mod absent => stay inert
    if RCRVGate.wrapped then return end
    RCRVGate.wrapped = true

    local orig = GetInToRV
== RQSvShared send helpers 270-290
        zombie:setVariable("bSprinter", true)
        zombie:setVariable("MovementSpeed", 1.2)
        zombie:resetModelNextFrame()
    end)
end
RQSvShared.applyBossSprinter = applyBossSprinter

-- ========================
-- Common utility functions
-- ========================

local function broadcast(cmd, args)
    sendServerCommand("RQ", cmd, args)
end

local function sendToPlayer(player, cmd, args)
    sendServerCommand(player, "RQ", cmd, args)
end

-- writes to RQSvShared.svPending so RQServer.lua can drain it in OnTick
local function scheduleAction(delayMs, fn)
    local q = RQSvShared.svPending
    q[#q + 1] = { due = getTimestampMs() + delayMs, fn = fn }
end

-- invisible or ghost admins shouldn't trigger zombie behaviors
Strong findings - including a live bug I didn't know about. Let me get a design pass on this.

Agent:Design RFTDCore + Reflections
IN
Design an implementation plan for a refactor in a Project Zomboid Build 42 Lua mod monorepo at c:\VSCodeProjects\PZMod. Read the files referenced below as needed. Output a detailed, staged plan - do not write any code files.

# The goal

The owner ships ~10 separate Workshop items under the "Requiem of the Dead" (RFTD) banner: Reclamation, Dragonfly, Dirge, Reaper, Husbandry, Last Rites, OddsAndEnds, Cookbook, OmenSpyNetwork, Sector7. He wants a new **master mod, "Requiem of the Dead" (RFTDCore)** that is:
1. A shared library - the family's common infrastructure, which today is copy-pasted 5-9 times over.
2. A **logging mastermind** - one telemetry/audit library all mods write through, with rotation, retention, and per-player + per-entity streams.
3. The eventual home of **"Requiem of the Dead: Reflections"** - an end-of-season per-player retrospective ("Here is your life"): where you spawned (with a https://map.projectzomboid.com/ deep link to the spawn house), stat progression, where you called home, the vehicle you made your own, challenges (deaths / memoirs written and read), zombies killed, and how you died.

A season is 3-4 months, ending at a server wipe.

# Established facts from exploration (do not re-derive; verify only if a design decision hinges on it)

## Packaging
- One Workshop item can ship MULTIPLE mod ids: `<Item>/Contents/mods/<ModId>/`. Already proven live - the Dragonfly item ships both `Dragonfly` and `BBLibrary`, with `BBLibrary/mod.info` declaring `require=Dragonfly`. Sector7 ships two map mods.
- `require=` in mod.info is the only dependency/load-order mechanism, and it appears exactly ONCE in the whole family (BBLibrary). Four real dependencies (Dragonfly, PhunZones2, RV Interior, Reaper) are undeclared.
- Every RFTD mod ships TWO identical mod.info files (root + `42/`).
- Mod ids are the key save data hangs off; PZ never self-cleans ModData from a removed mod id. Renaming/moving ids on a live server orphans state, so id changes must land at a wipe boundary.

## Duplication inventory (strongest consolidation candidates, ranked)
1. **Access/authorization**: 9 implementations across mods, 4 incompatible allowlists. `RCShared.isAdmin` (RCShared.lua:156) admits admin/moderator/overseer/gm/observer; Dirge `RQSvShared.svIsAdminPlayer` (:41) and Reaper `privileged` (RPServer.lua:22) admit 4; Husbandry `isAdminLike` (HBCommands.lua:22) admits ANY non-"None" level and is byte-copied into HBSexCheck_Server.lua:10; OddsAndEnds `BX.isAdmin` (BXShared.lua:58) admits only "Admin". Dragonfly uses a capability model instead (`DFCore.roleHas`, DFCore.lua:21).
2. **Rate limiter**: `DFCore.allow` (DFCore.lua:75) and `RCServer.underRate` (RCServer.lua:528) are the same fixed-window algorithm written twice, same RATE_MAX=20/1000ms, same fail-open policy. Reaper, Dirge, Husbandry dispatchers have NO limiter. The OnPlayerDisconnect prune with its "IsoPlayer or string" defensive branch is copy-pasted verbatim (RCServer.lua:549, DFServer.lua:126).
3. **LIVE BUG - command-module collision**: Dirge (`RQServer.lua:758`) and Husbandry (`HBCommands.lua:31`) BOTH dispatch on the bare module string `"RQ"`. Every Husbandry command is delivered to Dirge's dispatcher and vice versa; they survive only because command-name sets happen not to overlap. Husbandry also replies on `"RQ"`.
4. **File writers**: 6+ independent "append one stamped line via getFileWriter" implementations, each with its own timestamp helper and line format - RCAudit.lua:24, BXServer.lua:32, RQReflectLog.lua:36, OSNLog.lua:29, GuardianLogger.lua:123, MMAudit.lua:158. Plus a dead luajava/io.open path in RQDirgeLog.lua.
5. **Cached cfg() sandbox readers**: 4 cached-singleton implementations + ~30 inline `SandboxVars.<Id> or {}` reads. Dirge has the SAME function twice (RQConfig.get / RQSvShared.getSvConfig) with already-DRIFTED constant tables.
6. **Feedback**: RCShared.halo / DFFeedback.good|bad / three copies of a server->client `notify`/`reply`; RCServer.lua:16 is copy-pasted verbatim into RCRVGate.lua:34.
7. **DFRegistry tab-registration boilerplate**: 5 consumers repeat the same `Events.OnGameStart.Add(function() if not DFRegistry then return end ... end)` block with inconsistent pcall/Capability guarding, an unenforced `order` space (Reclamation and Husbandry both claim order=6), and an unvalidated cross-mod tabId reference (Dirge registers row actions onto "necro", a tab owned by Reaper).
8. **ISUserPanelUI:create post-hook**: RCUserPanelHook.lua and LRUserPanelHook.lua are the same ~50-line algorithm; each file's comment names the other.
9. dbg/trace loggers: 7 declarations of the same gated printf.
10. VERSION/MODULE constants: 5 mutually exclusive styles. `DFCore.VERSION = "0.6.2"` is already out of sync with Dragonfly mod.info `modversion=0.6.3`.

## The logging model to generalize - Dragonfly Memoirs
`Dragonfly/.../server/Memoirs/MMAudit.lua` is the most developed logger and the intended model:
- Layout: `Memoirs/<SafeName>/events.jsonl.log` (append), `Memoirs/<SafeName>/latest.json.txt` (TRUNCATED each write, derived/rebuildable), `Memoirs/_all.log` (append, one GLOBAL slim pipe timeline `<epochSec>|<gameDay>|<EVENT>|user=<name>|k=v...`). **The compound extensions are forced by the 42.20 write allowlist (see the erratum at the top of this file); the bare `.jsonl`/`.json` names shown elsewhere in this document are pre-42.20.** `_all.log` was the only one of the three that survived the change untouched, because it already ended `.log`.
- Envelope `{v=SCHEMA_V, t=epoch, day=worldAgeHours/24, event, user}` merged with caller data; key clashes documented as "a caller bug" but NOT enforced.
- Hand-rolled `jsonEncode` (MMAudit.lua:103) with lexicographically sorted keys for diffability; `jsonEscape` handles only 5 chars (no \b, \f, no \uXXXX for other control bytes).
- `fmtNum` (MMAudit.lua:53) = `string.format("%.2f", n)` with `.00` trimmed - **loses all precision beyond 2 decimals, including XP values**.
- `isArray` (MMAudit.lua:57) returns true for an EMPTY table - **empty maps encode as `[]`, not `{}`**, a shape hazard for consumers.
- `safeName` (MMAudit.lua:46) maps `[^%w%-_]` -> `_`; lossy and collision-prone (`Bob.Smith` and `Bob_Smith` collide). The READ side defends (MMRestore.lua:204) but the WRITE side does not - two colliding usernames interleave into one events.jsonl.
- `userWriter` (MMAudit.lua:154) has a nested->flat fallback remembered in an in-memory `layoutByUser` table.
- Nested dirs are engine-guaranteed: `LuaManager.getFileWriter` runs `File.mkdirs()` (re-verified on 42.20 at LuaManager.java:5511-5543, was :5444-5476); signature is still `getFileWriter(filename, createIfNull, append)` returning `LuaFileWriter`.
- ⚠ **Since 42.20 `getFileWriter` also returns nil for any extension outside `("ini","cfg","txt","log")`** (allowlist at LuaManager.java:9884, gate at :5514 - absent from 42.19.1). Case-sensitive and unlowercased, so `.TXT` fails too; extensionless names fail; only the final path segment is inspected, so dots in a `<SafeName>.<SteamID>` directory are harmless. `getFileReader`, `getModFileWriter` and `getModFileReader` are NOT gated. `getFileOutput` is ungated but cannot append (no append arg - truncates every open) and parks its stream in one `private static` field, so it is one file process-wide.
- Writes are open-append-close per line (no buffering) so a hard kill loses nothing already written.
- **NO rotation, NO size cap, NO retention, NO archiving anywhere.** `_all.log` is one global file for all players forever. PZ Lua exposes no file-delete primitive - and since 42.20 the truncate-as-delete substitute (`getFileWriter(path, true, false)`) is unavailable for any non-allowlisted extension, so pre-42.20 `.jsonl`/`.json` files can no longer even be emptied from Lua. They are permanent until removed out-of-band.
- `events.jsonl` is written but **never read** by anything. `MMRestore.decode` (MMRestore.lua:133) is a working hand-rolled JSON decoder explicitly exposed "for the future progression-sheet tooling".
- 14 EVENT names, all memoir-item-triggered or admin-triggered. No login, death, spawn, or periodic event.

## Data gaps for Reflections (all confirmed absent)
- **No spawn record**: no position, timestamp, or starting build is ever written at life start.
- **No life-start event**: `md.MMLifeId` (MMServer.lua:98-105, format `<epoch>-<rand>`) is minted lazily on the FIRST MEMOIR WRITE, not at spawn. A player who never writes a memoir has no life id.
- **No death capture anywhere in the monorepo.** Engine facts verified: `IsoPlayer.OnDeath()` returns early when `GameServer.server` and the `OnPlayerDeath` trigger is further guarded by `isLocalPlayer()`, so **OnPlayerDeath NEVER fires on a dedicated server**. `IsoGameCharacter.OnDeath()` triggers `OnCharacterDeath` via `super.OnDeath()` BEFORE that early return, so **OnCharacterDeath is the only death hook reachable server-side** - but it fires for every character including animals (IsoAnimal.java:1084), so it needs an `instanceof IsoPlayer`-equivalent guard.
- **No server-side login/spawn hook is reliable.** The proven in-family workaround is a standing `Events.OnTick` poll gated on `getSquare()` and `getInventory()`, keyed by `getOnlineID()`, with a throttle and a give-up timer - fully implemented at `Dragonfly/.../server/DFBanBox.lua:166-248`. Reclamation instead avoids connect hooks entirely and stamps presence from `EveryTenMinutes`/`EveryHours` sweeps (RCSession.lua:20-63) plus opportunistic stamps in command handlers.
- **Kill counters are corrupted for per-life reporting**: `MMSnapshotCodec.lua:432-440` ADDITIVELY carries `setZombieKills(snap.kills.Zombie + player:getZombieKills())` forward on every memoir recall, so `getZombieKills()` is not a per-life number on a Memoirs server.
- **hoursSurvived is never captured server-side** - only a client-side display label at MMStatsView.lua:61.
- No safehouse/home capture; no player->vehicle index (Reclamation keys claims BY VEHICLE in vehicle modData: RC_ClaimOwner/RC_ClaimAllowed/RC_ClaimPublic/RC_ClaimUsed/RC_ClaimId, RCClaim.lua:25-30, with a server-only derived index RCRegistry keyed by username).
- `MMSnapshotCodec.capture()` (MMSnapshotCodec.lua:78-143) captures: schemaVersion, epoch, perks (perkId->raw XP, only >0), traits (weight traits excluded), profession, recipes (set), kills {Zombie,Survivor}, nutrition, faith, lifeId. No position, vehicle, safehouse, hours, body damage, or inventory.
- `MMShared.WIPE_EPOCH = 1` (MMSvShared.lua:50) is a hand-edited global constant - the only season-ish marker; used only for read-time amnesty.
- MMSnapshotCodec has strong grant-vs-earned XP math (`buildGrantLevels` :263, `playerBuildIdentity` :295, `applyEarnables` :348) but it is computed at APPLY time and **never stored** - nothing about grant-vs-earned lands in any log.

## Existing HTML/report tooling precedent
`C:\Users\micha\Downloads\pzsurvey.py` (stdlib-only, 590 lines, NOT in the repo) is a complete decode -> build_dataset -> render pipeline that reads `players.db`, decodes IsoPlayer blobs, and emits a single self-contained HTML file (inline `<style>` with a `:root` palette, data injected as `<script type="application/json">`, vanilla-JS render functions, CSS-div charts, no external assets). It ALREADY extracts per player: hoursSurvived, zombieKills, survivorKills, traits, perk levels, x/y/z, profession, inventory, worn items, craft history, and per-mod ModData byte sizes. `c:\VSCodeProjects\PZMod\tools\` holds other stdlib Python forensics tools (cmdscan, pzbasements, SaveValidator) but no HTML generator and no player-data tooling.

# House rules and constraints (must be respected)
- **Vertical-slice rule**: build ONE verified vertical slice at a time (spine, then one feature end-to-end, verify on the dedicated server, then the next). Fanning out is what scraped an earlier project.
- Code conventions: modularity; shared tokens/helpers; WHY-comments not WHAT-comments; one file = one purpose; two-letter prefix = the command-module token; `<Px>Server.lua` dispatcher; `<Px>SvShared.lua` constants.
- `getFileWriter`/`getFileReader` are the ONLY working Lua file I/O in B42 (raw io.open and java.io are silently blocked server-side).
- B42 Kahlua gotchas: global `next()` is missing (use pairs + a counter); Java collection views (values()/keySet()/entrySet()) are not exposed and cannot be `:iterator()`'d; a single function with >200 locals silently fails to compile the WHOLE FILE in debug builds.
- `pcall` catches missing-method errors but PZ still logs them; engine Java NPEs are NOT caught by pcall and abort the tick.
- The dedicated server runs PUBLISHED Workshop builds while the owner's client symlinks the dev tree - so cross-mod version skew between separately-published items is a real hazard.
- The test server has `SaveWorldEveryMinutes=0`, so global ModData is RAM-only until a graceful shutdown; the owner's restart scripts force-kill java, meaning **no shutdown hook can be relied on**.
- A syntax gate exists: `tools\check-lua.bat` (luacheck, ~1s over all mod trees).
- Reclamation's audit writers were just fixed this session from append=false to append=true (RCAudit.lua:25, RCDamageAudit.lua:71). The ReclaimTest fork still carries the bug.

# What the plan must cover

1. **RFTDCore mod definition**: id, packaging (which Workshop item), what goes in it vs what stays, and how siblings declare the dependency. Address load-order: Core must load before consumers, and PZ's only lever is `require=`. Address the fact that Core is useless without adoption but adoption is a per-mod migration.
2. **The logging library**: on-disk layout, record schema/envelope, rotation and retention strategy given that PZ Lua CANNOT DELETE FILES, buffering vs open-append-close given no reliable shutdown hook, per-player vs per-entity streams, the safeName collision problem, the fmtNum precision problem, the empty-map-encodes-as-array problem, and a strict separation between a high-volume rotating forensic stream and a slim permanent season stream (a season retrospective CANNOT be derived from a stream that has been rotated away).
3. **Life-cycle instrumentation**: a reliable server-side spawn/life-start capture (position for the map deep link, starting build, timestamp), a life-id minted AT SPAWN rather than lazily, and a death capture via the server-reachable OnCharacterDeath with a player guard. Say exactly which hooks and which existing implementation to copy.
4. **Season/epoch model**: how a season is bounded, identified in the data, and rolled at a wipe.
5. **Reflections**: where the parsing/rendering lives (in-game Lua vs an offline Python tool reusing the pzsurvey.py pipeline), the schema contract between the log producers and the renderer, and how per-mod chapters (Reclamation's vehicle chapter, Memoirs' deaths/memoirs chapter) are contributed without Core depending on those mods.
6. **Migration sequencing** honoring the vertical-slice rule and the wipe boundary, with the highest-value/lowest-risk first slice identified explicitly.
7. **Risks** and what could go wrong, especially: the "RQ" module collision fix (a breaking wire-protocol change), mod-id changes orphaning save data, and version skew.

Be concrete and opinionated: name files, functions to reuse (with paths), and the order of work. Flag anywhere you think the owner's stated intent should be pushed back on.
Bash Git log and tools listing
IN
cd "c:/VSCodeProjects/PZMod" && git log --oneline -15 2>/dev/null; echo "---"; ls tools/

OUT
20a6a3e Dirge: dormant registry debt cleanup + audit hardening
ad0f666 Dirge 1.0.3: Dormant Persistence Phase 1 - inert registry + zombieKilled isDead guard
83c177f Sweeping checkpoint: capture full working tree before next project
9afd46b Reclamation 0.5.2: the Presence Law - janitor abandonment is about the player, not the object
2ce0a58 Reclamation 0.5.1: janitor safehouse shield + 14-day default window
a73abf1 Reclamation 0.5.0: the Janitor - abandoned-vehicle reclamation feeding the token pools
cd7774f Reclamation: entire 0.4.x surface dedi-verified 2026-07-03; Janitor is next
d7a824b Reclamation: record Eternal Torch 0.4.5 in-game verification
eed938a Reclamation 0.4.5: Eternal Torch reworked to Unlimited-Ammo semantics
71cee7e Reclamation 0.4.4: engine-block message is an admin-customizable in-character thought
1badf28 Reclamation 0.4.3: Eternal Torch admin cheat on the vanilla Admin Powers panel
1943e55 Reclamation 0.4.2: split claim caps - MaxClaims (vehicles) vs MaxClaimTrailers
c0bbfb6 Reclamation 0.4.1: fix vehicle removal desync; panel action is now plain Delete
6104b7b Reclamation: record 0.4.0 dedi gate-verification results in docs
97c3267 Reclamation: RC_dismantle radial icon from owner's torch art
---
Remove-HighwayCells.ps1
__pycache__
check-lua.bat
cmdscan
delete-basement-chunks.ps1
fakeclient
luacheck.exe
netprobe
pzbasements.py
pzbasements_inject.py
Bash List mod ids per workshop item
IN
cd "c:/VSCodeProjects/PZMod" && for d in Reclamation Dirge Reaper Husbandry "Last Rites" OddsAndEnds Cookbook OmenSpyNetwork Sector7; do echo "### $d"; ls "$d/Contents/mods/" 2>/dev/null; done

OUT
### Reclamation
RFTDReclamation
### Dirge
RFTDDirge
### Reaper
RFTDReaper
### Husbandry
RFTDHusbandry
### Last Rites
RFTDLastRites
### OddsAndEnds
RFTDOddsandEnds
### Cookbook
RFTDCookbook
### OmenSpyNetwork
OmenSpyNetwork
### Sector7
Sector-7 Breach
Sector-7 Breach Highway
Bash Find Memoirs lua files
IN
cd "c:/VSCodeProjects/PZMod" && find . -maxdepth 6 -name "*.lua" -path "*Memoirs*" | head -30

OUT
(Bash completed with no output)
Bash List Dragonfly lua tree
IN
cd "c:/VSCodeProjects/PZMod/Dragonfly/Contents/mods/Dragonfly/42/media/lua" && ls -R | head -100

OUT
.:
client
server
shared

./client:
DFBanBox_Notice.lua
DFColumns.lua
DFConfirm.lua
DFConsoleTab.lua
DFCoordOverlay.lua
DFDebugGate.lua
DFEngineLock.lua
DFErrorPoller.lua
DFFeedback.lua
DFItemEditor.lua
DFLog.lua
DFMedicalCheck.lua
DFPanel.lua
DFPatch_CleanUI.lua
DFPatch_Greenport.lua
DFPlayerInventoryModal.lua
DFPlayersTab.lua
DFRegistry.lua
DFRoleEditorUnlock.lua
DFRolesTab.lua
DFSafehouseDestroyPatch.lua
DFScoreboard.lua
Longstrider
MMClient.lua
MMContext.lua
MMStatsView.lua

./client/Longstrider:
LSGridOverlay.lua
LSMap.lua
LSTab.lua
LSTour.lua
LSTours.lua

./server:
DFBanBox.lua
DFEngineLock_Server.lua
DFInventory_Server.lua
DFPatch_AntiCheatLogNoise.lua
DFPatch_Greenport_Server.lua
DFPatch_JM3Archery.lua
DFPatch_PhunLewt.lua
DFPatch_RVInterior.lua
DFPatch_SOTO.lua
DFPatch_Spongies.lua
DFPlayerRoles_Server.lua
DFPlayersTab_Server.lua
DFRoleEdit_Server.lua
DFServer.lua
DFZombiesTab_Server.lua
MMServer.lua
Memoirs

./server/Memoirs:
MMAudit.lua
MMRestore.lua

./shared:
DFActionSpeed.lua
DFCore.lua
DFItemProbes.lua
DFPatch_BetterHutches.lua
DFPatch_Frogtown.lua
DFPatch_SpecialLootSpawns.lua
DFPatch_Turn180Noise.lua
MMSnapshotCodec.lua
MMSvShared.lua
Translate

./shared/Translate:
EN

./shared/Translate/EN:
ItemName.json
Print_Media.json
Print_Text.json
Recipes.json
Sandbox.json
Read c:\VSCodeProjects\PZMod\Dragonfly\Contents\mods\Dragonfly\42\media\lua\shared\DFCore.lua
Bash Total lua line count
IN
cd "c:/VSCodeProjects/PZMod" && wc -l $(find Reclamation Dirge Reaper Husbandry "Last Rites" OddsAndEnds Cookbook OmenSpyNetwork Dragonfly -name "*.lua") | tail -3

OUT
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDanger.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerHUD.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerMoodle.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerPanel.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRDangerQuips.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRHub.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua: No such file or directory
wc: Last: No such file or directory
wc: Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRUserPanelHook.lua: No such file or directory
    493 Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSnapshotCodec.lua
    229 Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua
  33743 total
Read c:\VSCodeProjects\PZMod\Reclamation\Contents\mods\RFTDReclamation\42\media\lua\server\RCAudit.lua
Bash Read DFBanBox login poll
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '150,260p' Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFBanBox.lua

OUT
        -- Tell the player (server formats so BBLibrary's override is honoured).
        local msg = string.format(DFBanBox.removalMessage or "%s has been removed.", r.name)
        pcall(function() sendServerCommand(player, "DFBanBox", "removed", { message = msg }) end)
        -- Audit for staff - input to the two-owner process, never an auto-action.
        if DFCore and DFCore.audit then
            DFCore.audit("BanBox confiscate", player, string.format("item=%s x%d", ft, r.count))
        else
            print(string.format("[Dragonfly] BanBox confiscate from %s: %s x%d",
                tostring(player:getUsername()), ft, r.count))
        end
    end
    if any then pcall(function() player:resetModelNextFrame() end) end  -- refresh if a worn item went
    dbg("scrub %s: scanned=%d, removed=%s",
        tostring(who), scanned, any and "yes" or "none banned")
end

-- Trigger reality on a DEDICATED server: OnPlayerUpdate doesn't fire (no local
-- player), and OnConnected/OnCreatePlayer BIND but don't fire on a remote join
-- here (the bounded "arm on connect" watcher printed "armed" then went silent
-- forever - nothing ever armed it). The only event proven to fire server-side is
-- OnTick (see DFPatch_RVInterior). So this is a STANDING OnTick poll - but kept
-- cheap: it does real work at most once a second, skips already-handled players
-- instantly, and gives up on any one player after WATCH_MAX_MS so a stuck loader
-- never causes repeated scans. Time-based (getTimestampMs); keyed by onlineID so
-- a relog (fresh id) is re-scrubbed.
local WATCH_MAX_MS     = 5 * 60 * 1000  -- give up waiting for one player to load in
local POLL_INTERVAL_MS = 1000           -- do real work at most this often
local scrubbedID = {}                   -- onlineID -> true (handled this connection)
local watchStart = {}                   -- onlineID -> ms first seen, still loading in
local lastDiag   = {}                   -- onlineID -> ms of last "waiting" diagnostic
local lastPoll   = 0

local function nowMs()
    local ok, v = pcall(getTimestampMs); if ok and type(v) == "number" then return v end
    ok, v = pcall(getTimeInMillis); if ok and type(v) == "number" then return v end
    return nil
end

local function pollScrub()
    local now = nowMs()
    if not now or (now - lastPoll) < POLL_INTERVAL_MS then return end  -- throttle to ~1s
    lastPoll = now
    if not confiscateOn() then return end
    if not DFBanBox._pollProven then
        DFBanBox._pollProven = true
        dbg("OnTick poll active (confiscate ON; scanning logins)")
    end
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local id = p and p.getOnlineID and p:getOnlineID()
        if id and not scrubbedID[id] then
            local sq  = p.getSquare and p:getSquare()
            local inv = p.getInventory and p:getInventory()
            if sq and inv then
                scrubbedID[id] = true; watchStart[id] = nil; lastDiag[id] = nil
                scrubPlayer(p)
            else
                local start = watchStart[id]
                if not start then watchStart[id] = now; start = now end
                -- Throttled visibility while waiting (every ~5s): shows what the
                -- server actually sees, so we can tell "not loaded yet" from a
                -- getSquare/getInventory that never populates.
                if not lastDiag[id] or (now - lastDiag[id]) > 5000 then
                    lastDiag[id] = now
                    dbg("waiting on %s: square=%s inv=%s (%ds elapsed)",
                        tostring((p.getUsername and p:getUsername()) or id),
                        tostring(sq ~= nil), tostring(inv ~= nil), math.floor((now - start) / 1000))
                end
                if now - start >= WATCH_MAX_MS then
                    scrubbedID[id] = true; watchStart[id] = nil; lastDiag[id] = nil
                    dbg("gave up waiting for %s after %d min - not scrubbed this connection",
                        tostring((p.getUsername and p:getUsername()) or id), math.floor(WATCH_MAX_MS / 60000))
                end
            end
        end
    end
end

if not DFBanBox._connectHooked then
    DFBanBox._connectHooked = true
    if Events.OnTick then
        Events.OnTick.Add(pollScrub)
        dbg("login scrub armed (standing OnTick poll, %dms interval, %d-min per-player cap)",
            POLL_INTERVAL_MS, math.floor(WATCH_MAX_MS / 60000))
    else
        print("[DFBanBox] login scrub: OnTick unavailable - scrub disabled")
    end
    -- Prune per-connection flags on disconnect (best-effort; a relog gets a fresh id).
    local function bindDC(name)
        local ev = Events[name]
        if ev and ev.Add then ev.Add(function(p)
            local i = p and p.getOnlineID and p:getOnlineID()
            if i then scrubbedID[i] = nil; watchStart[i] = nil; lastDiag[i] = nil end
        end) end
    end
    bindDC("OnDisconnect"); bindDC("OnPlayerDisconnect")
end
Bash Read MMSvShared
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '1,120p' Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSvShared.lua

OUT
-- MMSvShared.lua - Memoir (snapshot/restore) shared constants, lookups, and
-- debug layer. RFTD convention: two-letter prefix (MM), <Px>SvShared = shared tokens.
--
-- This subsystem turns a craftable journal into a CONVENIENCE SAVE (not a
-- reincarnation): write captures a full character snapshot; read restores it onto
-- whatever body you respawned as. Locked design rules (2026-07-13 overwrite model):
--   * MEMOIR IS THE SOURCE OF TRUTH: reading it OVERWRITES whatever was built at the
--     respawn screen - identity (profession/traits), body, faith: snapshot wins. No
--     reconcile window, no choice: the creation screen picks a loaner body, the
--     memoir returns the real character.
--   * XP: memoir restore (grants + earned*knob) PLUS whatever was EARNED playing the
--     new body - post-respawn grinding is real play, it adds on top. The respawn
--     build's starting grants - XP levels, traits/profession, AND granted recipes -
--     are DISMISSED with the build (no chef->die->engineer->read laundering of
--     profession-locked abilities). Additive is safe ONLY because the two earning
--     windows are disjoint lives - the life-id guarantees it.
--   * SAME-LIFE READS REFUSE (and do not consume): a memoir read by the life that
--     wrote it would double-count its own history. The life-id stamped at write
--     detects this; death wipes player modData, so a respawn never matches.
--   * Single-use: on read the server CONSUMES the memoir and hands back a plain notebook,
--     so a memoir can't be read twice. Reuse = craft a fresh memoir (pen/pencil gated).
--   * Identity gate (steamID/username) preserved.
--   * Grant math mirrors engine creation (IsoGameCharacter.applyTraits: passive base 5
--     + boosts, clamped 0..10); the XP knob taxes MEMOIR-earned XP only. No restore
--     lands below a fresh spawn of the saved build; remake cycles net zero (no
--     min/max laundering). See MMSnapshotCodec header for the full rule.
--   * Legacy (pre-v4, no life-id) books bridge via the old identity compare:
--     match -> the old harmless top-up (could be the same life); mismatch -> overwrite.

MMShared = MMShared or {}

MMShared.MODULE = "RFTDDragonflyMemoir"

-- client <-> server command names
MMShared.CMD = {
    WRITE_REQUEST = "mm_write",   -- client asks server to snapshot into the journal
    READ_REQUEST  = "mm_read",    -- client asks server to restore from the journal
    RESULT        = "mm_result",  -- server -> client feedback (ok/deny + say text)
    DUMP          = "mm_dump",    -- debug: dump authoritative journal/player state
}

MMShared.SCHEMA_VERSION = 4 -- v4 adds snap.lifeId (same-life read guard); v3 faith; v2 nutrition

-- WIPE EPOCH: read-time amnesty gate. Every write stamps the current epoch into the
-- snapshot; reading a book stamped with an OLDER epoch (or none) refuses - "the ink
-- has faded" - and KEEPS the book, so the owner just writes over it for a fresh
-- snapshot. Bump the number to void every memoir written before the bump, wherever
-- it is stored (unloaded chunks, offline inventories - no scrub can reach those).
-- Epoch 1 retires all books written before the 2026-07-20 double-read dupe fix.
MMShared.WIPE_EPOCH = 1

-- =====================================================================
--  CONFIG. Server-tunable knobs (SandboxVars, MP-synced to clients so the shared
--  codec computes the same result on the server authority and the owning client's
--  mirror-apply).
-- =====================================================================

-- XP restore mode (sandbox MemoirXPRestoreMode): 1 = Global (one % for every skill,
-- default / legacy behaviour), 2 = Per Individual (each vanilla skill has its own %).
-- Per-category was deliberately dropped - only these two tiers are wanted.
function MMShared.xpRestoreMode()
    local sv = SandboxVars and SandboxVars.RFTDDragonfly
    local m = sv and sv.MemoirXPRestoreMode
    return (type(m) == "number") and m or 1
end

-- 0..100 integer -> 0..1 fraction, clamped. Returns nil for a missing/non-number knob so
-- callers can tell "knob absent" apart from "knob set to 0" and fall back accordingly.
local function pctToFraction(pct)
    if type(pct) ~= "number" then return nil end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct / 100.0
end

-- XP restore fraction for ONE skill on restore (0..1). Scales that skill's recorded RAW XP
-- (90 = give back 90% of its saved XP). Identity (traits/profession), recipes, kills and
-- Faith are NOT scaled - they always restore in full - so the journal stays a true snapshot
-- and only XP potential dials down.
--   Global mode     : every skill uses MemoirXPRestore.
--   Individual mode : skill uses MemoirXPRestore_<perkId> if declared, else falls back to the
--                     global MemoirXPRestore. So any skill without its own knob (a modded
--                     skill, or a vanilla one we didn't list) degrades to the global value -
--                     never silently to 100%.
-- perkId optional: omit it (or in Global mode) and you get the single global fraction.
function MMShared.xpRestoreFraction(perkId)
    local sv = SandboxVars and SandboxVars.RFTDDragonfly
    local globalFrac = pctToFraction(sv and sv.MemoirXPRestore) or 1.0
    if not perkId or MMShared.xpRestoreMode() ~= 2 then return globalFrac end
    return pctToFraction(sv and sv["MemoirXPRestore_" .. perkId]) or globalFrac
end

-- =====================================================================
--  DEBUG LAYER. Read/write/dump traces (tagged [MM_DBG]) are gated by the
--  MemoirDebug sandbox option (default OFF) - silent unless an admin turns it on.
--  MM_DEBUG_FORCE is a local dev override (set true to force prints on).
-- =====================================================================
MM_DEBUG_FORCE = false

local function debugOn()
    if MM_DEBUG_FORCE then return true end
    local sv = SandboxVars and SandboxVars.RFTDDragonfly
    return (sv and sv.MemoirDebug == true) or false
end
MMShared.debugOn = debugOn

local function sideTag()
    if isServer() then return "SERVER" end
    if isClient() then return "CLIENT" end
    return "SP"
end

function MMname(player)
    if not player then return "?" end
    local ok, n = pcall(function() return player:getUsername() end)
    if ok and n and n ~= "" then return n end
    ok, n = pcall(function() return player:getFullName() end)
    return (ok and n) or tostring(player)
end

function MMlog(...)
Bash Read RQ module collision sites
IN
cd "c:/VSCodeProjects/PZMod" && echo "=== Dirge RQServer 745-790 ===" && sed -n '745,790p' Dirge/Contents/mods/RFTDDirge/42/media/lua/server/RQServer.lua && echo "=== Husbandry HBCommands 1-60 ===" && sed -n '1,60p' Husbandry/Contents/mods/RFTDHusbandry/42/media/lua/server/HBCommands.lua

OUT
Exit code 2
=== Dirge RQServer 745-790 ===
        pcall(inv.AddItem, inv, itemType)
    end
end

-- ========================
-- Client command handling
-- ========================

-- reflectPing per-player rate limit (username-keyed: exact SteamIDs are lossy
-- in server-side Lua). Any client may ping; the answer is read-only state.
local svReflectPingAt = {}

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RQ" then return end

    if command == "reflectPing" then
        -- Reflection probe (client half: RQReflect.lua). A client is asking
        -- "which specials does the server believe are near me RIGHT NOW?".
        -- Answer with authoritative rows AND log the same rows server-side,
        -- so the truth survives even if the response packet never lands.
        local pingNow = getTimestampMs()
        local uname   = "?"
        pcall(function() uname = player:getUsername() end)
        if svReflectPingAt[uname] and pingNow - svReflectPingAt[uname] < 3000 then return end
        svReflectPingAt[uname] = pingNow

        local px, py, pz = 0, 0, 0
        pcall(function() px, py, pz = player:getX(), player:getY(), player:getZ() end)
        -- client-reported position rides along; disagreement with the server's
        -- own view of the player is itself a sync-health datapoint
        local cx = tonumber(args and args.x) or px
        local cy = tonumber(args and args.y) or py
        local pdx, pdy = px - cx, py - cy
        local posDrift = math.sqrt(pdx * pdx + pdy * pdy)

        local md    = ModData.getOrCreate("RQZombieState")
        local rows  = {}
        local nRows = 0
        local total = 0
        for zombie, zType in pairs(svActiveZombies) do
            total = total + 1
            local ok, dead = pcall(zombie.isDead, zombie)
            if ok and not dead then
                local ok2, oid = pcall(zombie.getOnlineID, zombie)
                local ok3, zx  = pcall(zombie.getX, zombie)
                local ok4, zy  = pcall(zombie.getY, zombie)
=== Husbandry HBCommands 1-60 ===
sed: can't read Husbandry/Contents/mods/RFTDHusbandry/42/media/lua/server/HBCommands.lua: No such file or directory
Bash Locate Husbandry files
IN
cd "c:/VSCodeProjects/PZMod" && find Husbandry -name "HBCommands.lua" -o -name "HBSexCheck_Server.lua" | head && echo "---" && find Husbandry Dirge -name "*.lua" | sed 's|.*/||' | sort | head -60

OUT
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBSexCheck_Server.lua
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua
---
HBAPIProbe.lua
HBAddHayAction.lua
HBAnimalsTab.lua
HBBedding.lua
HBCommands.lua
HBContextMenu.lua
HBData.lua
HBDebugPanel.lua
HBErrorMagnifier.lua
HBHutchContextMenu.lua
HBHutchUI.lua
HBHutchesTab.lua
HBKeepAlive.lua
HBLifespan.lua
HBSexCheck.lua
HBSexCheck_Server.lua
RQAdmin.lua
RQBoss.lua
RQCastBar.lua
RQConfig.lua
RQCore.lua
RQDirgeLog.lua
RQEMP.lua
RQEatLog.lua
RQGlutton.lua
RQHealthBar.lua
RQHighlight.lua
RQJuggernaut.lua
RQLoot.lua
RQMoodle.lua
RQNecroActions.lua
RQPhunZones.lua
RQReconcile.lua
RQReflect.lua
RQReflectLog.lua
RQRegistry.lua
RQRing.lua
RQScavenger.lua
RQScreamer.lua
RQServer.lua
RQSvBoss.lua
RQSvDormant.lua
RQSvEMP.lua
RQSvEating.lua
RQSvGlutton.lua
RQSvJuggernaut.lua
RQSvScavenger.lua
RQSvScreamer.lua
RQSvShared.lua
Bash Read DFRegistry
IN
cd "c:/VSCodeProjects/PZMod" && cat Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/DFRegistry.lua

OUT
-- DFRegistry - tab/action/badge registration for consumer mods.
--
-- Reaper, Husbandry, Dirge, and Ladybug all call into this if Dragonfly is
-- loaded. Each registration is just a table description; DFPanel reads it
-- at panel-open time to build the UI. No registration means no surface,
-- which is how consumer mods stay shippable without Dragonfly.
--
-- Registration order doesn't matter; tabs are sorted by an optional `order`
-- field then alphabetically by label.

if isServer() then return end

DFRegistry = DFRegistry or {
    tabs         = {},  -- [id] = spec
    rowActions   = {},  -- [tabId] = { spec, spec, ... }
    statusBadges = {},  -- [id] = spec
}

function DFRegistry.registerTab(spec)
    if not spec or not spec.id then
        print("[Dragonfly] registerTab refused: missing spec or id")
        return
    end
    DFRegistry.tabs[spec.id] = spec
    print("[Dragonfly] registerTab ok: " .. tostring(spec.id) .. " (" .. tostring(spec.label or "?") .. ")")
end

function DFRegistry.registerRowAction(spec)
    if not spec or not spec.tabId then return end
    local list = DFRegistry.rowActions[spec.tabId]
    if not list then list = {}; DFRegistry.rowActions[spec.tabId] = list end
    list[#list + 1] = spec
end

function DFRegistry.registerStatusBadge(spec)
    if not spec or not spec.id then return end
    DFRegistry.statusBadges[spec.id] = spec
end

function DFRegistry.getTabs()
    local out = {}
    for _, spec in pairs(DFRegistry.tabs) do
        -- supersededBy hides this tab if the named successor is also registered.
        -- Used by Dragonfly's basic Zombies tab to step aside for Reaper's Necro.
        local hide = spec.supersededBy and DFRegistry.tabs[spec.supersededBy] ~= nil
        if not hide then out[#out + 1] = spec end
    end
    table.sort(out, function(a, b)
        local oa = a.order or 100
        local ob = b.order or 100
        if oa ~= ob then return oa < ob end
        return tostring(a.label or "") < tostring(b.label or "")
    end)
    return out
end

function DFRegistry.getRowActions(tabId)
    return DFRegistry.rowActions[tabId] or {}
end

function DFRegistry.getStatusBadges()
    local out = {}
    for _, spec in pairs(DFRegistry.statusBadges) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- Friendly alias for consumer mods. They write `Dragonfly.registerTab{...}`
-- rather than `DFRegistry.registerTab{...}`; reads cleaner from outside.
Dragonfly = Dragonfly or {}
Dragonfly.registerTab         = DFRegistry.registerTab
Dragonfly.registerRowAction   = DFRegistry.registerRowAction
Dragonfly.registerStatusBadge = DFRegistry.registerStatusBadge
Bash Inspect workshop item layout and docs
IN
cd "c:/VSCodeProjects/PZMod" && ls Reclamation/ Reclamation/Contents/ && echo "=== workshop.txt ===" && cat Reclamation/workshop.txt && echo "=== docs? ===" && find . -maxdepth 3 -iname "*.md" -not -path "./PZ_Engine_Decompiled/*" | head -40

OUT
Reclamation/:
Contents
preview.png
workshop.txt

Reclamation/Contents/:
mods
=== workshop.txt ===
version=1
id=3752878504
title=Requiem of the Dead: Reclaimation
description=[h1]Requiem of the Dead: Reclaimation[/h1]
description=
description=Reclaimation is a full vehicle lifecycle suite: claim the cars you earn, lock them down to keep them yours, and put the wrecks and rust-buckets nobody wants back to work as scrap. Built from the ground up for dedicated multiplayer servers.
description=
description=[b]Your vehicles stay yours. Everything else is fair game for the torch.[/b]
description=
description=[hr][/hr]
description=
description=[h2]Claiming Vehicles[/h2]
description=
description=Claim a vehicle to make it yours. A claimed vehicle is fully locked to anyone not on its access list:
description=
description=[list]
description=[*]Doors, interior, and seats
description=[*]Trunk and glovebox loot
description=[*]Mechanics (part install / uninstall)
description=[*]Siphoning fuel, smashing, and towing
description=[*]Both the radial and right-click menus
description=[/list]
description=
description=Each player claims a server-tunable number of vehicles, with a separate allowance for trailers so a camper never costs you a car slot. Claims live in a server-side registry and [b]auto-release[/b] after a tunable real-time inactivity window (credited for server downtime), so abandoned claims free themselves instead of locking cars forever.
description=
description=[hr][/hr]
description=
description=[h2]Permissions & Access[/h2]
description=
description=Ownership is not all-or-nothing. Grant other players granular, per-permission access to any vehicle you own:
description=
description=[list]
description=[*][b]Driver[/b] - take the wheel
description=[*][b]Passenger[/b] - ride along and use the seats
description=[*][b]Mechanic[/b] - work on the parts
description=[*][b]Inventory[/b] - reach the loot
description=[/list]
description=
description=Manage access in-game from the vehicle radial, or from the [b]My Vehicles[/b] fleet panel - a live list of every vehicle you own, with a 3D preview, distance-to-vehicle, and release-from-anywhere.
description=
description=[hr][/hr]
description=
description=[h2]Dismantling[/h2]
description=
description=Worn-out cars and wrecks don't have to sit and rot. With a welding mask and a blowtorch, dismantle a vehicle down to its scrap:
description=
description=[list]
description=[*]Everything inside [b]drops to the ground[/b] first - no loot is ever destroyed
description=[*]Claimed vehicles must be [b]released[/b] before they can be dismantled
description=[*]Good engines block the job (a tunable threshold), so a perfectly good car can't be scrapped out from under someone
description=[/list]
description=
description=[hr][/hr]
description=
description=[h2]Engine Salvage Lock[/h2]
description=
description=An optional lock stops non-staff players from stripping good engines for motor parts - closing the "leave the shell, take the heart" loophole.
description=
description=[hr][/hr]
description=
description=[h2]Admin Tools[/h2]
description=
description=[list]
description=[*][b]Audit ledger[/b] - every claim, dismantle, engine pull, and admin delete is written to a server-side log
description=[*][b]Eternal Torch[/b] - a checkbox on the vanilla Admin Powers panel that keeps your blowtorches topped up so cleanup never runs dry
description=[*][b]Vehicles tab[/b] - with Dragonfly installed, admins get a live list of streamed vehicles with teleport-to and delete
description=[/list]
description=
description=[hr][/hr]
description=
description=[h2]Customization[/h2]
description=
description=Nearly everything is a sandbox option: claim caps, trailer caps, the inactivity window, dismantle time, the engine-quality threshold, which subsystems are enabled, and more.
description=
description=[hr][/hr]
description=
description=[h2]Compatibility[/h2]
description=
description=[list]
description=[*][b]PhunZones[/b] - mark per-zone "no dismantle" areas
description=[*][b]RV Interior[/b] - claimed RV interiors are gated behind vehicle access
description=[*][b]Dragonfly[/b] - adds the admin Vehicles tab
description=[/list]
description=
description=All soft dependencies - Reclaimation runs fine without any of them.
description=
description=[hr][/hr]
description=
description=[h2]Server[/h2]
description=
description=Reclaimation was made for and is currently live on the [b]Requiem of the Dead[/b] RP server.
description=
description=[url=https://discord.gg/UMSj4vQs2P]Join the Discord →[/url]
description=
description=[hr][/hr]
description=
description=[h2]Technical[/h2]
description=
description=[list]
description=[*][b]Workshop ID:[/b] 3752878504
description=[*][b]Mod ID:[/b] RFTDReclamation
description=[/list]
tags=Build 42
visibility=unlisted
=== docs? ===
./Dirge/DORMANT_PERSISTENCE_PLAN.md
./Dirge/phunzones.md
./HusbandryTest/CLAUDE.md
./HusbandryTest/debug.md
./HusbandryTest/debug2.md
./HusbandryTest/FEATURES.md
./HusbandryTest/serverlogdumpselect.md
./ReclaimTest/_FORK_NOTES.md
./SaveValidator/FORMATS.md
./SaveValidator/README.md
./tools/cmdscan/README.md
./tools/fakeclient/RUNBOOK.md
./tools/netprobe/RUNBOOK.md
./zz_Archived/Sandman/DESIGN.md
./zz_Archived/xforge/SPEC-DRAFT.md
./zz_Archived/xforge/SPEC-EMISSIVE.md
./zz_Archived/xforge/SPEC-SCAN.md
./_rollback/README.md
Bash Look for repo conventions files
IN
cd "c:/VSCodeProjects/PZMod" && ls -a | head -30 && echo "=== Reclamation CLAUDE? ===" && find . -maxdepth 2 -iname "CLAUDE.md" && echo "=== check-lua ===" && cat tools/check-lua.bat

OUT
.
..
.git
.github
.gitignore
.vscode
Cookbook
Dirge
Dragonfly
DragonflyTest
Husbandry
HusbandryTest
Last Rites
OddsAndEnds
OmenSpyNetwork
PZ_Engine_Decompiled
Reaper
ReclaimTest
Reclamation
Reclamation.zip
SaveValidator
Sector7
_Review
_rollback
debuglog-server.txt
debuglogs
tools
z_texturesandicons
zz_Archived
=== Reclamation CLAUDE? ===
./HusbandryTest/CLAUDE.md
./PZ_Engine_Decompiled/CLAUDE.md
=== check-lua ===
@echo off
rem check-lua - fast Lua syntax gate for PZ mod trees (real Lua 5.1 parse).
rem
rem WHY: a missing `end` or typo'd bracket makes the whole file silently fail
rem to load in-game (PZ prints one console line and moves on) - and the
rem Workshop upload -> server pull -> client restart cycle burns ~10 minutes
rem discovering it. This catches that class of bug in one second, pre-upload.
rem
rem Usage:
rem   tools\check-lua                 check every mod tree in the repo
rem   tools\check-lua <path> [...]    check specific folders or files
rem
rem Silence = clean (exit 0). Anything printed = fix it before uploading.
rem Only syntax errors are reported (--only 011); style/global warnings are
rem deliberately off - PZ mods legitimately use hundreds of engine globals.
rem
rem luacheck.exe (standalone, ~800KB) sits next to this script and is
rem gitignored; re-download if missing:
rem   https://github.com/lunarmodules/luacheck/releases/latest/download/luacheck.exe

setlocal enabledelayedexpansion
set "LUACHECK=%~dp0luacheck.exe"
set "ROOT=%~dp0.."
set FAIL=0

if not exist "%LUACHECK%" (
    echo luacheck.exe not found next to this script. Re-download:
    echo   https://github.com/lunarmodules/luacheck/releases/latest/download/luacheck.exe
    exit /b 3
)

if not "%~1"=="" (
    "%LUACHECK%" --only 011 --std lua51 --formatter plain %*
    exit /b !errorlevel!
)

rem No args: sweep every mod tree (any top-level dir with a Contents/contents folder).
for /d %%D in ("%ROOT%\*") do (
    if exist "%%D\Contents\" (
        "%LUACHECK%" --only 011 --std lua51 --formatter plain "%%D\Contents"
        if !errorlevel! gtr 0 set FAIL=1
    ) else if exist "%%D\contents\" (
        "%LUACHECK%" --only 011 --std lua51 --formatter plain "%%D\contents"
        if !errorlevel! gtr 0 set FAIL=1
    )
)

if !FAIL!==0 echo All mod lua trees parse clean.
exit /b !FAIL!
Bash Find death event triggers in engine
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "OnCharacterDeath\|OnPlayerDeath" --include=*.java PZ_Engine_Decompiled/ | head -20

OUT
PZ_Engine_Decompiled/zombie/characters/animals/IsoAnimal.java:1084:        LuaEventManager.triggerEvent("OnCharacterDeath", this);
PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java:4582:        LuaEventManager.triggerEvent("OnCharacterDeath", this);
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java:6081:            LuaEventManager.triggerEvent("OnPlayerDeath", this);
PZ_Engine_Decompiled/zombie/Lua/LuaEventManager.java:726:        LuaEventManager.AddEvent("OnPlayerDeath");
PZ_Engine_Decompiled/zombie/Lua/LuaEventManager.java:728:        LuaEventManager.AddEvent("OnCharacterDeath");
Bash Verify death hook reachability
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '6040,6100p' PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java && echo "=== IsoGameCharacter OnDeath ===" && sed -n '4560,4600p' PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java

OUT
            if (player == null || player.onlineId != id) continue;
            return player;
        }
        return null;
    }

    public boolean isOnlyPlayerAsleep() {
        if (!this.isAsleep()) {
            return false;
        }
        for (int pn = 0; pn < numPlayers; ++pn) {
            if (players[pn] == null || players[pn].isDead() || players[pn] == this || !players[pn].isAsleep()) continue;
            return false;
        }
        return true;
    }

    public void setHasObstacleOnPath(boolean value) {
        this.hasObstacleOnPath = value;
    }

    public boolean isRemoteAndHasObstacleOnPath() {
        return !this.isLocalPlayer() && this.hasObstacleOnPath;
    }

    @Override
    public void OnDeath() {
        super.OnDeath();
        if (GameServer.server) {
            return;
        }
        this.StopAllActionQueue();
        if (this.isAsleep()) {
            UIManager.FadeIn(this.getIndex(), 0.5);
            this.setAsleep(false);
        }
        this.dropHandItems();
        if (IsoPlayer.allPlayersDead()) {
            SoundManager.instance.playMusic(DEATH_MUSIC_NAME);
        }
        if (this.isLocalPlayer()) {
            LuaEventManager.triggerEvent("OnPlayerDeath", this);
        }
        if (this.isLocalPlayer() && this.getVehicle() != null) {
            this.getVehicle().exit(this);
        }
        this.removeSaveFile();
        if (this.shouldBecomeZombieAfterDeath()) {
            this.forceAwake();
        }
        if (this.getMoodles() != null) {
            this.getMoodles().Update();
        }
        this.getCell().setDrag(null, this.getIndex());
    }

    public boolean isNoClip() {
        return this.getCheats().isSet(CheatType.NO_CLIP);
    }

    public void setNoClip(boolean noClip, boolean isForced) {
=== IsoGameCharacter OnDeath ===
        if (this.lastKnownLocation.containsKey(character)) {
            return this.lastKnownLocation.get(character);
        }
        return null;
    }

    @Override
    public void ReadLiterature(Literature literature) {
        this.stats.add(CharacterStat.STRESS, literature.getStressChange());
        this.getBodyDamage().JustReadSomething(literature);
        if (literature.getLearnedRecipes() != null) {
            for (int i = 0; i < literature.getLearnedRecipes().size(); ++i) {
                if (this.getKnownRecipes().contains(literature.getLearnedRecipes().get(i))) continue;
                this.learnRecipe(literature.getLearnedRecipes().get(i));
            }
        }
        if (literature.hasTag(ItemTag.CONSUME_ON_READ)) {
            literature.Use();
        }
    }

    public void OnDeath() {
        LuaEventManager.triggerEvent("OnCharacterDeath", this);
    }

    public void splatBloodFloorBig() {
        if (this.getCurrentSquare() != null && this.getCurrentSquare().getChunk() != null) {
            this.getCurrentSquare().getChunk().addBloodSplat(this.getX(), this.getY(), this.getZ(), Rand.Next(20));
        }
    }

    public void splatBloodFloor() {
        if (this.getCurrentSquare() == null) {
            return;
        }
        if (this.getCurrentSquare().getChunk() == null) {
            return;
        }
        if (this.isDead() && Rand.Next(10) == 0) {
            this.getCurrentSquare().getChunk().addBloodSplat(this.getX(), this.getY(), this.getZ(), Rand.Next(20));
        }
Bash Find OnDeath callers
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "OnDeath()" --include=*.java PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java PZ_Engine_Decompiled/zombie/iso/IsoMovingObject.java 2>/dev/null | head -20; echo "=== who calls OnDeath ==="; grep -rln "\.OnDeath()" --include=*.java PZ_Engine_Decompiled/ | head -20

OUT
PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java:1804:        this.OnDeath();
PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java:4581:    public void OnDeath() {
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java:6066:    public void OnDeath() {
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java:6067:        super.OnDeath();
=== who calls OnDeath ===
PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java
Bash Read context around OnDeath call
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '1770,1830p' PZ_Engine_Decompiled/zombie/characters/IsoGameCharacter.java

OUT
        return this.legsSprite != null && this.legsSprite.hasActiveModel();
    }

    @Override
    public boolean hasItems(String type, int count) {
        int total = this.inventory.getItemCount(type);
        return count <= total;
    }

    public int getLevelUpLevels(int level) {
        if (LevelUpLevels.length <= level) {
            return LevelUpLevels[LevelUpLevels.length - 1];
        }
        return LevelUpLevels[level];
    }

    public int getLevelMaxForXp() {
        return LevelUpLevels.length;
    }

    @Override
    public int getXpForLevel(int level) {
        if (level < LevelUpLevels.length) {
            return (int)((float)LevelUpLevels[level] * this.levelUpMultiplier);
        }
        return (int)((float)(LevelUpLevels[LevelUpLevels.length - 1] + (level - LevelUpLevels.length + 1) * 400) * this.levelUpMultiplier);
    }

    public final void DoDeath(HandWeapon weapon, IsoGameCharacter wielder) {
        this.DoDeath(weapon, wielder, true);
    }

    public void DoDeath(HandWeapon weapon, IsoGameCharacter wielder, boolean isGory) {
        IsoGameCharacter isoGameCharacter;
        this.OnDeath();
        if (this.getAttackedBy() instanceof IsoPlayer && GameServer.server && this instanceof IsoPlayer) {
            PVPLogTool.logKill((IsoPlayer)this.getAttackedBy(), (IsoPlayer)this);
        } else {
            if (GameServer.server && this instanceof IsoPlayer) {
                LoggerManager.getLogger("user").write("user " + ((IsoPlayer)this).username + " died at " + LoggerManager.getPlayerCoords(this) + " (non pvp)");
            }
            if (ServerOptions.instance.announceDeath.getValue() && !this.isAnimal() && this instanceof IsoPlayer && GameServer.server) {
                ChatServer.getInstance().sendMessageToServerChat(((IsoPlayer)this).username + " is dead.");
            }
        }
        if (GameServer.server && ServerOptions.instance.dropOffWhiteListAfterDeath.getValue() && (isoGameCharacter = this) instanceof IsoPlayer) {
            IsoPlayer player = (IsoPlayer)isoGameCharacter;
            if (!this.isAnimal() && !((IsoPlayer)this).getRole().hasCapability(Capability.CanAlwaysJoinServer)) {
                try {
                    ServerWorldDatabase.instance.removeUser(player.getUsername(), GameServer.serverName);
                }
                catch (SQLException e) {
                    DebugType.General.printException(e, LogSeverity.Error);
                }
                WorldMapVisitedServer.getInstance().deleteUser(player.getUsername());
            }
        }
        this.doDeathSplatterAndSounds(weapon, wielder, isGory);
    }

    /*
Bash Find DoDeath call sites
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "DoDeath(" --include=*.java PZ_Engine_Decompiled/ | grep -v "IsoGameCharacter.java" | head -25

OUT
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java:7644:            this.DoDeath(null, null, isGory);
PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java:7646:            this.DoDeath(killer.getUseHandWeapon(), killer, isGory);
PZ_Engine_Decompiled/zombie/characters/IsoZombie.java:4560:            this.DoDeath(null, null, bGory);
PZ_Engine_Decompiled/zombie/characters/IsoZombie.java:4562:            this.DoDeath(handWeapon, killer, bGory);
PZ_Engine_Decompiled/zombie/characters/IsoZombie.java:4564:            this.DoDeath((HandWeapon)killer.getPrimaryHandItem(), killer, bGory);
PZ_Engine_Decompiled/zombie/characters/IsoZombie.java:4566:            this.DoDeath(this.getUseHandWeapon(), killer, bGory);
Bash Read IsoPlayer death path
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '7600,7660p' PZ_Engine_Decompiled/zombie/characters/IsoPlayer.java

OUT
    public boolean canHearAll() {
        return this.getCheats().isSet(CheatType.CAN_HEAR_EVERYONE);
    }

    public void setCanHearAll(boolean b) {
        if (!Role.hasCapability(this, Capability.CanHearAll)) {
            this.getCheats().set(CheatType.CAN_HEAR_EVERYONE, false);
            return;
        }
        this.getCheats().set(CheatType.CAN_HEAR_EVERYONE, b);
    }

    public ArrayList<String> getAlreadyReadBook() {
        return this.alreadyReadBook;
    }

    public void setMoodleCantSprint(boolean b) {
        this.moodleCantSprint = b;
    }

    public void setAttackFromBehind(boolean attackFromBehind) {
        this.attackFromBehind = attackFromBehind;
    }

    public boolean isAttackFromBehind() {
        return this.attackFromBehind;
    }

    @Override
    public void onKilled(IsoGameCharacter killer, HandWeapon attackingWeapon, boolean isGory) {
        super.onKilled(killer, attackingWeapon, isGory);
        if (GameServer.server) {
            if (this.isOnFire()) {
                ConnectionQueueStatistic.getInstance().playersKilledByFireToday.increase();
            }
            if (killer instanceof IsoZombie) {
                ConnectionQueueStatistic.getInstance().playersKilledByZombieToday.increase();
            }
            if (killer instanceof IsoPlayer) {
                ConnectionQueueStatistic.getInstance().playersKilledByPlayerToday.increase();
            }
        }
        if (killer == null) {
            this.DoDeath(null, null, isGory);
        } else {
            this.DoDeath(killer.getUseHandWeapon(), killer, isGory);
        }
    }

    private void onDied(IsoGameCharacter sender, IsoDeadBody body) {
        if (!GameClient.client && this.shouldBecomeZombieAfterDeath()) {
            body.reanimateLater();
        }
        if (GameServer.server) {
            this.getNetworkCharacterAI().syncDamage();
            GameServer.sendCharacterDeath(body);
        }
    }

    @Override
Bash Read getFileWriter implementation
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '5430,5500p' PZ_Engine_Decompiled/zombie/Lua/LuaManager.java

OUT
            }
            return controller.getButtonCount();
        }

        @LuaMethod(name="setDebugToggleControllerPluggedIn", global=true)
        public static void setDebugToggleControllerPluggedIn(int index) {
            Controllers.setDebugToggleControllerPluggedIn(index);
        }

        @LuaMethod(name="lineSeparator", global=true)
        public static String lineSeparator() {
            return System.lineSeparator();
        }

        @LuaMethod(name="getFileWriter", global=true)
        public static LuaFileWriter getFileWriter(String filename, boolean createIfNull, boolean append) {
            File outFile;
            if (GlobalObject.hasRelativePath(filename)) {
                return null;
            }
            Object str = LuaManager.getLuaCacheDir() + File.separator + filename;
            str = ((String)str).replace("/", File.separator);
            str = ((String)str).replace("\\", File.separator);
            String dir = ((String)str).substring(0, ((String)str).lastIndexOf(File.separator));
            File f = new File(dir = dir.replace("\\", "/"));
            if (!f.exists()) {
                f.mkdirs();
            }
            if (!(outFile = new File((String)str)).exists() && createIfNull) {
                try {
                    outFile.createNewFile();
                }
                catch (IOException ex) {
                    Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                }
            }
            PrintWriter output = null;
            try {
                FileOutputStream fos = new FileOutputStream(outFile, append);
                OutputStreamWriter osw = new OutputStreamWriter((OutputStream)fos, StandardCharsets.UTF_8);
                output = new PrintWriter(osw);
            }
            catch (IOException ex) {
                Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                return null;
            }
            return new LuaFileWriter(output);
        }

        @LuaMethod(name="getSandboxFileWriter", global=true)
        public static LuaFileWriter getSandboxFileWriter(String filename, boolean createIfNull, boolean append) {
            File outFile;
            if (GlobalObject.hasRelativePath(filename)) {
                return null;
            }
            Object str = LuaManager.getSandboxCacheDir() + File.separator + filename;
            str = ((String)str).replace("/", File.separator);
            str = ((String)str).replace("\\", File.separator);
            String dir = ((String)str).substring(0, ((String)str).lastIndexOf(File.separator));
            File f = new File(dir = dir.replace("\\", "/"));
            if (!f.exists()) {
                f.mkdirs();
            }
            if (!(outFile = new File((String)str)).exists() && createIfNull) {
                try {
                    outFile.createNewFile();
                }
                catch (IOException ex) {
                    Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                }
            }
Bash Find file reader/exists primitives
IN
cd "c:/VSCodeProjects/PZMod" && grep -n "getFileReader\|getFileSize\|fileExists\|getAllModFolders\|serverFileExists" PZ_Engine_Decompiled/zombie/Lua/LuaManager.java | head -20

OUT
4086:            ZomboidFileSystem.instance.getAllModFolders(result);
4547:        @LuaMethod(name="fileExists", global=true)
4548:        public static boolean fileExists(String filename) {
4556:        @LuaMethod(name="serverFileExists", global=true)
4557:        public static boolean serverFileExists(String filename) {
4815:        @LuaMethod(name="getFileReader", global=true)
4816:        public static BufferedReader getFileReader(String filename, boolean createIfNull) throws IOException {
Bash Read fileExists and getFileReader
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '4540,4570p;4810,4850p' PZ_Engine_Decompiled/zombie/Lua/LuaManager.java

OUT
            String str = filename;
            str = str.replace("/", File.separator);
            str = str.replace("\\", File.separator);
            File file = new File(ZomboidFileSystem.instance.getCacheDir() + File.separator + "Lua" + File.separator + str);
            return file.exists();
        }

        @LuaMethod(name="fileExists", global=true)
        public static boolean fileExists(String filename) {
            String str = filename;
            str = str.replace("/", File.separator);
            str = str.replace("\\", File.separator);
            File file = new File(ZomboidFileSystem.instance.getString(str));
            return file.exists();
        }

        @LuaMethod(name="serverFileExists", global=true)
        public static boolean serverFileExists(String filename) {
            String str = filename;
            str = str.replace("/", File.separator);
            str = str.replace("\\", File.separator);
            File file = new File(ZomboidFileSystem.instance.getCacheDir() + File.separator + "Server" + File.separator + str);
            return file.exists();
        }

        @LuaMethod(name="takeScreenshot", global=true)
        public static void takeScreenshot() {
            Core.getInstance().TakeFullScreenshot(null);
        }

        @LuaMethod(name="takeScreenshot", global=true)
            if (file.exists()) {
                file.delete();
            }
        }

        @LuaMethod(name="getFileReader", global=true)
        public static BufferedReader getFileReader(String filename, boolean createIfNull) throws IOException {
            if (GlobalObject.hasRelativePath(filename)) {
                return null;
            }
            Object str = LuaManager.getLuaCacheDir() + File.separator + filename;
            str = ((String)str).replace("/", File.separator);
            File outFile = new File((String)(str = ((String)str).replace("\\", File.separator)));
            if (!outFile.exists() && createIfNull) {
                outFile.createNewFile();
            }
            if (outFile.exists()) {
                BufferedReader reader = null;
                try {
                    FileInputStream fis = new FileInputStream(outFile);
                    InputStreamReader isr = new InputStreamReader((InputStream)fis, StandardCharsets.UTF_8);
                    reader = new BufferedReader(isr);
                }
                catch (IOException ex) {
                    Logger.getLogger(LuaManager.class.getName()).log(Level.SEVERE, null, ex);
                }
                return reader;
            }
            return null;
        }

        @LuaMethod(name="getModFileReader", global=true)
        public static BufferedReader getModFileReader(String modId, String filename, boolean createIfNull) throws IOException {
            if (GlobalObject.hasRelativePath(filename) || filename.isEmpty() || new File(filename).isAbsolute()) {
                return null;
            }
            Object str = ZomboidFileSystem.instance.getCacheDir() + File.separator + "mods" + File.separator + filename;
            if (modId != null) {
                ChooseGameInfo.Mod mod = ChooseGameInfo.getModDetails(modId);
                if (mod == null) {
                    return null;
Bash Read function above getFileReader
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '4780,4816p' PZ_Engine_Decompiled/zombie/Lua/LuaManager.java

OUT
            }
            for (File file : outFile.listFiles()) {
                result.add(new BufferedReader(new FileReader(file)));
            }
            return result;
        }

        @LuaMethod(name="getSandboxPresets", global=true)
        public static List<String> getSandboxPresets() {
            ArrayList<String> result = new ArrayList<String>();
            String str = LuaManager.getSandboxCacheDir();
            File outFile = new File(str);
            if (!outFile.exists()) {
                outFile.mkdir();
            }
            for (File file : outFile.listFiles()) {
                if (!file.getName().endsWith(".cfg")) continue;
                result.add(file.getName().replace(".cfg", ""));
            }
            Collections.sort(result);
            return result;
        }

        @LuaMethod(name="deleteSandboxPreset", global=true)
        public static void deleteSandboxPreset(String name) {
            if (GlobalObject.hasRelativePath(name)) {
                return;
            }
            String fileName = LuaManager.getSandboxCacheDir() + File.separator + name + ".cfg";
            File file = new File(fileName);
            if (file.exists()) {
                file.delete();
            }
        }

        @LuaMethod(name="getFileReader", global=true)
        public static BufferedReader getFileReader(String filename, boolean createIfNull) throws IOException {
Bash Identify the cacheDir/Lua exists function
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '4525,4548p' PZ_Engine_Decompiled/zombie/Lua/LuaManager.java

OUT
        }

        @LuaMethod(name="checkSavePlayerExists", global=true)
        public static boolean checkSavePlayerExists() {
            if (!GameClient.client) {
                return PlayerDBHelper.isPlayerAlive(ZomboidFileSystem.instance.getCurrentSaveDir(), 1);
            }
            if (ClientPlayerDB.getInstance() == null) {
                return false;
            }
            return ClientPlayerDB.getInstance().clientLoadNetworkPlayer() && ClientPlayerDB.getInstance().isAliveMainNetworkPlayer();
        }

        @LuaMethod(name="cacheFileExists", global=true)
        public static boolean cacheFileExists(String filename) {
            String str = filename;
            str = str.replace("/", File.separator);
            str = str.replace("\\", File.separator);
            File file = new File(ZomboidFileSystem.instance.getCacheDir() + File.separator + "Lua" + File.separator + str);
            return file.exists();
        }

        @LuaMethod(name="fileExists", global=true)
        public static boolean fileExists(String filename) {
Bash Read MMSnapshotCodec capture and kill carry
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '78,145p' Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSnapshotCodec.lua && echo "=== 425-445 ===" && sed -n '425,445p' Dragonfly/Contents/mods/Dragonfly/42/media/lua/shared/MMSnapshotCodec.lua

OUT
function MMSnapshotCodec.capture(player)
    local snap = {
        schemaVersion = MMShared.SCHEMA_VERSION,
        epoch   = MMShared.WIPE_EPOCH, -- read refuses anything stamped older (amnesty gate)
        perks   = {},
        traits  = {},
        recipes = {},
        kills   = {},
    }

    for i = 0, PerkFactory.PerkList:size() - 1 do
        local perk = PerkFactory.PerkList:get(i)
        local t = perk:getType()
        if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
            local xp = player:getXp():getXP(t)
            if xp and xp > 0 then snap.perks[perk:getId()] = xp end
        end
    end

    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, known:size() - 1 do
        local nm = known:get(i):getName()
        if not isWeightTrait(nm) then table.insert(snap.traits, nm) end -- weight traits re-derive from weight
    end

    local prof = player:getDescriptor() and player:getDescriptor():getCharacterProfession()
    snap.profession = prof and prof:getName() or nil

    local recipes = player:getKnownRecipes()
    for i = 0, recipes:size() - 1 do snap.recipes[recipes:get(i)] = true end

    snap.kills = { Zombie = player:getZombieKills() or 0, Survivor = player:getSurvivorKills() or 0 }

    -- BODY STATE: the full nutrition tuple, not just weight. The engine recomputes weight
    -- from the calorie/macro balance, so restoring weight alone would drift back - we capture
    -- and restore the whole tuple so the body genuinely "is" the saved character again.
    local nut = player.getNutrition and player:getNutrition()
    if nut then
        snap.nutrition = {
            weight   = nut:getWeight(),
            calories = nut:getCalories(),
            lipids   = nut:getLipids(),
            proteins = nut:getProteins(),
            carbs    = nut:getCarbohydrates(),
        }
    end

    -- FAITH (ParanormalZ): a custom modData stat - player:getModData().exorcistFaith, 0..120 -
    -- NOT a PerkFactory skill, so the perk loop above never sees it. Captured verbatim and
    -- restored in full (like nutrition), never scaled by the XP knob. Absent when ParanormalZ
    -- isn't installed -> snap.faith stays nil and restore skips it.
    local md = player:getModData()
    if md and md.exorcistFaith ~= nil then snap.faith = md.exorcistFaith end

    -- LIFE-ID: which life wrote this book. Stamped into player modData by the write
    -- path (once per life - death wipes player modData). On read, a matching id means
    -- the same life is reading its own history: the additive XP model would double it,
    -- so the read refuses instead.
    snap.lifeId = md and md.MMLifeId or nil

    MMlog("CAPTURE for " .. MMname(player) .. " | profession=" .. tostring(snap.profession)
        .. " traits=" .. tostring(#snap.traits) .. " recipes=" .. tostring(countSet(snap.recipes)))
    MMlogTable("  CAPTURE perks(raw XP)", snap.perks)
    MMlogTable("  CAPTURE traits", snap.traits)
    return snap
end

-- ========================
=== 425-445 ===
            player:learnRecipe(recipeID); learned = learned + 1
        end
    end
    MMlog("  RECIPES +" .. tostring(learned) .. " of " .. tostring(countSet(snap.recipes)))

    -- KILLS: disjoint lives on overwrite -> additive (book's tally + this life's);
    -- legacy top-up -> max (same history may overlap, never add)
    if snap.kills then
        if mode == "overwrite" then
            player:setZombieKills((snap.kills.Zombie or 0) + (player:getZombieKills() or 0))
            player:setSurvivorKills((snap.kills.Survivor or 0) + (player:getSurvivorKills() or 0))
        else
            player:setZombieKills(maxn(snap.kills.Zombie, player:getZombieKills()))
            player:setSurvivorKills(maxn(snap.kills.Survivor, player:getSurvivorKills()))
        end
    end
end

-- BODY STATE: restore the saved nutrition tuple, then let the engine RE-DERIVE the weight
-- trait from the restored weight. Set-to-saved (never merged) - weight isn't earnable, it's
-- the body you respawn into; "same character, same body." Runs last so applyTraitFromWeight()
Bash Read RCClaim keys
IN
cd "c:/VSCodeProjects/PZMod" && sed -n '1,45p' Reclamation/Contents/mods/RFTDReclamation/42/media/lua/shared/RCClaim.lua

OUT
-- RCClaim - the claim brain. Loaded on both sides.
--
-- Owns the vehicle-modData claim scheme and the access dispatchers. Access is
-- GRANULAR: four permissions, each grantable per-whitelisted-player AND as a
-- per-vehicle "public" (everyone) flag.
--   driver    - enter/occupy the DRIVER seat (seat 0), seat-swap to it, tow
--   passenger - enter/occupy a PASSENGER seat, seat-swap to it
--   mechanic  - open the vehicle mechanics UI
--   inventory - take from the vehicle (trunk/seats/glovebox) + siphon fuel
-- Smashing a claimed car's window is owner/admin only (no tier grants it).
-- Opening/unlocking a door needs only "any access" (it's benign; the harmful
-- action behind it is gated at its own point).
--
-- Two dispatchers, both routed through here so UX and enforcement never differ:
--   canDo(vehicle, player, perm) - may this player do THIS specific thing?
--   canInteract(vehicle, player) - does this player have ANY access at all?
--                                  (used to fully hide the menus from a no-
--                                   access player; partial-access players see
--                                   the menu and are gated per-action.)
--
-- Reads only. Writes happen SERVER-SIDE ONLY (RCServer) + transmitModData.

RCClaim = RCClaim or {}

RCClaim.KEY_OWNER    = "RC_ClaimOwner"   -- owner username
RCClaim.KEY_ALLOWED  = "RC_ClaimAllowed" -- map: username -> {driver,passenger,mechanic,inventory = bool}
RCClaim.KEY_PUBLIC   = "RC_ClaimPublic"  -- {driver,passenger,mechanic,inventory = bool} for EVERYONE
RCClaim.KEY_USED     = "RC_ClaimUsed"    -- last-claimed stamp (os.time)
RCClaim.KEY_ID       = "RC_ClaimId"      -- stable id (getId() is not stable across reload)
RCClaim.LEGACY_OWNER = "WG_Claim_Owner"  -- VehicleClaimWG legacy read => seamless cutover

RCClaim.PERMS = { "driver", "passenger", "mechanic", "inventory" }

-- Owner username, or nil. Falls back to the legacy WG key.
function RCClaim.getOwner(vehicle)
    if not vehicle then return nil end
    local md = vehicle:getModData()
    local o = md[RCClaim.KEY_OWNER]
    if o and o ~= "" then return o end
    local legacy = md[RCClaim.LEGACY_OWNER]
    if legacy and legacy ~= "" then return legacy end
    return nil
end

function RCClaim.isClaimed(vehicle)
Bash Find all getFileWriter call sites
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "getFileWriter" --include=*.lua . | head -30

OUT
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua:8:--   2. getFileWriter is the only file API that works on BOTH sides in B42
./Dirge/Contents/mods/RFTDDirge/42/media/lua/shared/RQReflectLog.lua:38:        local writer = getFileWriter(FILE, true, true)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/client/Longstrider/LSTours.lua:163:        local w = getFileWriter(FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFPlayerRoles_Server.lua:63:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/DFRoleEdit_Server.lua:96:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:20:-- Nested dirs are ENGINE-GUARANTEED: getFileWriter runs File.mkdirs() on the
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:21:-- full parent chain (LuaManager.getFileWriter, verified in the 42.19 decompile),
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:25:-- getFileWriter is the ONLY server-side I/O that works in B42 (raw io.open is
./Dragonfly/Contents/mods/Dragonfly/42/media/lua/server/Memoirs/MMAudit.lua:158:    pcall(function() w = getFileWriter(DIR .. path, true, append) end)
./DragonflyTest/Contents/mods/DragonflyTest/42/media/lua/client/Longstrider/LSTours.lua:163:        local w = getFileWriter(FILE, true, false)
./DragonflyTest/Contents/mods/DragonflyTest/42/media/lua/server/DFPlayerRoles_Server.lua:63:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./DragonflyTest/Contents/mods/DragonflyTest/42/media/lua/server/DFRoleEdit_Server.lua:96:    local writer = getFileWriter(OVERRIDES_FILE, true, false)
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua:6:-- B42 only exposes getFileWriter/getFileReader for Lua file I/O (io.open is
./Last Rites/Contents/mods/RFTDLastRites/42/media/lua/client/LRPrefs.lua:59:    local w = getFileWriter(FILE, true, false)  -- create, don't append
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:11:-- recording every fill/in/out/destroy with quantities, via getFileWriter (the only file I/O that
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/server/BXServer.lua:34:        local w = getFileWriter(BX.LOGFILE, true, true) -- createIfNull, append (never truncate)
./OddsAndEnds/Contents/mods/RFTDOddsandEnds/42/media/lua/shared/BXShared.lua:27:-- Audit log filename, written to Zomboid/Lua/ via getFileWriter (the only file I/O that works in
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/client/OSNClient.lua:6:-- writing its own encrypted OSN-Debug.txt into Zomboid/Lua/ (client sandbox: getFileWriter, no luajava).
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:16:--   * getFileWriter is the only file I/O that works server-side in B42; open-write-close per row so each
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/server/GuardianLogger.lua:123:        local w = getFileWriter(fileName, true, true)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:3:-- Uses the engine-blessed getFileWriter API on BOTH sides (server + client). The old RQDirgeLog
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:6:-- getFileWriter works on the dedicated server too (cf. Bumblebee_FastMoveWhitelist) and writes to
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:30:        local w = getFileWriter(fileName, true, true)
./OmenSpyNetwork/Contents/mods/OmenSpyNetwork/42/media/lua/shared/OSNLog.lua:87:-- No-op: getFileWriter open-write-close per line means every line is already flushed to disk.
./ReclaimTest/Contents/mods/ReclaimTest/42/media/lua/server/RCAudit.lua:3:-- getFileWriter is the ONLY working B42 server-side file I/O (raw io.open is
./ReclaimTest/Contents/mods/ReclaimTest/42/media/lua/server/RCAudit.lua:25:    local ok, writer = pcall(getFileWriter, FILE, true, false) -- append=true
./ReclaimTest/Contents/mods/ReclaimTest/42/media/lua/server/RCDamageAudit.lua:71:    local ok, writer = pcall(getFileWriter, FILE, true, false) -- append
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCAudit.lua:3:-- getFileWriter is the ONLY working B42 server-side file I/O (raw io.open is
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCAudit.lua:25:    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
./Reclamation/Contents/mods/RFTDReclamation/42/media/lua/server/RCDamageAudit.lua:71:    local ok, writer = pcall(getFileWriter, FILE, true, true) -- createIfNull, append (never truncate)
Bash Find consumer registrations
IN
cd "c:/VSCodeProjects/PZMod" && grep -rn "Dragonfly.registerTab\|Dragonfly.registerRowAction\|DFRegistry" --include=*.lua Reaper Dirge Husbandry "Last Rites" Reclamation OddsAndEnds | grep -v "^Dragonfly" | head -20

OUT
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:13:-- DFRegistry check happens inside the OnGameStart callback below, not here.
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:239:    local actions = DFRegistry.getRowActions("necro")
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:510:    if not DFRegistry then return end
Reaper/Contents/mods/RFTDReaper/42/media/lua/client/RPNecroTab.lua:511:    DFRegistry.registerTab{
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:13:-- DFRegistry check happens inside the OnGameStart callback below, not here.
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:53:    if not DFRegistry or not Capability then return end
Dirge/Contents/mods/RFTDDirge/42/media/lua/client/RQNecroActions.lua:55:        DFRegistry.registerRowAction{
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:3:-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry isn't
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:14:-- DFRegistry check happens inside the OnGameStart callback below, not here.
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:386:    if not DFRegistry then return end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:387:    DFRegistry.registerTab{
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:913:    if DFPanel and DFRegistry and DFRegistry.tabs and DFRegistry.tabs["animals"] then
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:9:-- Soft-depends on Dragonfly: bails inside OnGameStart if DFRegistry is absent.
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:307:    if not DFRegistry then return end
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:308:    DFRegistry.registerTab{
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:4:-- OnGameStart and bails if the DFRegistry global is absent, so Reclamation
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:268:-- Deferred registration: DFRegistry may not exist (no Dragonfly) and load
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:271:    if not DFRegistry then return end
Reclamation/Contents/mods/RFTDReclamation/42/media/lua/client/RCVehicleTab.lua:273:        DFRegistry.registerTab{
Bash Check Cookbook/Sector7 lua and Husbandry senders
IN
cd "c:/VSCodeProjects/PZMod" && echo "=== Cookbook lua ===" && find Cookbook -name "*.lua" | head && echo "=== Sector7 lua ===" && find Sector7 -name "*.lua" | head && echo "=== HB client senders ===" && grep -rn "sendClientCommand\|sendServerCommand" --include=*.lua Husbandry | head -20

OUT
=== Cookbook lua ===
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/client/RFTDCBClient.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/server/RFTDCBServer.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/OC_BaseballBatCostsOneNotepad.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/OC_RemoveAluminumFromBatScrap.lua
Cookbook/Contents/mods/RFTDCookbook/42/media/lua/shared/RFTDCBShared.lua
=== Sector7 lua ===
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/ALICEPacks_HotbarAttachDefinition.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/Meiya_TweakItem.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/S7_Merit_Display.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/client/VaccinesZMenu.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/items/Meiya'CityDistributions.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/items/Meiya'sCityWorldFiller.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaCityCommand.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/server/MeiyaFreeSpawnsCar.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/AZ_InjectBackpackAttachments.lua
Sector7/Contents/mods/Sector-7 Breach/common/media/lua/shared/MeiyaCitySpawns.lua
=== HB client senders ===
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:263:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_PROBE, { id = tostring(row.oid) })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:268:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.0, label = "refill" })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBAnimalsTab.lua:298:    sendClientCommand(getPlayer(), "RQ", HBCmd.DEBUG_REFILL, { value = 0.9, label = "starve" })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBContextMenu.lua:25:            sendClientCommand(player, "RQ", HBCmd.ADD_SEEN, { id = tostring(oid) })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:734:    sendClientCommand(player, "RQ", HBCmd.DEBUG_REFILL, {
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBDebugPanel.lua:757:    sendClientCommand(player, "RQ", HBCmd.DEBUG_PROBE, { id = tostring(row.oid) })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/client/HBHutchesTab.lua:220:    sendClientCommand(getPlayer(), "RQ", HBCmd.ADD_BEDDING,
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBAPIProbe.lua:27:        sendServerCommand(player, "RQ", HBCmd.DEBUG_PROBE_RESULT, { line = s })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/server/HBSexCheck_Server.lua:40:    pcall(function() sendServerCommand(player, "RQ", "hbDebugProbeResult", { line = line }) end)
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua:62:            sendServerCommand(player, "RQ", HBCmd.DEBUG_PROBE_RESULT,
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua:97:        sendServerCommand(player, "RQ", HBCmd.DEBUG_PROBE_RESULT, { line = msg })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/HBSexCheck.lua:78:        sendClientCommand(getPlayer(), "RQ", "hbSexCheck", { id = oid })
Husbandry/contents/mods/RFTDHusbandry/42/media/lua/shared/TimedActions/HBAddHayAction.lua:51:        sendClientCommand(self.character, "RQ", HBCmd.ADD_BEDDING,
The plan is solid. Let me verify one detail the owner named specifically - the map deep-link format - before locking the schema.

Web Fetchhttps://map.projectzomboid.com/
Fetched from https://map.projectzomboid.com/
The map site doesn't expose its deep-link format in the page - which actually confirms the plan's call to log raw coordinates and resolve the link shape at render time, not bake it into the schema. I'll note it as an open item against the PZmap GitHub repo.

Three decisions I need from you before finalizing.

AskUserQuestion
OUT
The user answered: "Where should the Reflections HTML actually be generated?"="I'm thinking of a different shape. The Core emits a schema and we build the chassis that the schema drives seperately. We dont need it to generate html itself - that seems like a bad idea in a way. it's making my nose itch", "Who is a player's Reflection page visible to?"="Private per player (Recommended)", "How much runway is there before the season this should capture?"="42.20 releases on the 28th". Read the answers carefully - they may request clarification, changes, or that you not proceed - and follow what they actually say.
Understood on all three - that reframes the renderer as schema-driven and makes the timeline tight. 42.20 on the 28th is three days out, so the wipe window is effectively now.

Write C:\Users\micha\.claude\plans\alright-i-think-you-foamy-quasar.md
354 lines
There is no way we can do that for this season. This will be a next season surprise for all the players
That changes the shape of this significantly - and for the better. Let me revise the plan.

Edit C:\Users\micha\.claude\plans\alright-i-think-you-foamy-quasar.md
Added 10 lines
Edit C:\Users\micha\.claude\plans\alright-i-think-you-foamy-quasar.md
Added 20 lines
Plan revised. Now calling for approval.

Claude's Plan C:\Users\micha\.claude\plans\alright-i-think-you-foamy-quasar.md