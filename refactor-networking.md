# The Conductor

## Network consolidation plan for the Requiem family

Status: deferred until the `pcall` refactor in `REFACTOR.md` is complete
Plan date: 2026-08-16
Engine evidence: `PZ_Engine_Decompiled_42.20.2-ffe7a8a4b1` and the matching vanilla Lua
Scope: suite-owned client commands, server commands, command payloads, and intentional
global ModData traffic

## Why this exists

Requiem ships as one Workshop item and enables a family of mod ids. That gives every
family member the same code version, but it does not automatically give them one trust
model or one transport policy. Without a common boundary, twelve shipping mods today—and
potentially fourteen to twenty later—can each invent their own answers to:

- who may ask the server to do something;
- which parts of a client payload may be believed;
- how often a command may run;
- how large one payload may become;
- who should receive the reply;
- how snapshots are paged, cancelled, timed out, and reassembled;
- what one broadcast actually costs after connection fan-out;
- how a refusal, malformed request, dropped page, or handler fault becomes visible.

The intent behind `RDNet` remains correct: the monomod family should have one
authoritative networking surface that is safer and more network-friendly than a pile of
independent mods slinging packets without shared limits or measurement.

The correction is not to turn Core into the owner of every feature. Core owns the wire
rules. Satellite handlers continue to own gameplay decisions, validation, state changes,
and recovery. `RDNet` is the conductor, not every instrument.

This plan starts only after the user declares the `pcall` work complete. Do not smuggle a
networking, authority, wire-shape, or ownership change into a `pcall` slice. A security
issue may move ahead of this plan only when the user explicitly reprioritizes it.

`AGENTS.md`, `CLAUDE.md`, and `README.md` remain authoritative when this document drifts.

## The honest scope of the boundary

`RDNet` can govern suite-owned `sendClientCommand` / `sendServerCommand` traffic whose
wire token has completely adopted it. It cannot become middleware in front of every Lua
listener in the game:

- `GameServer.receiveClientCommand` fires `OnClientCommand` for every registered listener
  and ignores listener return values (`GameServer.java:2107-2138`). One listener cannot
  veto another.
- Vanilla and third-party commands stay outside RDNet unless their owners deliberately
  integrate. `RDGuardian` may observe them; observation does not create authority.
- Typed `INetworkPacket` families do not fire `OnClientCommand`. Server-side Lua cannot
  route or meter them through RDNet.
- `GlobalModData.transmit` is its own all-connections channel
  (`GlobalModData.java:111-136`). It must be measured and challenged separately.
- The broadcast overload of `sendServerCommand` walks every connection
  (`GameServer.java:3209-3213`). Hiding a message in a client UI after broadcasting it is
  not recipient security.
- One serialized string is prefixed by a signed short
  (`ByteBufferReader.java:51-55`). Connection-buffer size is not permission to send an
  arbitrarily large string.

The success claim is therefore precise: one authoritative boundary for family-owned
command traffic, one bounded measurement system for the wire Lua can see, and explicit
documentation for what remains outside both.

## Roles inside Core

These responsibilities cooperate but must not blur together:

| Surface | Responsibility | It must not become |
|---|---|---|
| `RDNet` | Registration, default-deny dispatch, command policy, recipient-aware sends | Domain validation or a second gameplay service layer |
| `RDAccess` | Shared capability and tier decisions | A substitute for handler-specific ownership and state checks |
| `RDRate` | Per-command fairness and optional aggregate flood ceilings | One shared bucket that lets unrelated commands starve each other |
| `RDWire` | Payload estimation, limits, and declared chunk contracts | A serializer or permission system |
| `RDChunk` | Reusable bounded paging where a real second consumer justifies it | Mandatory ceremony for small messages |
| `RDMeter` | Measured cost, fan-out, oversized traffic, and top talkers | Authority, blocking policy, or an always-on invasive wrapper without evidence |
| `RDGuardian` | Bounded forensic observation of inbound client commands | A gate, verdict engine, or duplicate dispatcher |

RDNet is the enforcement plane. RDMeter is the measurement plane. Policy must remain
correct when detailed telemetry is disabled, and telemetry must never claim it blocked a
command.

## Starting baseline

Measured from the shipping tree on 2026-08-16:

| Signal | Current state |
|---|---:|
| Server `OnClientCommand` listener registrations | 13 |
| Client `OnServerCommand` listener registrations | 31 |
| All command-event listener registrations | 44 |
| Executable client-to-server listeners, including RDNet | 10 |
| Observe-only client-to-server listeners | 3 |
| RDNet-adopted family tokens | 3 |

The adopted tokens are `RFTDCore`, `RFTDOddsAndEnds`, and `RFTDLimes`. Adoption quality is
not equal:

- Odds and Ends and Limes route their family-token commands through RDNet and have no
  private server dispatcher for those tokens.
- Core adopts `RFTDCore`, but `RDTripwire` still handles `tripwireReport` and
  `lifecycleReport` in a second executable listener. RDNet records them as unregistered
  while the other listener executes them. The token is therefore only partly adopted.
- `RDGuardian`, `RCDamageAudit`, and `RCJanitor` have legitimate observe-only listeners.
  The latter two watch vanilla's `vehicle` token, not a family token. Their existence is
  not a violation, but the static rules must be able to distinguish observation from
  execution.

Listener count alone is not the goal. A cheap observer and an executable dispatcher are
not equivalent. The target is unambiguous ownership, bounded cost, and a truthful trust
boundary.

Before Phase One changes code, run RDMeter during an approved representative Mosaic
session and record a private baseline. Never commit the resulting player-bearing logs.
Capture at least:

- calls and estimated bytes by `module:command` in both directions;
- actual broadcast fan-out;
- global ModData bytes after fan-out;
- oversized and partial estimates;
- join/rejoin bursts;
- ordinary player actions, Dragonfly admin work, a Dirge horde, Limes baseline/import,
  Reaper snapshots, and Reclaimation fleet/lifecycle use.

The baseline is evidence, not a quota. A lower byte count does not excuse a weaker
authority boundary, and a secure command is not allowed to become unbounded.

## Non-negotiable invariants

### One token, one executable intake

- A family wire token is its established mod id unless the user explicitly approves a
  compatibility change.
- An adopted token has exactly one executable server intake: RDNet.
- Observe-only listeners may inspect a command but may not mutate family state, answer it,
  or claim to reject it.
- Adoption is atomic per token. Register the complete approved command surface, then
  remove the legacy dispatcher in the same slice. Never leave two executable routes.
- Duplicate token/command registration is a loud configuration error. Load order must
  never silently choose the winner.
- Unregistered commands are default-deny and observable through a bounded rejection path.

### The client sends intent, not truth

- Treat module, command, args, identifiers, coordinates, counts, text, revisions, and
  chunk markers as untrusted wire data.
- The server resolves authoritative objects and derives ownership, distance, current
  state, resource cost, and transition eligibility.
- A client report may create clearly labelled telemetry. It may not mint resources,
  remove registry entries, grant ownership, authorize a destructive action, or create an
  authoritative ledger fact.
- Capability checks answer who may attempt an operation. Domain validation still answers
  whether this player may perform this operation on this object in this state.
- A UI gate is presentation only. The matching server handler always enforces authority.

### Fairness and flood protection are separate

- Every command declares a command-scoped rate appropriate to its cost and legitimate
  cadence.
- Low-rate commands cannot be starved by unrelated family traffic.
- If an aggregate per-player flood ceiling is retained, it is a distinct, higher layer
  with distinct diagnostics. One bucket does not pretend to provide both policies.
- Rejection behavior is explicit. Interactive commands receive a bounded refusal when
  that prevents a permanently waiting UI; fire-and-forget telemetry may be silently
  dropped when replying would amplify abuse.
- Expensive work is independently bounded after intake: list size, scan radius, rows,
  objects per tick, queued jobs, and concurrent assemblies all have server-owned limits.

### Audience is part of the contract

- Request/response traffic defaults to the requesting player.
- Staff information is sent only to server-verified staff recipients. A hidden panel on a
  non-staff client is not confidentiality.
- Broadcast is reserved for state every connected client genuinely needs.
- Relevant-area delivery is preferred when world state matters only to nearby clients and
  the verified engine surface supports it.
- Every fan-out API makes its audience visible at the call site or registration contract.
  A generic `broadcast` helper must not conceal whether the audience is all, staff, or
  spatially relevant.

### The payload has a budget before it has traffic

- Small commands have a declared maximum shape even when they normally contain three
  fields.
- Variable lists and strings are bounded before loops, allocation, persistence, or sends.
- A payload that can exceed its safe budget is paged by estimated bytes, not row count.
- Paged streams carry identity, sequence, total, timeout, and supersession/cancellation
  behavior. Clients expose stalled or partial streams instead of presenting incomplete
  data as authoritative.
- Full baselines and deltas are distinct contracts. A gap detector must not cause naive
  chunks sharing one revision to be silently discarded.
- Global ModData is used only when every connection needs the whole durable blob. A joiner
  request must not casually rebroadcast a full table to the entire server.

### Measurement is singular and bounded

- RDMeter is the canonical cost vocabulary. Satellites do not invent parallel byte
  estimators, top-talker tables, or oversized thresholds.
- Adopted RDNet traffic exposes enough metadata for RDMeter to classify command, audience,
  estimated bytes, chunk contract, accepted/rejected status, and actual fan-out without
  double-counting.
- Detailed global wrapping remains opt-in until a Mosaic profile proves it cheap enough.
  RDNet policy enforcement cannot depend on that option being armed.
- The optional global probe remains useful for vanilla, third-party, legacy, and ModData
  traffic that does not pass through RDNet.
- Logs, rings, assemblies, and counters are bounded. A rejected flood must not become an
  unbounded log or staff-broadcast flood.

## The migration contract for one token

Every token migrates through the same reviewable slice:

1. Inventory every client-to-server command, server-to-client command, broadcast,
   relevant-area send, global ModData transmit, and client receiver for the token.
2. Classify each message as intent, query, reply, notification, baseline, delta, page, or
   telemetry. If one command mixes classes, split the contract before migration.
3. For each inbound command, record:
   - legitimate sender and exact capability/tier;
   - payload shape and bounds;
   - authoritative object resolution;
   - domain preconditions and state transition;
   - per-command rate and post-intake work budget;
   - reply/rejection behavior;
   - failure boundary and observable result.
4. For each outbound command, record audience, maximum estimated bytes, fan-out, chunking,
   and client timeout/partial behavior.
5. Read the current decompile and vanilla Lua for every engine-network assumption. Cite
   the relevant body, not only a signature.
6. Add focused tests for registration, capability refusal, malformed input, rate scope,
   domain denial, recipient selection, chunk boundaries, and handler failure.
7. Register the complete surface with RDNet and route its sends through the approved Core
   surface.
8. Remove the old executable listener and direct family-token sends. Observe-only vanilla
   listeners stay only when their non-authoritative purpose is explicit.
9. Run all repository gates and the token's Mosaic smoke test before recording adoption.

Append one row to the ledger when the token is complete. Do not count a token as adopted
because one command moved.

| Date | Phase | Token | Commands | Authority changes | Wire changes | Measurement | Verification |
|---|---|---|---:|---|---|---|---|
| 2026-08-16 | Baseline | Whole shipping tree | pending inventory | plan only | 13 C2S / 31 S2C listeners | pre-change capture pending | documentation review |

## Phase One — Make the switchboard honest

### Objective

Make Core's claimed networking guarantees enforceable before migrating another legacy
token. This phase changes infrastructure and the Core token only.

### Work

- Move `tripwireReport` and `lifecycleReport` into RDNet registration and remove
  RDTripwire's executable `OnClientCommand` listener. Guardian remains observe-only.
- Reject duplicate registrations loudly and expose the adopted token/command registry for
  tests and bounded diagnostics.
- Define a static `check-network` gate that, at minimum:
  - inventories command listeners and direct family-token sends;
  - rejects a private executable dispatcher for an adopted token;
  - rejects duplicate registrations detectable in source;
  - flags broadcast sends of staff/admin channels;
  - maintains a downward-only legacy baseline while migrations are incomplete.
- Give every existing RDNet command an explicit rate and rejection policy. Preserve
  handler-level domain validation.
- Separate per-command rate buckets from any aggregate flood ceiling. Migrate Dragonfly
  and Reclaimation off the shared bare-username bucket only in their token slices; Phase
  One establishes the Core contract and tests.
- Add recipient-aware sending. The design must distinguish requester, one named player,
  verified staff, every client, and—only when engine evidence supports it—spatially
  relevant clients.
- Decide the client-receive shape before implementation:
  - recommended: one RDNet client listener with registered `module:command` consumers,
    giving family server-to-client traffic the same ownership and measurement choke point;
  - acceptable fallback: retain cheap filtered client listeners, but require every
    family send to pass through RDNet and the audience/measurement contract.
- Decide how adopted traffic reaches RDMeter without double-counting when the optional
  global wrapper is also armed. Test the armed and disarmed paths.
- Add focused Core tests for unknown command, duplicate registration, capability denial,
  command-scoped rate isolation, aggregate flood behavior, nil/malformed args, handler
  fault containment, staff-only fan-out, broadcast fan-out, and meter classification.

### Exit conditions

- Core's adopted token has one executable intake and no false "rejected but executed"
  path.
- Duplicate registration cannot silently replace a handler.
- Command-scoped and aggregate limits are separate and tested.
- Recipient scope is explicit and staff-only traffic never goes to ordinary clients.
- RDNet and RDMeter have one tested accounting relationship with no double-counting.
- The network gate is green and has a documented allowlist for legitimate observers.
- All repository gates and the Core Mosaic command self-test pass.

## Phase Two — Move authority before moving packets

### Objective

Repair the trust contract of each satellite, then adopt its whole token. Migration is not
a mechanical replacement of `sendClientCommand` with `RDNet.send`; an unsafe handler
behind RDNet is still unsafe.

### Recommended order

1. **Odds and Ends and Limes — prove the reference adopters.** Audit their complete
   registered surfaces against the hardened Core contract, fill missing declarations, and
   use their small event traffic and complex chunked traffic as the two reference shapes.
2. **Husbandry — small authority pilot.** Fold `HBCommands` and `HBSexCheck_Server` into
   one registered token. Server-verify animal eligibility/proximity and bedding resource
   consumption before mutating animal, player, or hutch state. Remove unconditional
   per-command console noise from the normal path.
3. **Reclaimation — highest-value domain correction.** Replace outcome reports that mutate
   state with server-owned intent handling. In particular:
   - derive dismantle facts before removal instead of trusting `owner`, `claimId`,
     `wreck`, or vehicle type after the object is gone;
   - verify the reporting player is actually using the resolved vehicle before Janitor
     attribution;
   - move claim, fleet, tuning, purge, spawn, and destructive actions onto explicit
     capabilities/tier policy rather than the broad `isAdmin` role-name bucket;
   - keep `RCDamageAudit` and `RCJanitor` as clearly observe-only vanilla-channel sensors;
   - document the vanilla `vehicle.remove` hole separately. RDNet cannot veto vanilla's
     listener, so a correct family dismantle path does not pretend to close the engine
     exposure.
4. **Dragonfly, Staffing Tools, and Reaper — staff plane.** Preserve Dragonfly's strong
   named per-handler capabilities, replace all-client audit broadcasts with verified-staff
   delivery, scope rates per command, and decide whether `Dragonfly_RoleEdit` changes to
   the established `RFTDStaffTools` wire token. That token change requires explicit user
   approval even though the Workshop bundle ships atomically. Reaper's cull, snapshot,
   scan, and threshold commands receive action-specific authority and queue limits.
5. **Dirge — high-volume gameplay plane.** Inventory every command branch in the large
   dispatcher, bound malformed and repeated death reports, give expensive scans explicit
   rates/work ceilings, preserve server-confirmed zombie state, and keep baseline/delta
   revision semantics intact. Measure horde traffic before changing page or cadence
   policy.
6. **Memoir — persistence-critical plane.** Migrate last among ordinary satellites so the
   established patterns are proven before touching snapshot/restore authority. Required
   persistence failures remain truthful failures; transport containment must not turn a
   partial restore into success.
7. **Remaining send-only or low-traffic modules.** Ban Box notices, season notices, and
   other small server-to-client surfaces adopt the recipient and measurement contract
   even when they have no inbound command dispatcher.

This order is a recommendation, not permission to alter public behavior. Each token plan
must surface capability-policy, wire-token, save/wire-shape, or gameplay changes before
implementation.

### Exit conditions

- Every migrated token has one executable server intake and a complete command registry.
- No client-reported fact directly creates authoritative resources, ownership, deletion,
  registry mutation, or ledger truth.
- Every destructive or private action has an explicit server-side capability/tier plus
  domain validation.
- Every request has bounded input and work, and interactive requests terminate visibly on
  success, refusal, timeout, or partial failure.
- Staff-only data is never sent to ordinary clients.
- Each token's focused tests, repository gates, and Mosaic smoke test pass before the next
  migration begins.

## Phase Three — Close the side roads and prove the wire

### Objective

Finish family adoption, remove transitional paths, and demonstrate that the consolidated
suite is both safer and cheaper under representative load.

### Work

- Migrate any remaining family-owned command token and remove obsolete direct dispatchers,
  direct sends, duplicated rate limiters, parallel estimators, and transitional dual paths.
- Audit all 31 starting client `OnServerCommand` listeners. Consolidate them if Phase One
  selected a client registry; otherwise prove each remaining listener is a cheap,
  correctly filtered consumer with no duplicate execution path.
- Audit every family broadcast. Convert requester responses to unicast, staff feeds to
  verified-staff delivery, world-local state to relevant-area delivery where supported,
  and retain all-client broadcast only with a documented audience reason.
- Audit every global ModData transmit. Replace join-triggered global re-broadcasts with
  targeted command baselines where practical; coalesce the unavoidable broadcasts.
- Require byte-budget declarations for every variable snapshot, delta, import, inventory,
  fleet, zombie, or registry payload. Exercise maximum legal payloads in tests.
- Run the same approved RDMeter scenarios used for the baseline. Compare calls, estimated
  bytes, fan-out, oversized records, join bursts, and top talkers. Explain regressions;
  do not hide them by changing thresholds.
- Run malformed-client and low-privilege-client probes against every adopted token. Prove
  that rejection creates no mutation and no unbounded response/log amplification.
- Update `README.md` with the measured adoption state and current listener counts. Remove
  migration commentary from code once the final ownership is obvious from structure.
- Produce a community-facing changelog describing observable reliability, admin-policy,
  or configuration changes without exposing implementation jargon or exploit recipes.

### Exit conditions

- Every family-owned client-to-server command uses RDNet and exactly one executable
  dispatcher.
- Every family-owned server-to-client send uses the approved recipient and measurement
  surface.
- No adopted token has a legacy executable listener or direct family-token bypass.
- No staff-only payload reaches ordinary clients.
- No variable payload is unbounded or relies on row count as a byte budget.
- No global ModData transmit exists merely to answer one joining or requesting player.
- RDMeter shows the final wire cost under the same scenarios as the baseline, with no
  unexplained oversized or high-rate family traffic.
- Static gates, full tests, deployment dry run, and the complete Mosaic networking smoke
  matrix pass.

## Verification matrix

Run focused tests during each token slice and all repository gates before closing a phase:

```text
tools\check-lua.bat
tools\check-pcall.bat
tools\check-helpers.bat
tools\check-network.bat
tools\run-tests.bat
python "tools\Deploy Tools\deploy-workshop.py" --dry-run
```

`check-network` is planned work and does not exist at this baseline. Do not describe it as
passing until Phase One adds it.

The Mosaic/runtime matrix must include:

- ordinary player, each relevant staff tier, and top admin;
- valid, unknown, malformed, over-rate, and out-of-domain requests;
- request disconnect and target disconnect during queued work;
- two unrelated commands in the same second to prove rate isolation;
- staff-only, requester-only, all-client, and relevant-area delivery;
- missing, reordered, duplicated, superseded, and timed-out pages;
- fresh join, several near-simultaneous joins, and reconnect;
- representative horde, fleet, inventory, zone import, snapshot, and persistence loads;
- RDMeter armed and disarmed, with proof that policy is identical and accounting does not
  double-count.

None of the batch files proves a live RakNet path, event load order, connection fan-out,
or client reconstruction. Runtime evidence is mandatory for a networking phase.

## Decisions that remain with the user

The plan recommends a direction but does not silently decide these compatibility and
policy questions:

1. Whether RDNet gains one client-side server-command dispatcher or retains many cheap
   filtered consumers behind one outbound send/measurement surface.
2. Whether an aggregate per-player flood ceiling exists above per-command limits, and what
   operational response follows when it trips.
3. Which exact capabilities or sandbox tiers own Reclaimation, Reaper, Husbandry debug,
   and other powerful actions currently gated as broad "staff".
4. Whether `Dragonfly_RoleEdit` changes to the `RFTDStaffTools` mod-id token.
5. Whether the vanilla `vehicle.remove` exposure receives a separate engine-level
   mitigation, detection/repair strategy, or documented acceptance.
6. Whether detailed family traffic measurement becomes default-on after profiling proves
   its hot-path cost, while the invasive global probe remains opt-in.

These decisions are made before the affected phase touches code. Do not bury them inside
an apparently mechanical migration.

## Explicit non-goals

- Replacing Project Zomboid's network stack or claiming control over typed engine packets.
- Blocking, rewriting, or policing third-party namespaces through an observer callback.
- Moving satellite domain logic into Core.
- Changing established wire tokens, save schemas, mod ids, or sandbox policy without
  approval.
- Broadcasting private information because every client happens to ship the receiving
  code.
- Chasing zero listeners or zero packets. Necessary traffic with a clear owner and budget
  is healthy traffic.
- Treating a lower byte count as proof of correct authority.
- Combining this work with the active `pcall` refactor.
