# FakeClient Runbook — synthetic players, and per-client traffic attribution

**What this is:** Project Zomboid B42 ships an undocumented, scenario-driven synthetic-client
harness — `zombie.network.FakeClientManager` — a standalone `main()` that spawns N fake players,
each speaking the real UDP protocol to a **real dedicated server**. The load lands on your actual
GameServer with your actual 111-mod list loaded, so every relay, every mod's `OnTick`, and every
broadcast executes for real. You synthesize the *players*, not the engine.

**What makes it worth the trouble:** the engine's Prometheus exporter labels packet histograms by
**`client`** — and the bots log in as `Client0`…`ClientN`. So bot traffic is individually
addressable. See §5; it is the reason this rig exists in this repo rather than being a curiosity.

Every `:NNN` below is a line in
`PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/FakeClientManager.java`, **re-verified
against 42.20** unless another file is named. (The 42.19 edition of this runbook was ~1 line
optimistic throughout; those citations have been corrected, not carried forward.)

---

## 0. What is and isn't faithful

The bots are faithful to the **server's** work: inbound handling, the relay fan-out, frame-step
cost, and every byte the server sends. That is exactly the half you are measuring. Their *inbound*
handling is a stub — `receive()` (:691) parses a subset of packet types and drops the rest. So
"bytes the server sent to Client7" is a real measurement; "what a real client would do with them"
is not simulated.

Because the metric that matters is main-thread CPU and server-side bytes, **you do not need 14
machines or real internet**. Mosaic plus a bot process on the same box over loopback exercises the
real path.

---

## 1. Mosaic prerequisites

Checked against `C:\Mosaic\pzdata\Server\MDS.ini` on 2026-08-03 — **Mosaic is already correct on
every count**, nothing to change:

| Setting | Needed | Mosaic today | Why (`file:line`) |
|---|---|---|---|
| `DoLuaChecksum` | false | **false** | Server sets `checksumState=Done` when false, so the bot can skip checksum entirely (`LoginPacket.java:80-81`) |
| `Password` | empty | **empty** | Bot logs in with no password (`:785-793`) |
| `Open` | true | **true** | Users auto-create on join |
| `MaxPlayers` | ≥ bot count | **32** | Else the ServerFull denial fires (`LoginPacket.java:83-86`) |
| `DefaultPort` | 16261 | **16261** | Hardcoded bot target (`SERVER_PORT`, :55) |
| `MultiplayerStatisticsPeriod` | ≥1 | **1** | Gauge refresh cadence (`StatisticManager.java:121`) |

Two things that are **not** pre-verified and must be checked on the first run:

- **Version match.** The server rejects a client whose version string differs, hard, at login
  (`LoginPacket.java:46-51`). The bot sends its **own JVM's** version — `Core.getVersionNumber()`,
  captured at :58 and written at :790 — so it is only correct if the install you launch the bot
  from is the same build as Mosaic's dedi. Both should be `42.20`. Confirm before blaming the JSON.
- **Steam mode must be OFF.** Not optional, and this was got wrong once already — see the box below.

> ### Steam mode blocks bots at the transport layer (observed 2026-08-03)
> `SteamUtils.java:64-72` loads **one** networking library:
> `steam_api64 + RakNet64 + ZNetJNI64` when `zomboid.steam=1`, or `RakNet64 + ZNetNoSteam64` when
> it is `0`. The bot hardcodes `ZNetNoSteam64` (:348) with no Steam option at all.
>
> Point a bot at a Steam-mode server and it fails **silently**: packets reach UDP 16261 and are
> dropped below the login layer, so there is no kick, no denial, no `_user.txt` entry — just
> `game{parameter="players"} 0` and a bot retrying forever.
>
> An earlier version of this runbook claimed Steam mode was fine because `LoginPacket.java:56-63`
> only *records* steamId with no reject branch. That reading is accurate and irrelevant: nothing
> gets far enough to be logged in. **Check the transport, not the login path.**
>
> Turning Steam off costs the workshop mods too — `getInstalledItemModsFolders` (:429) and
> `getStagedItemModsFolders` (:439) are both gated on `isSteamModeEnabled()`, so a no-Steam server
> boots vanilla unless the mods are staged into the cachedir `mods` folder first. Use
> `../netprobe/stage-mods.ps1`, then `../netprobe/1B-START-NOSTEAM.bat`.

> **Use a throwaway world.** Bots create characters, write DB rows, and (with `createHorde`) spawn
> zombies. Mosaic is the test surface, but back up `C:\Mosaic\pzdata` if the current save matters.

---

## 2. Launching bots

`FakeClientManager` needs the full PZ classpath and natives (`RakNet64`, `ZNetNoSteam64`, :347-348),
exactly like the game. Easiest is to reuse the client install's own launch line and swap the main
class.

**Use `run-bots.ps1`.** It exists because the raw command line does not survive being pasted into
PowerShell: argument mode splits unquoted `-D` properties on the dot, turning
`-Djava.awt.headless=true` into `-Djava` plus `.awt.headless=true`, so java takes the fragment as
the main class and reports `Could not find or load main class .awt.headless=true` — which reads as
a classpath fault and is not one. The classpath and `java.library.path` both contain `;`, a
PowerShell statement separator, and fail the same way for a different reason.

```powershell
.\tools\fakeclient\run-bots.ps1 -Id 0     # smoke test, one bot
.\tools\fakeclient\run-bots.ps1           # all 14
```

The script echoes its target before connecting, so a run aimed at the wrong host is obvious
immediately rather than an hour later. Parameters: `-Scenario`, `-PZ`, `-HeapGB`.

Equivalent raw form, for reference or for a `.bat` (where the dot-splitting does not occur):

```bat
cd /d "D:\Steam\steamapps\common\ProjectZomboid"
.\jre64\bin\java.exe ^
  -Djava.awt.headless=true ^
  --enable-native-access=ALL-UNNAMED ^
  --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED ^
  -Xmx2g ^
  -Djava.library.path=./win64/;./ ^
  -cp "./;projectzomboid.jar" ^
  zombie.network.FakeClientManager ^
  -scenarios="C:\VSCodeProjects\RequiemoftheDead\tools\fakeclient\scenario-14bots.json"
```

- `-scenarios=<file>` — **required** (:334-335). Missing/blank → `Invalid scenarios file name` (:342).
- `-id=<n>` — optional (:338-339); run ONLY movement `n`, on port `17500+n`. **Use this for the
  first smoke test.** Omit to run every `movements[]` entry in one process (:373-375).
- Run **from the install dir** so the natives resolve.

One bot per daemon thread (:549-551), staggered by `id * connection.interval` (:228). The process
lives until all bots quit (:377-379). Ctrl-C to stop.

**Smoke test before anything else:**

```bat
... zombie.network.FakeClientManager -scenarios="...\scenario-14bots.json" -id=0
```

Expect `Start client (0) ...` then a `Player   N connect in X.XXXs` line (:444). If you instead see
a kick, read it — `receiveKicked` prints the server's reason verbatim (:1155).

> **JVM note:** `main` at :328 is declared **package-private**, not `public`. It runs because PZ
> ships Zulu 25, whose relaxed launch protocol accepts a non-public `main`. Point an older JRE at
> this and it dies with "Main method not found" — which looks exactly like a missing class. Use the
> bundled `jre64`.

---

## 2a. Resource budget — read this before running 14

Measured on this box 2026-08-03: Ryzen 7 3700X (8c/16t), 31.9 GB RAM. With Mosaic and one game
client already up: **1.8 GB free, 30.1 GB committed, Memory Compression already at 2.0 GB.**

**CPU is not the constraint.** The server is main-thread-bound, and 14 bot threads doing
`update(); sleep(1)` (:587-590) are cheap. 16 logical cores is ample.

**RAM is the constraint, and it will corrupt your results before it breaks anything.** A box
swapping during a capture produces inflated tick times and GC pauses that look exactly like a
misbehaving mod. You would then bisect for hours chasing your own memory pressure.

The offender is Mosaic's `-Xms16g -Xmx16g`: `Xms == Xmx` commits the full 16 GB at startup
regardless of need. For a bot run with no real players, that is wildly oversized.

| Test-run setting | Frees | Note |
|---|---|---|
| Server `-Xms4g -Xmx8g` | ~6 GB | plenty for 14 bots and no humans |
| Run captures with `-NoClient` | ~6.4 GB | the bots ARE the players |
| Bot JVM `-Xmx2g` | — | stops the default (1/4 RAM = 8 GB) ceiling from mattering |

That budget lands near 15 GB of 32 with real headroom. Bots are light — they never render, and
`receiveChunkPart` (:1017) discards chunk payloads rather than building a world.

Only launch your own client for the §6.1 calibration run, which needs exactly one bot.

Sanity-check before every capture:

```powershell
$os = Get-CimInstance Win32_OperatingSystem
"Free: {0:N1} GB" -f ($os.FreePhysicalMemory/1MB)   # want >6 GB before starting bots
```

---

## 3. Scenario JSON schema (reversed from `load()` :76-286)

A ready file sits next to this one: `scenario-14bots.json`.

```jsonc
{
  "version": "42.20",                       // REQUIRED to be PRESENT (:82) but its VALUE IS INERT —
                                            // see the note below. Missing => whole file fails to load.
  "config": {
    "client": {
      "connection": {
        "serverHost": "127.0.0.1",          // optional (:86-88), default 127.0.0.1
        "interval": 1500,                   // REQUIRED (:89) ms; join stagger = id*interval
        "timeout": 10000,                   // REQUIRED (:90) ms handshake timeout
        "delay": 15000                      // REQUIRED (:91) ms reconnect delay
      },
      "statistics": { "period": 5, "id": 0 },// REQUIRED (:93-94). id = which bot prints stats/time-sync
      "checksum": { "lua": "...", "script": "..." }  // OPTIONAL (:95-99). OMIT — Mosaic has DoLuaChecksum=false
    },
    "zombies": {                            // OPTIONAL (:100-129)
      "behaviour": "Normal", "maxZombiesPerUpdate": 50,
      "deleteZombieDistance": 100, "forgotZombieDistance": 70,
      "canSeeZombieDistance": 40, "seeZombieDistance": 30, "canChangeTarget": true
    },
    "player": {
      "fps": 60,                            // REQUIRED (:131) bot update rate
      "predict": 100,                       // REQUIRED (:132) gates PlayerUpdate send cadence (:1979-1984)
      "damage": 0.0,                        // optional (:133-135)
      "voip": false                         // optional (:136-138)
    },
    "movement": {                           // REQUIRED defaults (:140-153)
      "radius": 150,
      "motion": {
        "aim": 4, "sneak": 6, "sneakrun": 10, "walk": 7, "run": 13, "sprint": 19,
        "pedestrian": { "min": 5, "max": 20 }, "vehicle": { "min": 40, "max": 80 }
      }
    }
  },
  "movements": [                            // ONE ENTRY = ONE BOT (:154-277)
    {
      "id": 0,                              // REQUIRED unique int (:158); also default connect stagger
      "description": "bot00",               // optional (:160-162)
      "spawn": { "x": 10800, "y": 9500 },   // optional (:165-169), else random 6000-12000
      "motion": "Walk",                     // optional (:171-173), else random (80% Pedestrian)
      "type": "Stay",                       // optional (:212-215), default Line
      "speed": 7,                           // optional (:174-211), else derived from motion
      "radius": 150,                        // optional (:216-219)
      "direction": "N",                     // optional (:220-223) IsoDirections; else random
      "ghost": false,                       // optional (:224-227)
      "connect": 0,                         // optional ms (:228-231), else id*interval
      "disconnect": 0,                      // optional ms (:232-235) 0=never
      "reconnect": 0,                       // optional ms (:236-239)
      "teleport": 0,                        // optional ms (:240-243)
      "destination": { "x": 10850, "y": 9550 },                       // optional (:244-250)
      "createHorde": { "count": 50, "radius": 20, "interval": 8000 }, // optional (:251-260)
      "makeSound": { "interval": 4000, "radius": 30, "message": "hi" } // optional (:261-270)
    }
  ]
}
```

**`motion`** (:495-505): `Aim, Sneak, Walk, SneakRun, Run, Sprint, Pedestrian, Vehicle`
**`type`** (:507-516): `Stay, Line, Circle, AIAttackZombies, AIRunAwayFromZombies, AIRunToAnotherPlayers, AINormal`
(`Stay` pins the bot at spawn but it **still emits PlayerUpdates** via `run()` :1983 — ideal for a
co-located pile.)

> ### The `version` field is inert — corrected 2026-08-03
> The 42.19 runbook said "match your server banner or the handshake may reject." That is **wrong**,
> and it sent you chasing banner strings. `load()` parses it into `Movement.version` at :82 and
> **nothing ever reads that field again** — the login writes `versionNumber` (:790), the static
> captured from `Core.getInstance().getVersionNumber()` at :58, i.e. the bot JVM's own build.
>
> What still matters: the key must be **present**, because `getString("version")` throws when
> absent, the whole `load()` is wrapped in one try (:78-282), and the catch returns an **empty
> movements map** — so a missing `version` silently yields *zero bots* and a single
> `Scenarios file load failed` line. Version mismatches are real, but they are fixed by launching
> the bot from a matching install, not by editing JSON.

---

## 4. Which knob pulls which lever

Each bot's `run()` loop (:1943-1998), gated by `player.fps`:

| Mechanism | Driven by | Code |
|---|---|---|
| PlayerUpdate relay fan-out (O(players²), worst with co-location) | bot count × `predict`, and shared `spawn` | `sendPlayer` :1983 |
| Chat-triggered mod broadcasts | `makeSound.message` | `sendChatMessage` :1994 |
| Server-side zombie sim cost | `createHorde` → `/createhorde2` | :1990, command built :2027 |
| World-sound broadcast | `makeSound` | `sendWorldSound4Player` :1993 |

So: **co-located `Stay` bots** maximise the relay; **`makeSound` bots** exercise every mod that
hooks chat; **`createHorde` bots** manufacture zombie load on demand.

---

## 5. The payoff — per-client traffic attribution

This is the part that makes the rig worth maintaining.

With `-DprometheusPort` set on Mosaic (see `../netprobe/MOSAIC-SETUP.md`), the engine registers two
histograms **labelled by packet type _and_ client**:

```java
Histogram.builder().name("packet_send").unit(BYTES).labelNames("packetType", "client")
```
`StatisticManager.java:77-78`

They are fed from `NetworkStatistic.addOutcomePacket` / `addIncomePacket` (`:143` / `:129`) using
`connection.getUserName()`. And the send side is a genuine chokepoint: every variant —
`endPacket`, `endPacketImmediate`, `endPacketUnordered`, `endPacketUnreliable`,
`endPacketSuperHighUnreliable`, plus the ping buffer — funnels into the private
`endPacket` at `UdpConnection.java:295`, which observes at `:298` before the buffer is flipped.
**Nothing sends without being counted.**

Bots name themselves `String.format("Client%d", movement.id)` at :1700. So `Client0`…`Client13`
appear verbatim as label values, and you get true wire bytes per bot, per packet type, at whatever
resolution you scrape.

**Use it with RDWire, not instead of it.** The two are complementary and neither is sufficient:

| | Prometheus exporter | `RDWire.lua` |
|---|---|---|
| Accuracy | true wire bytes | estimate by construction (no engine API for real bytes) |
| Attribution | per engine packet type + per client | per mod / per call site |
| Blind spot | all mod traffic collapses into a couple of packet types — cannot name a mod | cannot tell you its share of the real total |

Run both in one window and they compose: Prometheus supplies the measured denominator, RDWire
splits the mod slice inside it. That is the path to promoting the wire3 finding
("PhunZones ≈63% of mod traffic") from an estimate to a measurement.

Bonus: the client exports too — `MainScreenState.java:279` also calls `StatisticManager.init()`, so
a **real** client launched with `-DprometheusPort=9092` reports its own view. That is how you do the
1:1 calibration in §6 without guessing.

---

## 6. Experiments worth running

Fix the scenario, change exactly one thing per run.

1. **Calibrate to 1:1.** One real client (with its own `-DprometheusPort`) beside one bot. Tune
   `player.fps` / `predict` until the bot's packet rate matches the human's. Only then does
   "14 bots" mean "14 players".
2. **Ramp N** — 2, 4, 8, 14, 20 co-located `Stay` bots. Plot bot count against per-client sent
   bytes. Linear is the healthy shape; a knee is the relay going quadratic.
3. **Mod bisection — the decisive one.** Same 14-bot scenario, run twice, with one mod removed from
   `MDS.ini` between runs. Diff per-client `packet_send_bytes`. This is the only technique that
   turns "mod X is N% of traffic" into "mod X *causes* the problem."
4. **Cluster vs spread** — 14 bots sharing one `spawn` versus 14 far apart with `type: Line`.
   Separates relevance-driven pile-up from raw packet count.
5. **Zombie load isolation** — `createHorde` bots with minimal movement, to price frame-step sim
   cost on its own.

---

## 7. Gotchas checklist

- [ ] Launch the bot JVM **from the PZ install dir** with its bundled `jre64` (natives + non-public `main`).
- [ ] `version` key present; its value is irrelevant. Missing key = zero bots, one error line.
- [ ] Server `DoLuaChecksum=false` **and** no `checksum` block in the JSON — they must agree. Mosaic: already false.
- [ ] Smoke-test with `-id=0` before running all 14.
- [ ] Bots appear in-world and in the DB as `Client0`…`ClientN`. Clean them up afterwards.
- [ ] Never point this at a world you care about.
- [ ] Loopback only exercises the CPU path — it will not reproduce real-internet loss or jitter.
- [ ] Kill orphaned bot JVMs between runs. A survivor holds port 17500 and the next run dies with
      `Network start failed: 5` (RakNet `SOCKET_PORT_ALREADY_IN_USE`), which names neither the port
      nor the process:
      `Get-Process java | Where-Object { $_.Path -like 'D:\Steam*' } | Stop-Process -Force`

## Error quick-reference

| Message | Means |
|---|---|
| `Could not find or load main class .awt.headless=true` | PowerShell split the `-D` arg — use `run-bots.ps1` |
| `Network start failed: 5` | Port 17500 held by an orphaned bot process |
| `Connection failed: 17` | Nothing answered at `serverHost:16261` — server down or wrong host |
| `Invalid scenarios file name` | `-scenarios=` missing or blank (:342) |
| `Scenarios file load failed` + zero bots | JSON invalid, or a required key (e.g. `version`) is absent |
| `Client kicked. Reason: ...` | Server rejected it; the reason is verbatim (:1155) |

---

*Reverse-engineered from the decompiled B42 engine 2026-07-05; re-verified line-by-line against
42.20 and extended with the per-client metrics path 2026-08-03. This is TIS's internal QA tool —
undocumented and unsupported; expect to iterate on the JSON.*
