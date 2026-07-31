# Requiem of the Dead

Monorepo for the Requiem of the Dead Project Zomboid (Build 42) server mod suite.

**One Workshop item, many mods.** [RequiemOfTheDead/](RequiemOfTheDead/) is the single
release artifact: every RFTD mod id ships inside it and updates atomically, so version
skew between family members is structurally impossible. Servers subscribe to one item
and enable the mod ids they want via `Mods=`.

**RFTDCore is the harness the rest of the family depends on.** Ten of the eleven other mods
declare `require=RFTDCore` and the dependency is hard (BBLibrary is the exception - it
depends on `RFTDBanBox`). What Core *contains* and what the satellites have *migrated
onto* are different lists, and the gap is deliberate: each satellite adopts at its own
migration turn.

- **Adopted family-wide.** `RDShared` (identity, version, clocks) and `RDEvents` (the
  closed chronicle event enum), required by name from every satellite - plus season
  bookkeeping, `RDLife` life-cycle instrumentation, and `RDGuardian`'s forensic record of
  every client command, which hook engine events directly and so never waited on adoption.
- **Opt-in.** `RDMeter` is the network-traffic probe absorbed from OmenSpyNetwork:
  server→client sends, global ModData broadcasts weighted by connection count, and the
  client→server sizes folded into Guardian's own records via `RDWire`. Guardian says what
  arrived; this says what it cost, including the ModData fan-out nothing else can see.
  **Default off** - arming it wraps engine send functions every mod on the server calls,
  so it is a `RFTDCore.WireProbeEnabled` decision, not a standing posture.
- **Partly adopted.** Two-tier server logging (permanent per-player *chronicle* streams +
  a bounded *forensic* ring) works, but only Reclamation and a single Dirge event write to
  it, and Reclamation's writes are transitional dual-writes kept alongside the legacy path
  until a season has proven the new one. `RDRate` backs Reclamation's dispatcher and
  RDNet's.
- **Adopted by one satellite.** `RDNet` - one dispatcher per wire token, default-deny
  registration, capability gates - carries Core's self-test and Odds & Ends' three Reliquary
  commands. Odds & Ends is the first satellite to put its whole wire through it and register
  no `OnClientCommand` listener of its own, which is the only adoption that counts.
  Twenty-eight `Events.On*Command.Add` listeners still live outside Core, ten of them
  server-side dispatchers, and that second number has not moved. `RDNet.lua`'s header is the
  authority on this, not the paragraph above it.

Core also carries two things that are not harness and change at their own pace: the
`DFRegistry`/`DFLog`/`DFFeedback` client UI framework, and the compat/anti-grief patch
layer - fourteen patch files, nearly half of Core's file count and a third of its lines.

## Mods in the bundle

| Mod id | What it is | Version |
|---|---|---|
| `RFTDCore` | The harness (required by everything) | 0.1.0 |
| `Dragonfly` | Admin command center: tabbed panel, item editor, Longstrider map/tours, debug gate | 0.8.0 |
| `RFTDStaffTools` | Extended ESC scoreboard + unlocked role editor + role persistence | 0.7.0 |
| `RFTDMemoir` | Craftable character snapshot/restore journal | 0.7.0 |
| `RFTDBanBox` | Item ban engine (loot-strip + login confiscation) | 0.7.0 |
| `BBLibrary` | RotD default ban list for RFTDBanBox (opt-in) | 0.1.0 |
| `RFTDReclamation` | Reclaimation - vehicle lifecycle: claims, permissions, fleet panel, dismantling, the Janitor | 0.7.0 |
| `RFTDDirge` | Special zombie variants: Screamers, Juggernauts, EMP, Gluttons, Scavengers, Bosses | 1.1.0 |
| `RFTDHusbandry` | Animal taming, breeding, and management | 0.2.0 |
| `RFTDLastRites` | Client QoL HUD: life-threat indicators (cold, heat, bleeding) | 0.2.0 |
| `RFTDOddsAndEnds` | Catch-all for small self-contained modules: Reliquary handover stash, RIPIT bulk rip, Sticky Headwear, Lumberjack forestry (wood weight, tree sweep), timed-action speed scaling | 0.2.0 |
| `RFTDReaper` | Twin-spawn bloom detector/culler - **pending the 42.20 verdict**; may retire with the Necro tab folding into Dirge | 1.2.0 |

**The migration is complete.** `C:\VSCodeProjects\PZMod` (repo `Om3ni/PZMods`) is the
frozen archive: history, tooling, the engine decompile, retired test forks, and what stays
behind (OmenSpyNetwork - standalone and frozen with its own users; Cookbook and Sector7).
Odds & Ends came over as a mod id carrying one module: **Chandler**, its SoapZ-derived soap
and candle crafting, is still in the archive and migrates on its own turn, since it brings
~3.5k lines, 30 textures, and a third-party attribution obligation with it. Legacy per-mod
Workshop items freeze as superseded-by pointers per `docs/legacy-items/DEPRECATION.md`
(October 1 sunset).

## Naming

Display names are "Requiem of the Dead: X" - Season One (RFTDCore; the harness wears
the season's name and rolls to Season Two at the next wipe, id never changes), Memoirs,
Ban Box, Staffing Tools, Dragonfly, Dirge, Reclaimation, Odds and Ends, and at their turns
Husbandry and Last Rites. Display names are free text; mod ids are frozen.

## Conventions

- Layout: `RequiemOfTheDead/Contents/mods/<modid>/mod.info` + `<modid>/42/media/...`;
  the two mod.info copies per mod stay byte-identical; one `workshop.txt`/`preview.png`
  at the bundle root.
- Wire tokens = mod ids. Intra-bundle token changes need no dual-accept (client+server
  ship atomically); the only live transition is Dirge accepting legacy `"RQ"` until
  Husbandry's migration turn ends it.
- Access tiers are sandbox policy, strict by default: `RFTDDirge.ConvertAccess`,
  `RFTDDragonfly.PanelAccess`, `RFTDDragonfly.DebugGateAccess` (1 = Admin only,
  2 = all staff).
- A feature that needs sandbox dials picks its home by what the feature *is*, and pays for
  its own sandbox page - never inherit a namespace because one already exists. Sandbox
  namespaces are a gravity well: the binding that attracts a feature is what later makes it
  expensive to move. Timed-action speed scaling spent its life in Dragonfly for exactly this
  reason and moved to `RFTDOddsAndEnds` in 0.8.0.
- Test forks are retired. Testing happens on git branches, not folder copies.
- Every Lua edit goes through `tools\check-lua.bat` before upload (silence = clean).
- `tools\run-tests.bat` runs behavioural tests under real Lua 5.1 for the modules that
  need no engine stubs - RDJson today. Lua 5.1 specifically: Kahlua is 5.1, and 5.3+ added
  an integer subtype that changes `math.floor` and `%.0f`, so a newer interpreter would
  give confident but wrong answers about `RDJson.fmtNum`. A green run here covers those
  modules only; it is not a statement about the bundle.
- No mod-id renames of existing mods, ever.
- The vehicle mod is spelled **Reclaimation** (reclaim + reclamation - intentional
  wordplay) everywhere human-facing; the mod id `RFTDReclamation` and derived
  identifiers keep the id spelling - frozen, not prose.
- Core emits its event registry as `RFTD/schema.json` at boot; external tooling in
  `tools/` consumes that artifact rather than carrying its own copy of the contract.
