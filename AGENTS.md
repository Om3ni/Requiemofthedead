# Requiem of the Dead — Agent Working Agreement

This repository is a production Project Zomboid Build 42 server-mod suite, not a
disposable mod experiment. Apply the engineering discipline that would be expected in a
maintained application—clear contracts, narrow responsibilities, explicit trust
boundaries, tests, observability, and reviewable changes—while respecting the realities
of Kahlua and the Project Zomboid engine. Do not import patterns from React, Tauri, Node,
or another ecosystem merely because they are fashionable there.

Current engine evidence lives at
`C:\VSCodeProjects\RequiemoftheDead\PZ_Engine_Decompiled_42.20.2-ffe7a8a4b1`.
It is intentionally ignored by Git; inspect it with an explicit path rather than a
Git-aware file search that respects `.gitignore`.

## Read before changing code

1. Read `README.md` for bundle architecture, naming, layout, release, and versioning
   conventions.
2. Read `CLAUDE.md` for engine facts and failure modes already paid for through
   debugging. Its filename is historical; its technical rules apply to every agent.
3. Inspect the files, callers, tests, and current Git diff relevant to the task. Never
   assume the worktree is clean or that an uncommitted change is disposable.
4. For engine-facing work, read the current decompiled implementation, not merely a
   declaration or search result.

If documentation, code, tests, decompiled engine behavior, or the user's request
contradict one another, stop and surface the contradiction before editing. Do not invent
a compromise behind the user's back.

## Repository and deployment boundaries

- `C:\VSCodeProjects\RequiemoftheDead` is the authoritative development repository.
- `RequiemOfTheDead/` is the single Workshop artifact. Shipping code lives under
  `RequiemOfTheDead/Contents/mods/<mod-id>/`.
- `wip/` contains non-shipping work unless the user explicitly approves promotion into
  the Workshop artifact.
- `PZ_Engine_Decompiled_*` and `PZ_Natives_Decompiled_*` are read-only evidence. Never
  edit generated decompiles to make a claim appear true.
- `C:\Users\micha\Zomboid\Workshop\RequiemOfTheDead` is a staging snapshot, not a
  second development tree. Never edit it by hand or treat differences there as
  disposable.
- Do not run a real deployment, staging mirror, upload, cleanup, shadow restoration, or
  other environment-changing script without explicit user approval. Dry-run inspection
  is allowed when it is relevant and non-destructive.
- Never create junctions or symlinks for active mod trees. The repository's deployment
  tools use real copies because canonical-path mismatches corrupt engine mod attribution.
- Never commit or publish player data, server logs, captures, snapshots, credentials,
  Steam IDs, IP addresses, or generated forensic reports. Respect `.gitignore`, but do
  not assume it catches every sensitive filename.

## Collaboration contract

- Plan before writing. For any non-trivial change, first state the goal, affected
  responsibilities/files, invariants, engine evidence needed, and verification plan.
- After forming the plan, assess whether the current agent, model, tool, runtime, or
  workflow is the best fit for the work. Repeat that assessment if new evidence changes
  the problem. When a materially better option exists, recommend it to the user before
  implementation and explain what it improves, which part of the work it should own,
  and its relevant cost, latency, capability, or coordination tradeoffs. Do not silently
  switch models, delegate work, install tooling, or broaden access; the recommendation
  informs the user's decision rather than replacing it.
- A request to implement a clearly scoped change authorizes that scope. It does not
  authorize adjacent cleanup, architectural migration, deployment, release work, or
  unrelated fixes.
- Ask before making a decision that materially changes behavior, architecture, public
  APIs, wire/save formats, module ownership, dependencies, user-visible policy, or the
  approved scope. Present the real alternatives and tradeoffs.
- Do not ask the user to decide implementation details that have only one technically
  valid answer. Make those necessary decisions and explain them afterward.
- If the user's proposal is unsound, say so plainly and explain the failure mode. Do not
  quietly reshape a bad idea into something merely implementable and call it agreement.
- Preserve existing work. Do not revert, overwrite, reformat, rename, or "clean up"
  unrelated user changes.
- Prefer small, reviewable change sets. Do not mix behavior changes, mechanical cleanup,
  and architecture migration unless the approved plan requires them together.
- After changing code, report what changed, decisions made, evidence consulted, checks
  run, and any remaining uncertainty. Never describe a skipped or unavailable check as
  passing.

### Sole-maintainer Git workflow

- This is a sole-maintainer project designed, scoped, and built by the user. Do not
  impose contributor-oriented process on it or imply that outside authorship or review
  is expected.
- Git is primarily a personal safety, history, and decision boundary: use it to preserve
  known-good states, isolate intentional changes, and make recovery possible.
- Pull requests, reviewer-facing ceremony, and detailed commit narratives are not
  required. Do not create a branch, commit, push, or pull request unless the user asks.
- When a commit is requested, keep its message concise and descriptive. Put essential
  engine evidence, compatibility reasoning, and operational knowledge in the code or
  repository documentation where future work can find it, rather than relying on an
  elaborate commit message.

## Architecture and ownership

### Files and responsibilities

- A file should own one cohesive responsibility and have one principal reason to
  change. A principal module, component, adapter, registry, dispatcher, or operation is a
  valid unit.
- Split a file when it contains independent behaviors, unrelated lifecycle ownership,
  multiple public responsibilities, or sections that could change for different reasons.
- Small private helpers may remain beside the responsibility they support. Do not turn
  every local function into a file; fragmentation and load-order coupling are also design
  costs.
- Avoid broad "utils" files. Name an abstraction for the domain concept or boundary it
  owns.

### Naming and project voice

- Names should have enough character to belong to this project. Before introducing a
  feature, module, file prefix, public surface, or meaningful function, challenge a name
  that merely restates the mechanism (`QuietHorn`, `VehicleHelper`, `handleData`). If it
  feels painfully on-the-nose, propose a memorable domain name that still tells the truth
  about its responsibility; `NoiseOrdinance` is the model.
- Personality is welcome in private function names too—even gallows humor—when the name
  remains understandable in context and its contract is documented where needed. Soul is
  not permission for ambiguity: a reader should not have to execute a function to learn
  what kind of responsibility it owns.
- Do not force a joke where precise vocabulary is stronger, and do not casually rebrand
  frozen mod IDs, wire/save keys, sandbox options, exact engine callbacks, external API
  names, or established public contracts. Those remain compatibility decisions under the
  collaboration rules above.
- Naming discussion happens during planning. Do not finish a feature under a placeholder
  name and silently leave the rebrand for later, and do not rename unrelated established
  code while implementing a scoped change.

### Helpers and reuse

- Do not duplicate helper implementations. Before adding one, search the repository for
  the same behavior, not just the same name.
- Promote an abstraction when a real second consumer exists or when multiple call sites
  share one semantic contract. Do not create speculative shared infrastructure for a
  hypothetical future consumer.
- Shared by multiple mod IDs: place the abstraction in the appropriate RFTDCore surface.
  Shared only within one mod: keep it in that mod. A file move into Core is an ownership
  decision, not merely deduplication.
- Keep call-site policy at the call site. A helper should centralize mechanism or a stable
  rule; it should not erase meaningful differences between consumers.
- Run the helper debt ratchet after Lua changes. Existing baseline debt is not permission
  to add more.

### RFTDCore as platform middleware

Core may act as the suite's platform/middleware layer for concerns that must be
consistent across modules: identity, clocks, lifecycle, command dispatch, access control,
rate limiting, logging, observability, shared UI contracts, and verified compatibility
patches.

That role has limits:

- Two or more genuine consumers, or an unavoidable suite-wide engine boundary, justify
  Core ownership. A single leaf feature normally does not.
- Core exposes explicit, narrow APIs and registration contracts. Satellites should not
  reach into Core internals or depend on incidental globals.
- Middleware must be default-deny where it guards a trust boundary, observable when it
  rejects or fails, and cheap when disabled.
- Core must not become a catch-all merely because every module can reach it. Code placed
  there cannot be disabled independently.
- Admin surfaces belong in Dragonfly. Other modules may integrate with Dragonfly but must
  not make Core or gameplay behavior depend on Dragonfly being enabled.
- Avoid cyclic ownership: lower-level platform code must not depend back on satellite
  behavior.

### Networking and authority

- Treat every client command and payload as untrusted. Authorization, capability checks,
  rate limits, identifiers, ranges, object existence, and state transitions are enforced
  server-side.
- New family client-to-server commands use `RDNet` unless the user approves a different
  boundary. Do not add another family-wide dispatcher.
- Adoption is per wire token/subsystem: register the complete approved command surface,
  then remove the old server `OnClientCommand` dispatcher for that token. Do not leave two
  executable paths accepting the same command.
- An RDNet capability gate is not a substitute for domain validation inside the handler.
- Preserve atomic bundle assumptions only where they are established. Never assume a
  remote client, persisted save, or third-party caller is well-formed merely because
  suite modules ship together.
- Wire-token, save-schema, event-name, sandbox-option, and mod-ID changes are compatibility
  decisions and require explicit approval.

## Engine evidence and Lua constraints

- Never guess an engine API. Verify the exact call against the most current decompiled
  engine present in this repository. Read the method body and relevant callers/guards;
  a symbol hit or signature alone is insufficient.
- Verify vanilla Lua APIs against the current vanilla Lua source. Java decompilation
  cannot prove a Lua wrapper or global exists. If the needed source is unavailable, say
  that the call is unverified and stop before basing a change on it.
- Record non-obvious engine evidence close to the code as `Class.java:line` (and method
  when useful). Comments explain the relevant guarantee or failure mode, not merely that
  verification occurred.
- Treat Kahlua as its own runtime with a Lua 5.1-shaped subset. A passing Lua 5.1 test does
  not prove an engine global, Java collection behavior, load order, or Kahlua-only limit.
- Respect asymmetric loading: the dedicated server honors dependency order, while client
  Lua tiers load alphabetically across mods. Require cross-mod globals explicitly when a
  file-scope use could precede their defining file, and gate on execution context rather
  than the accidental existence of a global.
- Keep existing hard engine rules intact, including allowed writer extensions, unique
  namespaced trait IDs, and frozen mod IDs. See `CLAUDE.md` for the current evidence.

## Error boundaries and `pcall`

- Direct calls are the default. Do not use `pcall` around operations that cannot throw,
  around field reads as superstition, or to hide errors that should fail loudly in
  development.
- Every new `pcall` must have a concrete, documented failure mode. Verify engine-call
  claims in the decompile.
- A guard earns its place through useful granularity or a genuine foreign-code boundary:
  for example, allowing one external handler or malformed record to fail without losing
  an independent batch. Engine event containment and silence are not sufficient reasons;
  the engine already protects listener boundaries and logs before Lua catches the error.
- Keep the guarded region as small as possible. Never wrap an entire lifecycle handler
  when only one independent operation is expected to fail.
- Do not add a method to `tools/pcall-safe.json` without reading its current Java body and
  recording the evidence required by that file.
- Baselines are ratchets, not targets. Never raise a `pcall` baseline to make a check green
  without an approved, documented reason for every newly accepted guard.

### Choosing `pcall` or another design

`pcall` is a failure-isolation tool, not a way to write "I am unsure" in Lua. Use this
decision order before adding or preserving one:

1. Name the exact operation that can fail and read the current implementation. If no
   concrete throw path exists on a valid receiver, call it directly.
2. Ask whether the failure is actually an unmet precondition. A nullable script, unloaded
   square, absent inventory, malformed payload, wrong execution side, or premature load
   order should be handled by a guard, validation, context gate, or corrected `require`—not
   by catching the resulting programming error.
3. Ask whether the operation can be made deterministic. Normalize input, resolve the
   authoritative object, split unrelated work, or move the call to the lifecycle point
   where its contract is valid before considering an exception boundary.
4. Use `pcall` only when the failure remains legitimate after those steps and the caller
   has useful recovery: skip one independent record while continuing a batch, contain a
   third-party callback, preserve the authoritative mutation when a secondary audit sink
   fails, or degrade an optional integration. File and network I/O qualify only when their
   failure is recoverable at that call site.
5. Guard the smallest failing operation. Check the returned status, execute an explicit
   fallback or bounded diagnostic, and keep independent work outside the protected region.
   If the only response is to discard the error and continue in a partially updated state,
   the boundary is probably wrong.

Do not use `pcall` to supply defaults for required engine data, probe whether a verified
method exists, compensate for an inaccurate test double, protect one engine event listener
from another, or suppress logs. Tests model valid engine contracts and add explicit fault
injection only for failure modes production can genuinely encounter. An impossible mock
exception is not evidence for a production guard.

## Experimental and invisible behavior

- Every experimental behavior that is otherwise invisible must include a proportionate
  way to observe it: a bounded log, metric, debug panel, overlay, self-test, trace, or
  deterministic reproduction path.
- Observability must answer whether the feature ran, what decision it made, and why it
  refused or failed. A bare "entered function" message is not enough.
- Invasive probes and global wrappers default off and must be cheap when disabled. Logs
  and forensic streams must be bounded and must not expose sensitive player data beyond
  their deliberate operational purpose.
- State how temporary instrumentation will be removed or disabled after the experiment.
  Do not leave an unbounded debug path in a release artifact.

## Verification gates

For Lua changes, run the narrowest relevant tests during iteration and the repository
gates before calling the work complete:

```text
tools\check-lua.bat
tools\check-pcall.bat
tools\check-helpers.bat
tools\run-tests.bat
```

- `check-lua` proves syntax only.
- The `pcall` and helper checks enforce ratchets; being at or below baseline does not mean
  the remaining debt is good code.
- The Lua harness covers only what its stubs and engine-free modules model. A green run is
  not an in-game proof.
- If a required executable or Python is unavailable, use an explicitly located compatible
  runtime when safe, or report the gate as not run. Do not edit baselines as a workaround.
- For an engine event, load order, networking, UI, save, per-tick, or dedicated-server
  change, define and perform the relevant Mosaic/runtime smoke test when the environment
  is available. Obtain approval before deploying copies or restarting processes.
- When a check fails outside the approved scope, report the exact failure and determine
  whether the implementation, test fixture, or pre-existing work is responsible. Do not
  repair unrelated failures without approval, and do not dismiss them as "probably
  pre-existing" without evidence.

## Release discipline

- The Workshop item is the release unit; suite versions move in lockstep. Do not bump a
  version for an ordinary code edit or commit. Versioning is an explicit release step.
- Maintain a community-facing changelog for releases. Write for server owners, admins,
  and players—not programmers or reviewers. Lead with what changed in play, what was
  fixed, and whether anyone must change a sandbox option, server setting, load order, or
  operating practice. Translate implementation details into their observable effect;
  omit file names, function names, architectural jargon, refactor mechanics, and test
  minutiae unless they directly affect users. Preserve the project's voice without
  obscuring instructions or compatibility warnings.
- Internal engineering notes are not a substitute for the community changelog, and the
  changelog is not the place to preserve technical evidence. Keep engine findings,
  invariants, migration reasoning, and maintenance details in code or repository
  documentation.
- Keep the two `mod.info` copies for each mod byte-identical.
- Never rename an existing mod ID. Preserve established wire tokens and intentional
  human-facing spellings.
- Before a requested upload, reconcile version declarations, run all gates, inspect a
  staging dry run, and describe exactly what the mirror will add, replace, or delete.
- Only stage through the repository's staging tool. The real staging mirror uses
  destructive synchronization within its owned target and therefore always requires
  explicit approval.

## Code review priorities

Review findings before style. Prioritize:

1. Data loss, save/wire incompatibility, authority bypass, and staging/deployment risk.
2. Incorrect engine assumptions, client/server or load-order mistakes, and lifecycle
   leaks.
3. Hidden failures, over-broad `pcall`, unbounded hot-path work, and missing visibility.
4. Broken ownership boundaries, duplicated semantics, and accidental Core growth.
5. Missing tests, misleading comments, and documentation drift.

Do not spend review attention on cosmetic preferences unless they obstruct correctness or
maintenance. A review that finds no actionable problem should say so plainly and name the
remaining test or runtime uncertainty.
