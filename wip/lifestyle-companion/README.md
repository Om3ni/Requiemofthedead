# Lifestyle Companion — PULLED 2026-07-31

`RFTDLifestyleCompanion` was pulled from the shipped tree the same day it was
built, before ever being committed or published. It lives here in case it comes
back.

## Why it was pulled

Owner call: hardening Lifestyle: Hobbies' networking exposed more problems than
the Companion fixed — the adversarial review kept finding new upstream issues
past the ~14–15 the port addressed, and shadow-maintaining someone else's mod
at that defect rate is a treadmill, not a patch. The honest paths are upstream
fixes or a sanctioned fork, not a third-party bandage.

## Revival condition

Only if the author ([Angry], workshop item 3403870858) grants permission to
fork — or lands the fixes upstream, in which case only the RDNet family
integration would return, not the shadows. The author had been approached about
bundling the fixes; see `RFTDLifestyleCompanion/README.md` for the technical
handover (gating policy table, verification status, per-file rationale).

## What's here

- `RFTDLifestyleCompanion/` — the complete mod as pulled: hardened
  `LSservercommands.lua` shadow (RDNet default-deny over all ~86 "LS"
  commands), `RDLS_TransferHelperFix.lua` (anti-dupe/anti-mint), `Read.lua`
  shadow (NeuralHat crash fix), constants, README.
- `tools/` — `check-upstream.sh` staleness guard + the sha256 snapshot of the
  upstream files the port was made from (Lifestyle modversion 0.4.0).

Status at pull: all Lua parses, command coverage verified against upstream
(82 registered + 4 intentional default-deny), relay arg-mappings verified.
Never live-tested — the one MDS login attempt died on an unrelated server
config problem (Lifestyle itself missing from Mods=, world dictionary still
holding its scripts).

All Lifestyle content, code and design belong to its author; the patch code
here is Requiem of the Dead's own work.
