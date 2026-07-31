# Dragonfly sidebar badge - source art

Masters for the Dragonfly Panel button in the vanilla left-hand sidebar, the one
that sits beneath CLIENT and ADMIN (`DFSideButton.lua`).

| File | State | Shown when |
|---|---|---|
| `DF_Panel_Off_master.png` | green | panel closed |
| `DF_Panel_On_master.png` | red | panel open |

Both 1024x1024 RGBA with real alpha. Renamed from `Dragonfly.png` / `Dragonfly2.png`
because a trailing "2" does not say which state it is.

## Regenerating the shipped set

```
python tools/make-sidebar-icon.py art/dragonfly/DF_Panel_Off_master.png \
    RequiemOfTheDead/Contents/mods/Dragonfly/42/media/ui/DFSidebar \
    --name DF_Panel_Off --align-with art/dragonfly/DF_Panel_On_master.png

python tools/make-sidebar-icon.py art/dragonfly/DF_Panel_On_master.png \
    RequiemOfTheDead/Contents/mods/Dragonfly/42/media/ui/DFSidebar \
    --name DF_Panel_On --align-with art/dragonfly/DF_Panel_Off_master.png
```

Needs Pillow (`pip install Pillow`) - the only tool in `tools/` that is not
stdlib-only.

## `--align-with` is not optional, and here is why

The two states are swapped in place by `setImage()`, so any difference in scale or
offset between them reads as the badge JUMPING the moment the panel opens.

These two renders do not have the same alpha bounds - the green extends 839px tall,
the red only 804px. Normalising each on its own bounding box magnifies them by
different amounts and produces a 4.4% size pop on every toggle. `--align-with`
unions both bounds into one shared crop frame (`112, 96, 911, 935`) so both states
are cut and scaled identically. Union is commutative, so the order of the two runs
cannot matter.

Verified after generating: the alpha silhouettes share a bounding box at all five
sizes (one 1px glow-falloff difference at 96). If you re-render either state,
regenerate BOTH - a fresh render will have its own bounds and the old sibling was
framed against the old union.

## Why the output is square when the button is not

The sidebar button is `TEXTURE_WIDTH x (TEXTURE_WIDTH * 0.75)`, i.e. 4:3, but the
art is square - exactly as vanilla ships it (`Admin_Icon_Off_128.png` is 128x128).
`ISButton` uses `drawTextureScaledAspect`, which fits the art inside the button
without distorting it. Do not pre-squash to 4:3.

Content fills 95.3% of the canvas to match vanilla (122 of 128px). The masters fill
~78%, so a straight downscale renders a visibly runty badge next to its neighbours;
the tool corrects this. `--fill 1.0` keeps the art's own margins instead.

## Sizes

PZ ships five variants per icon, one per sidebar-size option, and picks the folder
matching its current `TEXTURE_WIDTH`: 48, 64, 80, 96, 128. Shipping one file means
four of the five settings get a runtime rescale, so generate the set.

Output lands in `Dragonfly/42/media/ui/DFSidebar/<W>/DF_Panel_<State>_<W>.png` -
a Dragonfly-owned folder, deliberately not vanilla's `media/ui/Sidebar/`, so our
files can never shadow or be confused with the engine's.
