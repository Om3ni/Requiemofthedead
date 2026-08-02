# Reaper backup — pre-popman-refactor

Full copy of `RequiemOfTheDead/Contents/mods/RFTDReaper` taken 2026-08-02, immediately
before the popman-informed refactor of RPCore.lua:

1. single-pass zombie enumeration (per-player cell walk removed — one server-wide IsoCell),
2. event-driven newborn detection via `OnZombieCreate` (sweep demoted to slow safety net),
3. two-stage fingerprinting (inventory signature only on tile+outfit collision).

Context: Mosaic set `ZombieConfig.ZombiesCountBeforeDelete = 0` the same day, making
Reaper the only population deleter on the server. Engine findings behind the changes:
`engine-popman-observability-42.20.md` at repo root.

To roll back: copy this folder's contents over `RequiemOfTheDead/Contents/mods/RFTDReaper`
(delete this README from the copy).
