# Copyright and third-party notices

**Requiem of the Dead** — copyright © 2026 Project_Omen. All rights reserved except as
granted by the GNU General Public License, version 3, the full text of which is in
[LICENSE](LICENSE).

## What the licence means here, in plain words

You may use, study, modify and redistribute this work. If you distribute it — modified or
not, on the Steam Workshop or anywhere else — you must:

1. **Keep the copyright notices.** Every file's `Copyright Project_Omen` line stays.
2. **Licence your version under GPL-3.0 as well.** No closing it up.
3. **Publish your complete source**, to whoever you gave the binary to.
4. **Say what you changed.**

What that does *not* do, and it is worth being honest about it: the GPL does not stop
someone reuploading a credited, source-available copy. No licence does. What it does is
make an *uncredited* or *closed* copy a licence violation, which is the standing you need
to file a DMCA notice with Valve. Enforcement is a takedown process, not a technical one.

## Third-party components

**None.** As of 2026-08-04 every mod in the bundle is Project_Omen's own work, and the GPL
grant above covers all of it without carve-out. Both previously outstanding items were
resolved rather than papered over:

| Component | Was | Resolution |
|---|---|---|
| `Longstrider/LSMap.lua`, `LSGridOverlay.lua` | Flagged as deriving the map-widget bring-up and overlay hook mechanics from PhunZones2 (UburGeek) | **Re-authored 2026-08-04** (LM-EDIT-1). The bring-up sequence proved to be *vanilla's own* — `ISUI/Maps/ISMiniMap.lua:709-723` and `ISMapDefinitions.lua:22-30` run it, across eight vanilla call sites — so it was rewritten from The Indie Stone's shipped Lua and the engine decompile. The zoom-fit search loop, which genuinely was PhunZones', is replaced by a direct solve from the published projection formula. No `LS-DERIVED` markers remain anywhere in the tree. |
| `RFTDEchoes` | A fork of *Musicians of the Wasteland* by Gravy (Workshop `3301008514`), recorded in-file as "open-use license" | **Pulled from the bundle 2026-08-04** to `wip/echoes-fork/`. The claimed licence could not be substantiated — the Workshop description states no licensing or reuse terms at all — so a fork of it is not ours to relicense. It ships nowhere until the upstream author grants permission. See [wip/echoes-fork/README.md](wip/echoes-fork/README.md). |

The standing rule, from `docs/limes-design.md` §2: **ideas, never lines.** Where a mechanism
can only be expressed one way, the authority to cite is the engine decompile or vanilla's
own shipped Lua — not the mod that called it first.

`docs/limes-design.md` §2 states the standing rule the family works under: **ideas, never
lines.** Where a mechanism can only be expressed one way, the authority to cite is the
engine decompile, not the mod that called it first.

## A note on the engine

Project Zomboid, its engine, assets and APIs are the property of The Indie Stone. This
project is an unofficial modification. Nothing here is endorsed by or affiliated with
The Indie Stone, and no engine code is redistributed.

## Adding the header to a file

The GPL asks that each source file carry a short notice. The family's convention already
puts `-- Copyright Project_Omen` at the foot of a file; the fuller form is:

```lua
-- <FileName>.lua - <one-line purpose>
--
-- Copyright (C) 2026 Project_Omen
--
-- This file is part of Requiem of the Dead. It is free software: you may
-- redistribute and/or modify it under the terms of the GNU General Public
-- License as published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version. It is distributed
-- WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
-- or FITNESS FOR A PARTICULAR PURPOSE. See <https://www.gnu.org/licenses/>.
```
