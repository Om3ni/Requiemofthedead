# Requiem of the Dead

Monorepo for the Requiem of the Dead Project Zomboid (Build 42) server mod suite.

**One Workshop item, many mods.** [RequiemOfTheDead/](RequiemOfTheDead/) is the single
release artifact: every RFTD mod id ships inside it and updates atomically, so version
skew between family members is structurally impossible. Servers subscribe to one item
and enable the mod ids they want via `Mods=`.

**RFTDCore is the harness the rest of the family depends on.** It owns the shared
infrastructure — unified two-tier server logging (permanent per-player *chronicle*
streams + a bounded *forensic* ring), life-cycle instrumentation, season bookkeeping,
networking, rate limiting, capability-based access gates, the DFRegistry/DFLog/DFFeedback
framework, and the compat/anti-grief patch layer. Every other mod declares
`require=RFTDCore`; the dependency is hard.

## Mods in the bundle

| Mod id | What it is | Version |
|---|---|---|
| `RFTDCore` | The harness (required by everything) | 0.1.0 |
| `Dragonfly` | Admin command center: tabbed panel, item editor, Longstrider map/tours, action-speed scaling, debug gate | 0.7.0 |
| `RFTDStaffTools` | Extended ESC scoreboard + unlocked role editor + role persistence | 0.7.0 |
| `RFTDMemoir` | Craftable character snapshot/restore journal | 0.7.0 |
| `RFTDBanBox` | Item ban engine (loot-strip + login confiscation) | 0.7.0 |
| `BBLibrary` | RotD default ban list for RFTDBanBox (opt-in) | 0.1.0 |
| `RFTDReclamation` | Reclaimation — vehicle lifecycle: claims, permissions, fleet panel, dismantling, the Janitor | 0.7.0 |
| `RFTDDirge` | Special zombie variants: Screamers, Juggernauts, EMP, Gluttons, Scavengers, Bosses | 1.1.0 |
| `RFTDHusbandry` | Animal taming, breeding, and management | 0.2.0 |
| `RFTDLastRites` | Client QoL HUD: life-threat indicators (cold, heat, bleeding) | 0.2.0 |
| `RFTDReaper` | Twin-spawn bloom detector/culler — **pending the 42.20 verdict**; may retire with the Necro tab folding into Dirge | 1.2.0 |

**The migration is complete.** `C:\VSCodeProjects\PZMod` (repo `Om3ni/PZMods`) is the
frozen archive: history, tooling, the engine decompile, retired test forks, and the
deliberately-left-behind mods (OmenSpyNetwork — standalone and frozen with its own
users; Cookbook, OddsAndEnds, Sector7). Legacy per-mod Workshop items freeze as
superseded-by pointers per `docs/legacy-items/DEPRECATION.md` (October 1 sunset).

## Naming

Display names are "Requiem of the Dead: X" — Season One (RFTDCore; the harness wears
the season's name and rolls to Season Two at the next wipe, id never changes), Memoirs,
Ban Box, Staffing Tools, Dragonfly, Dirge, Reclaimation, and at their turns Husbandry
and Last Rites. Display names are free text; mod ids are frozen.

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
- Test forks are retired. Testing happens on git branches, not folder copies.
- Every Lua edit goes through `tools\check-lua.bat` before upload (silence = clean).
- No mod-id renames of existing mods, ever.
- The vehicle mod is spelled **Reclaimation** (reclaim + reclamation — intentional
  wordplay) everywhere human-facing; the mod id `RFTDReclamation` and derived
  identifiers keep the id spelling — frozen, not prose.
- Core emits its event registry as `RFTD/schema.json` at boot; external tooling in
  `tools/` consumes that artifact rather than carrying its own copy of the contract.
