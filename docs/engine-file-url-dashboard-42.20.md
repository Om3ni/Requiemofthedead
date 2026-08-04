# Engine determination — The file:// dashboard pattern (PZ_Pulse, 42.20.0)

*Analyzed Workshop mod 3753700423 ("PZ Pulse" by qwerto, v0.3.3) at
`D:\Steam\steamapps\workshop\content\108600\3753700423`, engine claims verified against
`PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02. Companion to
`engine-lua-file-io-42.20.md`.*

**Short version: there is no HTTP, no server, no socket. The game writes JavaScript
payloads disguised as `.txt` files into `Zomboid/Lua/`, and a static HTML page — opened
in a browser via a `file:///` URL — polls them by repeatedly injecting `<script>` tags
with a cache-buster. It's a one-way file mailbox that looks like streaming. Everything
it does is built on the exact write paths mapped in `engine-lua-file-io-42.20.md`.**

## The mechanism, end to end

### Game side (client Lua, `PZ_Pulse.lua`)

1. On a throttled render tick (250–2000 ms slider; `OnRenderTick` + `OnTickEvenPaused`
   so it survives pause and main menu), collect player status into a table and
   serialize it with a hand-rolled Lua→JSON encoder (Kahlua has no JSON lib).
2. Write two files under `Zomboid/Lua/PZ_Pulse/` via `getFileWriter`:
   - **`heartbeat.txt`** — rewritten *every* export tick:
     `window.PZ_BEAT = {beat, seq, interval, state, build, mp, mem}`. A monotone
     `beat` that stops advancing = the game closed.
   - **`data.txt`** — rewritten *only when the payload changed*:
     `window.PZ_DATA = {...}; window.PZ_DATA.seq = N`. The heartbeat carries the
     current `seq`, so the page knows when to re-pull.
3. Both files are **JavaScript wearing `.txt` names** — forced by the 42.20
   `getFileWriter` allowlist (`Set.of("ini","cfg","txt","log")`). Pre-42.20 the mod
   wrote real `.js` and even the `.html` shell; the allowlist killed that, so the page
   now ships static inside the mod at `42/media/web/index.html`.

### Browser side (static page shipped in the mod)

1. The player opens
   `file:///<modDir>/42/media/web/index.html?d=file:///<user>/Zomboid/Lua/PZ_Pulse/` —
   the `?d=` parameter tells the shipped (immovable) page where this machine's live
   data lives.
2. A `file://` page **cannot `fetch()` sibling files** (browser cross-file blocking),
   but it **can load them as classic scripts**:
   ```js
   var s = document.createElement('script');
   s.src = DATA_BASE + 'heartbeat.txt?t=' + Date.now();   // index.html:3532
   ```
   The script executes (Chrome runs it regardless of the text/plain type over
   `file://`), assigns `window.PZ_BEAT`, and the `?t=` cache-buster forces a fresh
   disk read each poll.
3. The page polls the heartbeat at the interval the heartbeat itself declares; when
   `seq` changes it re-pulls `data.txt` the same way and re-renders in place.

### Getting the URL to the player

- `openUrl` **cannot open it** — it's gated by a hardcoded 4-domain Indie Stone
  whitelist (steamcommunity.com / projectzomboid.com / theindiestone.com / pzwiki.net,
  [LuaManager.java:1277](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1277),
  gate at [:5998](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L5998)),
  so `file://` silently no-ops. **Verified — the mod's comment is accurate.**
- `Clipboard.setClipboard` **is ungated** (exposed at
  [LuaManager.java:1802](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1802),
  [Clipboard.java:55](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/Clipboard.java#L55)) —
  so the mod builds the URL from `getModInfoByID("PZ_Pulse"):getDir()` +
  `Core.getMyDocumentFolder()` and offers a "Copy dashboard URL" button. Copy/paste is
  the universal bridge out of the sandbox.

## What the author missed: the `getFileOutput` loophole

The mod's comments state "the mod can no longer write .js or .html at all." **False** —
`getFileOutput` ([LuaManager.java:4794](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4794))
returns a raw `DataOutputStream` with no extension check; `writeBytes` from Lua writes
real `.js`, `.json`, `.html` into the same jail. PZ_Pulse's ship-the-shell redesign is
better engineering anyway (static page + data files), but for RFTD the costume is
optional: we can write honest `.js`/`.json` and skip the `.txt`-as-script trick
entirely.

## What's possible around this mechanism

1. **A live ops dashboard for Mosaic — the popman sensor's display layer.** Server Lua
   has the identical `getFileWriter`/`getFileOutput` surface. Wire/RDMeter metrics
   (births, deaths, zombie-list size, derived virtualized, tick gaps, per-player
   boundary crossings) written as a heartbeat + change-gated data file on the dedi box
   give any browser on that machine a live graph — zero in-game network traffic, zero
   engine risk. This is the missing display layer for
   `engine-popman-observability-42.20.md`.
2. **Remote viewing needs one sidecar.** A `file://` page only works on the machine
   that owns the files. Point any static file server (`python -m http.server`, nginx,
   caddy) read-only at the folder and remote browsers get the same dashboard — plus
   real `fetch()` (the cross-file blocking vanishes over http). The "server" is a
   sidecar process, never the game.
3. **Inbound is half-possible.** The browser page itself cannot write files, so the
   loop stays one-way. But game Lua can poll an inbox file with `getFileReader` every
   N ticks — anything local that can write a file (a helper script, an editor, a
   sidecar receiving HTTP POSTs) can feed commands in. The trust boundary is the local
   machine: anything that can write the folder can inject data — and if the payload is
   script-shaped, inject code into the dashboard page. Keep dashboards read-only;
   sanitize any inbox.
4. **Client-side second screens for players.** The same pattern works per-player in MP
   (PZ_Pulse is exactly that). A Necro-tab mirror or squad status page is feasible
   without touching the game's render loop.
5. **Pattern hygiene worth copying:** heartbeat (liveness) separate from data
   (change-gated), `seq` for cheap change detection, interval carried in-band so poll
   rate tracks write rate, every collector pcall-wrapped so one missing getter degrades
   one field, and the write throttle floor (250 ms) keeping main-thread file I/O
   negligible.

## Constraints

- Writes are main-thread open/truncate/write/close — throttle and change-gate, as
  PZ_Pulse does. Never per-frame.
- The `.txt`-as-script trick is verified in Chrome; other browsers may honor MIME over
  `file://`. Writing real `.js` via `getFileOutput` sidesteps the question.
- On a dedi, `Zomboid/Lua/` is the server's cache dir (Mosaic: the pzdata tree) — the
  dashboard lives where the server runs, not where players sit, unless a sidecar
  serves it.

## Risk posture on the `getFileOutput` loophole (2026-08-02)

Treat it as convenience, never foundation — it is plainly an oversight (a gate on one
function, an ungated stream one function over) and IS has shown they'll break modders
mid-beta (the 42.20 allowlist itself forced PZ_Pulse's redesign). The allowlist gates
*names*, not formats: JSON-in-`.txt` via `getFileWriter` is front-door legal, and over
HTTP the extension is irrelevant to `fetch()`. Design rule for SpyMaster/Wire: every
load-bearing write goes through `getFileWriter` + allowlisted names; the loophole may
only carry niceties with a one-line fallback (real `.json` names, self-deploying
dashboard page → fallback: rename, or hand-copy one static HTML). Route all file
output through one Wire chokepoint module so any future tightening is a one-file fix.
