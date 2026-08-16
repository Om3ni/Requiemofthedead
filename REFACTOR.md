# The Narrow Bridge

## Three-phase plan out of `pcall` hell

Status: working plan, 2026-08-15  
Engine evidence: `PZ_Engine_Decompiled_42.20.2-ffe7a8a4b1`  
Starting point: 460 `pcall` sites across 12 shipping mods; all repository gates green

## Why this exists

The suite has already fallen from roughly 2,400 guards to 460. That is real progress,
but the remaining number still says two different things at once:

- legitimate failure boundaries exist around independent rows, foreign callbacks,
  optional integrations, and secondary file/network sinks;
- deterministic engine calls, Java collection access, UI work, and broad blocks are
  still mixed into those boundaries.

The goal is not zero `pcall`. The goal is that every remaining guard names a failure the
current engine or an external boundary can genuinely produce, isolates the smallest useful
operation, and has an explicit recovery that preserves a truthful result.

This plan implements the decision procedure in `AGENTS.md` and `CLAUDE.md`. Those files
remain authoritative if this document drifts.

## Progress ledger

- [ ] Phase One — Clear the false uncertainty
- [ ] Phase Two — Build boundaries that deserve protection
- [ ] Phase Three — Prove the survivors and close the door

Append one row after each completed slice. Counts are the scanner result before and after,
not a hand count.

| Date | Phase | Mod / responsibility | Guards | Decision summary | Verification |
|---|---|---|---:|---|---|
| 2026-08-15 | Baseline | Whole shipping tree | 460 | Green starting signal | All repository gates |
| 2026-08-15 | Phase One | RFTDBanBox / client removal notice | 1 → 0 | removed: one invalid `ISChat.addLineInChat` call; BanBox sends text while vanilla requires a `ChatMessage`, so its `pcall` only hid the contract error. redesigned: none. retained: none. | Vanilla `ISChat.lua:707-708`; focused BanBox notice test (10 assertions); all repository gates |
| 2026-08-15 | Phase One | RFTDStaffTools / persisted role reapply | 3 → 0 | removed: direct field-return role comparison and validated authoritative role assignment; removed the unrelated ObjectModData send. redesigned: none. retained: none. | `IsoPlayer.java:6987-6989, 8065-8089`; `Role.java:47-49`; `IsoObject.java:4470-4480`; `GameServer.java:2666-2671`; focused role test (4 assertions); all repository gates |
| 2026-08-15 | Phase One | RFTDLastRites / danger tick listener | 1 → 0 | removed: one broad `update()` wrapper whose only purpose was duplicate event-error reporting. redesigned: none. retained: none. | `Event.java:53-63`; focused danger-poll test (5 assertions); Lua syntax and pcall gates |
| 2026-08-15 | Phase One | RFTDLastRites / HUD and moodle teardown | 2 → 0 | removed: direct vanilla UI teardown calls after their ordinary `javaObject` preconditions; a swallowed teardown still discarded the owner reference, so it provided no recovery. redesigned: none. retained: none. | Vanilla `ISUIElement.lua:1373-1380`; all repository gates |
| 2026-08-15 | Phase One | RFTDReaper / LZI peak governor | 1 → 0 | removed: broad unsupported cross-build probe around the registered Build 42.20 peak option and bridge call. redesigned: none. retained: none. | `SandboxOptions.java:550-559, 1963`; focused governor test (7 assertions); Lua syntax and pcall gates |
| 2026-08-15 | Phase One | RFTDReaper / cull cleanup and world-list lookup | 3 → 1 | removed: direct fixed-build zombie cell/list cleanup and one duplicate lifecycle guard. redesigned: two global world-list lookups now share one guarded helper. retained: one `getCell` guard because no world exists before construction. | `IsoObject.java:1842-1844`; `IsoCell.java:2339-2341`; `LuaManager.java:4771-4774`; Reaper scheduler test (20 assertions); Lua syntax and pcall gates |
| 2026-08-15 | Phase One | RFTDReaper / survivor audit | 5 → 5 | removed: none. redesigned: callback recovery now emits bounded diagnostics. retained: per-zombie `getOutfitName` and `removeFromWorld` hazards, one pre-world `getCell` boundary, and two independent foreign callbacks. | Current `RPCore.lua` evidence comments; Reaper scheduler and full repository gates |
| 2026-08-15 | Phase One | RFTDOddsAndEnds / ContainerOrder UI wrappers | 4 → 0 | removed: direct vanilla scroll-height, refresh, and render calls; each had a validated receiver and no useful recovery after swallowing a failure. redesigned: none. retained: none in this responsibility. | Vanilla `ISUIElement.lua:292-297, 1191-1198, 1627-1633`; focused ContainerOrder test (40 assertions); Lua syntax, pcall, and full behavioral gates |
| 2026-08-15 | Phase One | RFTDOddsAndEnds / InventoryCollapse pane integration | 3 → 0 | removed: direct vanilla pane refresh/scrollbar calls and the local post-refresh filter pass; swallowed failures had no repair and could present stale inventory state. redesigned: none. retained: per-item weight reads, whose script chains can legitimately fail, for Phase Two. | Vanilla `ISInventoryPane.lua:1787, 2022, 2196`; all repository gates |
| 2026-08-16 | Phase One | RFTDLimes / editor UI reparent and teardown | 2 → 0 | removed: direct vanilla `removeChild` and explicit nil precondition before the census-label update; neither exception path had recovery beyond continuing with the same state. redesigned: teardown is now a visible `ui`/widget absence check. retained: map projection, persistence, foreign integrations, and engine lifecycle hazards. | Vanilla `ISUIElement.lua:1480-1485`; all repository gates |
| 2026-08-16 | Phase One | RFTDLimes / client noplayers bounce | 2 → 0 | removed: the guard around an invalid `setLx`/`setLy` sequence and its redundant event wrapper. redesigned: direct `setX`/`setY` restores each axis's current and next coordinates through the engine's own movement contract. retained: the Dragonfly feedback callback, an optional explanation after enforcement. | `IsoMovingObject.java:478-498`; focused restriction-client test (5 assertions); all repository gates |
| 2026-08-16 | Phase One | RFTDLimes / periodic zed census | 1 → 0 | removed: the listener-wide diagnostic wrapper; it duplicated the engine's own per-listener containment and did not suppress its error reporting. redesigned: none. retained: the independent scan, wire, and optional-integration boundaries in the zed subsystem. | `Event.java:53-63`; all repository gates |
| 2026-08-16 | Phase One | RFTDDirge / cast and health HUD teardown | 3 → 0 | removed: direct vanilla UI teardowns after the existing owner and `javaObject` preconditions; swallowed teardown errors had no repair path. redesigned: none. retained: caller-owned cast-bar callbacks and per-effect engine boundaries. | Vanilla `ISUIElement.lua:1373-1380`; Lua syntax, pcall, and full behavioral gates |
| 2026-08-16 | Phase One | RFTDOddsAndEnds / Workshop handcraft panel | 4 → 0 | removed: direct refresh and layout calls on the successfully built vanilla handcraft panel; stale UI was not a recovery from an invalid panel contract. redesigned: none. retained: the optional panel-build and foreign routing boundaries. | Vanilla `ISHandCraftPanel.lua:99-173, 176-183`; all repository gates |
| 2026-08-16 | Phase One | RFTDLimes / import-log list scrolling | 1 → 0 | removed: direct vanilla list visibility update; the actual method validates its input and has no render dependency. redesigned: none. retained: optional import-tab construction and layout isolation. | Vanilla `ISScrollingListBox.lua:623-638`; Lua syntax, pcall, and full behavioral gates |
| 2026-08-16 | Phase One | Dragonfly / stale sidebar and map child teardown | 3 → 0 | removed: direct vanilla `removeChild` calls after parent/child preconditions; a destroyed backing UI object is already a no-op in vanilla. redesigned: none. retained: tenant callbacks, Core integrations, and persistence I/O boundaries. | Vanilla `ISUIElement.lua:1480-1485`; Lua syntax, pcall, and full behavioral gates |
| 2026-08-16 | Phase One | Dragonfly / deck visibility lifecycle | 3 → 0 | removed: visibility probes around valid deck instances; vanilla instantiates its backing object before reading visibility. redesigned: existing nil-instance checks remain as the lifecycle boundary. retained: tenant callbacks, Core integrations, and persistence I/O boundaries. | Vanilla `ISUIElement.lua:676-680`; Lua syntax, pcall, and full behavioral gates |
| 2026-08-16 | Phase One | RFTDReclamation / radial menu re-centering | 1 → 0 | removed: direct vanilla menu geometry updates after the existing menu precondition; dimensions instantiate their backing UI object and positioning is normal UI work. redesigned: none. retained: foreign slice-provider callbacks and vehicle-operation boundaries. | Vanilla `ISUIElement.lua:195-215, 259-271`; Lua syntax, pcall, and full behavioral gates |
| 2026-08-16 | Phase One | RFTDMemoir / delayed inventory refresh | 2 → 0 | removed: direct vanilla inventory-pane refresh calls after explicit pane lifecycle checks; swallowing a pane-contract failure left the result UI stale with no recovery. redesigned: none. retained: snapshot mirror, trait, audit, and persistence boundaries. | Vanilla `ISInventoryPane.lua:2022`; focused Memoir client test (6 assertions); all repository gates |
| 2026-08-16 | Phase One | Dragonfly Longstrider / ordinary UI setup | 4 → 0 | removed: direct vanilla button tinting, numeric-field setup, and rename-modal construction after their normal widget lifecycle steps. redesigned: none. retained: Core callbacks, tenant integration, map startup, and file/I/O boundaries. | Vanilla `ISButton.lua:386-400`, `ISTextEntryBox.lua:32-34`, `ISTextBox.lua:280-283`; all repository gates |
| 2026-08-16 | Phase One | Dragonfly / player-stats window replacement | 1 → 0 | removed: stale-instance close wrapper; vanilla's own panel opener directly closes the current instance, whose inherited close only hides the panel. redesigned: none. retained: Core registry and admin-operation boundaries. | Vanilla `ISPlayerStatsUI.lua:854-857`, `ISPanel.lua:14-16`; all repository gates |
| 2026-08-16 | Phase One | RFTDDirge / Screamer panic bump | 1 → 0 | removed: speculative future-build guard around the current exported `CharacterStat.PANIC` and local stats update. redesigned: none. retained: SearchMode, per-item, trait-registry, callback, and lifecycle boundaries. | `CharacterStat.java:27`, `Stats.java:87-89`; all repository gates |
| 2026-08-16 | Phase One | RFTDHusbandry / debug animal highlighting | scanner-exempt | removed: three direct outline bit/color writes after valid animal and player checks. The debug engine-probe file is deliberately excluded from `check-pcall`, so the scanner remains 415. retained: per-animal scan and probe containment. | `IsoObject.java:5115-5119, 5154-5158`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / entry, help, and settings dialog teardown | 3 → 0 | removed: direct vanilla UI teardowns after owner-instance checks; swallowing a failure still cleared the owner reference and gave no recovery. redesigned: none. retained: entry focus, callback, validation, and platform boundaries. | Vanilla `ISUIElement.lua:1373-1380`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / console tail selection | 1 → 0 | removed: direct vanilla list scroll update after rebuilding the list and selecting its known tail index; a swallowed UI failure left the live console stale. redesigned: none. retained: stale-widget, callback, registry, and logging boundaries. | Vanilla `ISScrollingListBox.lua:623-638`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / entry dialog focus release | 1 → 0 | removed: direct focus release from an instantiated entry widget; swallowing it could leave the removed dialog consuming keyboard input. redesigned: none. retained: entry validation and foreign callbacks. | Vanilla `ISTextEntryBox.lua:150-152`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / entry widget setup | 3 → 0 | removed: speculative cross-build wrappers around current instantiated-widget max-length, placeholder, and focus setup. redesigned: none. retained: font fallbacks, validation, and foreign callbacks. | `UITextBox2.java:542-545, 673-675, 739-741`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / console self-rebuilds | 3 → 0 | removed: local rebuild wrappers with no independent recovery; swallowing them left console selection, detail, or relayout stale. redesigned: none. retained: stale-widget, registry, and external logging boundaries. | Current `DFConsoleTab.lua` ownership checks; all repository gates |
| 2026-08-16 | Phase One | RFTDReclamation / vehicle preview teardown | 2 → 0 | removed: direct vanilla preview UI teardowns after existing preview checks; swallowing failure only leaked the element and did not provide recovery. redesigned: none. retained: preview scene construction, vehicle authority, and foreign boundaries. | Vanilla `ISUIElement.lua:1373-1380`; all repository gates |
| 2026-08-16 | Phase One | RFTDReclamation / dismantle-menu option replacement | 1 → 0 | removed: direct vanilla context-menu option removal before adding the superseding dismantle action; empty or absent lists already return cleanly. redesigned: none. retained: claim, vehicle, and wrapper boundaries. | Vanilla `ISContextMenu.lua:1016-1019`; all repository gates |
| 2026-08-16 | Phase One | RFTDOddsAndEnds / Workshop Journal internal Craft route | 1 → 0 | removed: local Journal-to-Craft routing wrapper; the selected row supplies the Journal's own indexed recipe to its local helper, so swallowing failure had no recovery. redesigned: none. retained: public cross-mod routing, panel construction, and per-script boundaries. | Current `WSJournal.lua`/`WSTab.lua` route ownership; all repository gates |
| 2026-08-16 | Phase One | RFTDLimes / details-view visibility refresh | 3 → 0 | removed: direct vanilla visibility updates after widget references exist; the engine instantiates a missing backing object itself, so swallowing failure risked stale overlapping forms. redesigned: none. retained: map transform, font, import, persistence, and foreign boundaries. | Vanilla `ISUIElement.lua:657-660`; all repository gates |
| 2026-08-16 | Phase One | RFTDCore / settings preference relayout | 1 → 0 | removed: local settings-window relayout wrapper with no independent recovery; swallowing it left preferences visibly stale. redesigned: none. retained: preference persistence and external callbacks. | Current `DFSettingsWindow.lua` owner-instance check; all repository gates |
| 2026-08-16 | Phase Two | RFTDCore / client telemetry receivers | 2 → 0 | removed: listener-wide guards around validated Core server-command envelopes. redesigned: malformed envelopes are rejected and malformed relay rows are skipped at their own boundary. retained: none in these receivers; the engine still contains and reports listener failures. | Current `RDTripwire.lua`/`RDCmdRelay.lua` payload contracts; `Event.java:53-63`; all repository gates |
| 2026-08-16 | Phase Two | RFTDCore / forensic archive boundary | 6 → 5 | removed: the guarded directory walk that destructively reclaimed numbered ring files. redesigned: all thirteen forensic streams now roll by UTC window and target file size into collision-safe immutable parts; existing ring/legacy segments are never opened; `head.txt` is advisory only; Limes restriction records now use the complete Core call contract. retained: narrow record/segment I/O and optional tally boundaries, whose failures preserve gameplay, increment a visible counter, and emit bounded diagnostics. | `LuaManager.java:4617-4623, 5523-5555`; `OsLib.java:44-50, 87-121`; archive tests (47 assertions), Limes forensic contract (8), mixed-era reader paths (5); all repository gates; Mosaic dedicated-server smoke: UTC-window rollover preserved prior archives, six new segments/60 valid JSONL records, write canary healthy, and no stack-trace errors |

## Starting inventory

| Mod | Current guards |
|---|---:|
| RFTDCore | 111 |
| RFTDReclamation | 82 |
| Dragonfly | 47 |
| RFTDMemoir | 46 |
| RFTDDirge | 43 |
| RFTDHusbandry | 40 |
| RFTDLimes | 39 |
| RFTDOddsAndEnds | 36 |
| RFTDReaper | 8 |
| RFTDLastRites | 4 |
| RFTDStaffTools | 3 |
| RFTDBanBox | 1 |

Two shapes deserve special attention:

- 91 guards are opaque to the method-call checker. They may be valid callbacks or local
  operations, but automated engine-call verification cannot tell.
- 141 guards contain multiple method targets. Some are coherent transactions; others hide
  several unrelated operations behind one fallback.

The most frequent protected targets include Java collection `get`/`size`, file
`write`/`close`/`readLine`, `string.format`, `math.floor`, font measurement, UI removal,
and vehicle/building operations. Frequency is a routing signal, not proof that a guard is
wrong.

## Rules for every work slice

One slice is one file or one tightly coupled responsibility. Before editing it:

1. Record each guard's protected operation, possible throw, recovery, and caller boundary.
2. Read the current Java or vanilla Lua body for every engine claim. Cite class and line in
   code when the conclusion is not obvious from the call-site contract.
3. Classify the guard:
   - **remove** — the operation is deterministic once ordinary preconditions hold;
   - **redesign** — the region is too broad, probes repeatedly, or substitutes a false
     default for required data;
   - **retain** — a real failure remains and the caller can recover usefully.
4. Add or repair the narrow test/observable signal before changing behavior. Fault
   injection must model a failure production can actually encounter.
5. Make the smallest coherent change. Do not combine pcall work with naming, networking,
   ownership, save/wire, or feature refactors.
6. Run the focused test, then the repository gates. Lower the ratchet only after the slice
   is proven.

Every slice ends with a short ledger entry in its commit or review notes:

```text
removed:   <count and why direct calls are valid>
redesigned:<count and the new boundary>
retained:  <count, exact failure, recovery, and test/diagnostic>
evidence:  <decompile/vanilla locations read>
```

## Phase One — Clear the false uncertainty

### Objective

Remove guards whose only job is to express uncertainty, and expose broad regions that must
be redesigned in Phase Two. This phase changes error visibility, not intended feature
behavior.

### Work

- Call Lua standard-library operations directly. Invalid arguments are programming or
  input-validation errors, not runtime contingencies.
- Establish nil, bounds, load-order, side, and object-state preconditions before Java
  collection or engine calls.
- Continue the decompile-backed safe-call sweep. Add a method name to
  `tools/pcall-safe.json` only when every plausible receiver satisfies the shared-name rule.
- Split multi-target guards so setup, required state, optional enrichment, and secondary
  effects no longer share one fallback.
- Remove guards justified by engine event containment, log suppression, or impossible test
  doubles.
- Mark real I/O, foreign-callback, optional-integration, and independent-row boundaries for
  Phase Two; do not delete them to satisfy a count.

### Order

1. Pilot the process on RFTDBanBox, RFTDStaffTools, RFTDLastRites, and RFTDReaper.
2. Sweep leaf gameplay modules: Odds and Ends, Limes, Husbandry, and Dirge.
3. Sweep the larger surfaces: Reclaimation, Dragonfly, and Memoir.
4. Sweep Core last, after repeated satellite patterns show which contracts genuinely
   belong in shared infrastructure.

### Exit conditions

- No `pcall` remains around Lua formatting, math, table/string helpers, or another
  operation that cannot legitimately fail with validated inputs.
- Every engine call in a removed guard has cited evidence or an already verified contract.
- Every remaining multi-target guard is either one coherent transaction or explicitly
  queued for Phase Two.
- Fixtures model valid engine surfaces and fail loudly when required methods are absent.
- All gates pass and the per-mod baselines only move downward.

A plausible result is 300–340 guards. That is a forecast, not a quota.

## Phase Two — Build boundaries that deserve protection

### Objective

Replace blanket containment with narrow failure isolation and truthful recovery.

### Workstreams

#### File and network sinks

- Protect one record, segment, or optional sink—not every `write`, `close`, and conversion.
- Complete authoritative state changes before secondary telemetry where the domain permits.
- Return a structured success/failure result or emit one bounded diagnostic. Never turn a
  failed required write into a claimed success.
- Treat cleanup failure separately only when it changes the caller's recovery.

#### Independent batches

- Keep per-row/per-vehicle/per-player isolation when one bad entry must not abort peers.
- Put required batch setup outside the guard.
- Identify the failed member in the diagnostic and continue only when partial success is a
  valid domain result.

#### Foreign callbacks and optional integrations

- Put the guard at one adapter boundary owned by the caller.
- Validate capability and version before invocation when an authoritative check exists.
- Cache stable compatibility verdicts rather than probing on every tick or object.
- Disable only the optional integration after failure; do not default required suite state.

#### Engine lifecycle hazards

- Prefer the correct event, side gate, load order, and receiver precondition.
- When a current engine body can still throw, guard only that call and state the exact
  recovery.
- Do not use a cross-build compatibility probe unless the feature truly supports more than
  the verified build; one-shot probes must cache and expose their verdict.

### Priority seams

- Core logging/forensics and Limes persistence: consolidate per-method file guards into
  record/segment boundaries.
- Memoir audit/restore: preserve independent-character and optional-mod isolation without
  fabricating snapshot data.
- Reclaimation scans: preserve per-vehicle progress while moving verified vehicle state out
  of broad guards.
- Dragonfly/UI: rely on engine listener/render containment; retain guards only at foreign
  registration or genuinely optional rendering surfaces.
- Husbandry and Dirge: separate young/cross-build APIs from verified Build 42 calls.

### Exit conditions

- No broad guard protects unrelated authoritative and optional work.
- No repeated exception-based capability probe remains in a hot path.
- Each retained guard has a named failure, useful recovery, and bounded observability.
- Tests cover the recovery rather than merely proving an exception was swallowed.
- All gates pass and ratchets move downward.

A plausible result is 180–240 guards. Again, legitimacy wins over the number.

## Phase Three — Prove the survivors and close the door

### Objective

Turn the remaining guards from historical residue into an explicit, enforceable boundary
catalogue.

### Work

- Re-audit every retained guard against the final code shape and current decompile.
- Require each survivor to fit one of four boundary classes:
  1. foreign callback or third-party API;
  2. one independent member of a partial-success batch;
  3. optional integration that can be disabled truthfully;
  4. secondary file/network sink whose failure must not undo primary authoritative work.
- Extend `check-pcall.py` based on findings from Phases One and Two:
  - recognize deterministic Lua standard-library calls;
  - flag broad guards with unrelated target families;
  - require a boundary-class reason for opaque guards;
  - keep the per-mod ratchet strictly downward.
- Update `tools/pcall-safe.json` citations and remove stale or over-broad entries.
- Run dedicated-server, client, admin UI, persistence-failure, optional-mod present/absent,
  and representative large-batch smoke tests.
- Remove temporary instrumentation once its question is answered; retain only bounded
  operational signals that remain useful.

### Exit conditions

- Every remaining `pcall` belongs to an allowed boundary class and has a reviewable reason.
- Zero guards exist only to hide errors, compensate for fixtures, or protect an engine
  event listener from sibling listeners.
- The checker rejects regression toward blanket containment.
- The full suite, deployment dry run, and smoke matrix pass.
- The final guard count is recorded as an outcome, never chosen as the definition of done.

## Verification gates

Run focused tests during each slice and all of these before closing a phase:

```text
tools\check-lua.bat
tools\check-pcall.bat
tools\check-helpers.bat
tools\run-tests.bat
python "tools\Deploy Tools\deploy-workshop.py" --dry-run
```

The deployment dry run belongs at phase boundaries, not after every source edit. It proves
the ship formatter preserved the final Lua token streams; it does not replace in-game
testing.

## Explicit non-goals

- Reaching zero `pcall`.
- Changing wire tokens, save/modData schemas, sandbox keys, mod IDs, or public behavior.
- Folding leaf features into Core because their guard cleanup revealed shared access.
- Solving helper debt, RDNet adoption, or unrelated architecture during a pcall slice.
- Preserving a guard merely because deleting it exposes a real bug. Exposed bugs are fixed
  at their actual contract; the blanket does not go back over them.
