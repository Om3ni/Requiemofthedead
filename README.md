# Requiem of the Dead

Monorepo for the Requiem of the Dead Project Zomboid (Build 42) server mod suite.

**RFTDCore is the harness the rest of the RFTD family depends on.** It owns the
family's shared infrastructure — unified two-tier server logging (permanent per-player
*chronicle* streams + a bounded *forensic* ring), life-cycle instrumentation, season
bookkeeping, networking helpers, rate limiting, and capability-based staff access
gates. Satellite mods declare `require=RFTDCore` as each adopts a Core API; once
adopted, the dependency is hard.

## Mods

| Folder | Mod id | Workshop item | Status |
|---|---|---|---|
| `RFTDCore` | `RFTDCore` | *(unpublished)* | In development — v0.1 |
| `Dirge` | `RFTDDirge` | 3701543539 | Migrated — on the harness (1.1.0, requires RFTDCore; "RQ" dual-accept this release) |
| `Reclaimation` | `RFTDReclamation` | 3752878504 | Migrated — on the harness (0.7.0, requires RFTDCore) |
| `Dragonfly` | `Dragonfly` (+`BBLibrary`) | 3728273142 | Migrated — on the harness (0.7.0, requires RFTDCore); shakeout post-stable |
| — | `RFTDReaper` | 3730287596 | Evaluate vs 42.20 vanilla culling (order: 3) |
| — | `RFTDHusbandry` | 3711156499 | Migrating (order: 4) |
| — | `RFTDLastRites` | 3748797439 | Migrating (order: 4) |

Source of truth for unmigrated mods remains `C:\VSCodeProjects\PZMod` (repo
`Om3ni/PZMods`, branch `testing`, tag `pre-requiem-migration`). Each mod migrates on
its own branch: copy → hash-verify → wire-token standardization (module token = mod id,
one dual-accept release) → Core adoption → Workshop uploads thereafter happen from here
(`workshop.txt` ids update the existing items in place).

## Conventions

- Workshop upload shape per mod: `<Folder>/Contents/mods/<modid>/mod.info` +
  `<Folder>/Contents/mods/<modid>/42/media/...`, `preview.png` and `workshop.txt` at the
  folder root. Root and `42/` `mod.info` files stay byte-identical.
- Test forks are retired. Testing happens on git branches, not folder copies.
- Every Lua edit goes through `tools\check-lua.bat` before upload (silence = clean).
- No mod-id renames of existing mods, ever.
- The vehicle mod is spelled **Reclaimation** (reclaim + reclamation — intentional
  wordplay) everywhere human-facing. The mod id `RFTDReclamation` and derived
  identifiers (wire token, sandbox page, zone field ids, translation keys) keep the
  id spelling — they are frozen, not prose.
- Core emits its event registry as `RFTD/schema.json` at boot; external tooling in
  `tools/` consumes that artifact rather than carrying its own copy of the contract.

## The Dragonfly shakeout (at its migration turn)

Dragonfly becomes the pure admin panel. Memoir → `RFTDMemoir`; BanBox + BBLibrary →
`RFTDBanBox`; Scoreboard/RoleEditor → `RFTDStaffTools`; DFCore framework, DFLog buffer,
DFRegistry, DFPatch_* compat layer → `RFTDCore`.
