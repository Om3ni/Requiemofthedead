# Requiem of the Dead

Monorepo for the Requiem of the Dead Project Zomboid (Build 42) server mod suite.

**RFTDCore** is the orchestrator: unified two-tier logging (permanent per-player
*chronicle* + bounded *forensic* ring), life-cycle instrumentation, the season model,
networking helpers, and capability-based access gates. Satellite mods declare
`require=RFTDCore` as each adopts a Core API. The chronicle is the data source for
**Reflections** — the end-of-season per-player retrospective.

## Mods

| Folder | Mod id | Workshop item | Status |
|---|---|---|---|
| `RFTDCore` | `RFTDCore` | *(unpublished)* | In development — v0.1 |
| — | `RFTDDirge` | 3701543539 | Migrating from PZMod (order: 1) |
| — | `RFTDReclamation` | 3752878504 | Migrating from PZMod (order: 1) |
| — | `Dragonfly` (+`BBLibrary`) | 3728273142 | Migrating + shakeout (order: 2) |
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

## The Dragonfly shakeout (at its migration turn)

Dragonfly becomes the pure admin panel. Memoir → `RFTDMemoir`; BanBox + BBLibrary →
`RFTDBanBox`; Scoreboard/RoleEditor → `RFTDStaffTools`; DFCore framework, DFLog buffer,
DFRegistry, DFPatch_* compat layer → `RFTDCore`.

## Reflections

Core emits `RFTD/schema.json` (from `RDEvents.lua`) at boot; a separate schema-driven
chassis in `tools/reflections/` (stack TBD) builds one private, self-contained HTML page
per player at season's end. Nothing player-visible ships before the reveal.

Design docs: `docs/` — see also the plan files referenced in `docs/softplan.md`.
