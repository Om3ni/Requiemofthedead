# Legacy Workshop item sunset — plan of record

~11 outside servers run the standalone RFTD items. They get a real memo and a real
runway: **maintenance ends October 1, 2026.** The items keep working forever; they just
stop moving.

## The memo (per legacy item, one final release from PZMod)

Ships **after** the bundle ("Requiem of the Dead: Season One") is published, so the
splash can link the real item id.

1. Copy `SUNSET_SPLASH_TEMPLATE.lua` into the mod as
   `42/media/lua/client/RFTDSunset_<ModName>.lua`; set `MOD_NAME` and `BUNDLE_URL`.
   Staff-only, once per session, dismissible; server console line per boot. Never
   shown to regular players — operators are the audience.
2. Workshop description: prepend "SUPERSEDED by [Requiem of the Dead: Season One](link).
   Not maintained after October 1, 2026. This version keeps working as-is."
3. Upload from PZMod (the legacy items' source of truth). Syntax-gate first.
4. After Oct 1: items stay up, visibility unchanged, no further releases except
   critical breakage at owner's discretion.

## Roster

| Item | Workshop id | Sunset? |
|---|---|---|
| Dirge | 3701543539 | Yes |
| Dragonfly | 3728273142 | Yes |
| Husbandry | 3711156499 | Yes (after its migration turn lands in the bundle) |
| Last Rites | 3748797439 | Yes (after its migration turn) |
| Reclamation | 3752878504 | Yes (unlisted, low traffic) |
| Reaper | 3730287596 | Pending the 42.20 culling verdict — sunset either way (replaced or retired) |
| **OmenSpyNetwork** | 3747461064 | **NO — stays standalone and frozen.** Supervisory probe with its own outside constituency; its code already lives on inside Core (RDGuardian). Feature-frozen, maintenance-only. |

BBLibrary ships inside the Dragonfly item and sunsets with it.
