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

The licence above covers Project_Omen's own work. Portions of this repository derive from
other authors and remain governed by their original terms. **Anything listed here is not
Project_Omen's to relicense**, and a GPL grant over these sections is not asserted until
each item's status is settled.

| Component | Origin | Status |
|---|---|---|
| `Dragonfly/.../Longstrider/LSMap.lua`, `LSGridOverlay.lua` | PhunZones2 (UburGeek) — the `ISMiniMapInner` bring-up ritual and the overlay hook/transform mechanics, marked in-file with `LS-DERIVED BEGIN`/`END` | **Unresolved.** Marked `RE-AUTHOR before Workshop publish` and tracked as **LM-EDIT-1** in `docs/limes-design.md` §2. Re-authoring these from the engine decompile removes the dependency entirely and is the intended resolution. |
| `RFTDEchoes` | Forked from *Musicians of the Wasteland* (Steam Workshop `3301008514`), noted in `ECCore.lua` as carrying an "open-use license" | **Needs confirming.** "Open-use" is a description, not a named licence. The upstream terms should be read and recorded here before this mod is published under GPL-3.0. |

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
