# Plague Mask (Last Rites) - staged, not shipped

Unreleased clothing item pulled out of the bundle on 2026-07-26. Nothing here is
broken or abandoned; it is finished-looking work that simply is not ready to be
on a subscriber's disk yet.

## Why it left the bundle

The script was already `.disabled`, so Project Zomboid never loaded any of it.
But `.disabled` only stops the *engine* reading the file - it does nothing to stop
the file shipping. All six files were being pushed to every subscriber on every
Workshop update:

| File | Size |
|---|---:|
| `42/media/textures/RFTD_PlagueMask.png` | 625,607 b |
| `42/media/models_X/Static/Clothes/M_RFTD_PlagueMask.x` | 184,516 b |
| `42/media/models_X/Static/Clothes/F_RFTD_PlagueMask.x` | 184,515 b |
| `42/media/clothing/clothingItems/Hat_RFTD_PlagueMask.xml` | 573 b |
| `42/media/scripts/RFTD_PlagueMask.txt.disabled` | 839 b |
| `42/media/fileGuidTable.xml` | 211 b |

**996,261 bytes - 17.4% of the whole bundle**, downloaded by everyone, loaded by
nobody, and readable by anyone who opens the Workshop folder. That last part is
the real cost: an unreleased item is a surprise exactly once.

`fileGuidTable.xml` came too. It looks like shared infrastructure but its only
entry is the Plague Mask clothing XML, so it belongs with the item; Last Rites
ships no other custom clothing. If a second clothing item is ever added, the
editor regenerates this file.

## Restoring it

The `42/` tree here mirrors the mod's layout exactly, so putting it back is a
straight copy with no path edits:

```
robocopy wip\plague-mask\42 RequiemOfTheDead\Contents\mods\RFTDLastRites\42 /E
```

Then rename `RFTD_PlagueMask.txt.disabled` to `RFTD_PlagueMask.txt` to arm the
script, and confirm the mesh path in it (`Static/Clothes/M_RFTD_PlagueMask`)
still matches where the `.x` files landed.

## Before shipping it

- Both meshes are ~184 KB and the texture is 625 KB, which is heavy for one hat.
  Worth a look at the texture dimensions before it goes out to everyone.
- Last Rites currently declares itself a client QoL HUD mod (`mod.info`). Adding
  a craftable/wearable item changes what the mod *is*, so the description and the
  README's one-line summary both need updating in the same release.
