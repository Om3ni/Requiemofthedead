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
