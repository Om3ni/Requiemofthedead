# RFTDEchoes — pulled from the bundle 2026-08-04

Parked here, not deleted. Same treatment as `wip/lifestyle-companion/`: the work is sound,
the permission is not settled.

## Why it was pulled

Echoes is a **fork** of *Musicians of the Wasteland* by **Gravy**
([Workshop `3301008514`](https://steamcommunity.com/sharedfiles/filedetails/?id=3301008514)).
`ECCore.lua` records the upstream as carrying an "open-use license".

Checked on 2026-08-04, that could not be substantiated: **the Workshop description states no
licensing, permission, reuse, forking, or redistribution terms at all.** "Open-use license"
appears to be a good-faith paraphrase of the mod being extension-friendly — the description
does say it is "easy to extend with addon-mods" and points at a git repo of example addons
— but *extensible* is not *licensed for forking*, and no licence text was located.

With no stated upstream terms, the default is that the author retains all rights. That means:

- Echoes cannot be published under this repository's GPL-3.0, because a fork of unlicensed
  work is not ours to relicense.
- Shipping it while asking others not to pirate our work is the exact argument we would
  lose in public.

Being a fork, it also belongs on its own footing rather than inside a suite that shares one
licence and one lockstep version — which is why it moves out rather than merely going dark.

## What would bring it back

1. **Ask Gravy.** Written permission to fork and redistribute, ideally naming a licence.
   This is the same gate `wip/lifestyle-companion/` sits behind, and that precedent is why
   the mod is parked instead of scrapped.
2. **Record the answer here**, then either ship Echoes as a separate mod under whatever
   terms upstream grants, or — if permission is declined — retire it.

Note the upstream credits *Bard Interactive Music* by Phibonacci
([GitHub](https://github.com/Phibonacci/Bard-Interactive-Music), MIT) for animations. MIT
covers that component only; it says nothing about Gravy's own work.

## Contents

The mod tree is intact and unmodified at `RFTDEchoes/`. Nothing was stripped, so a revival
is a move back plus a version bump — no reconstruction.

Loose ends noted at the time of the pull: the songbook UI was still a stub awaiting a
layout, and `UISCHEMA.md` in the repo root still references Echoes as the worked example
for the shared UI vocabulary. That reference is deliberate and harmless — the schema
outlived the mod that motivated it.

## Server note

`RFTDEchoes` may still appear in a server's `Mods=` line (Mosaic's `MDS.ini` did at the
time of writing). With the folder gone from the bundle, that entry now points at nothing —
remove it from the server config or the mod simply fails to load.
