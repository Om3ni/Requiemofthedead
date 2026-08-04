# First run — from everything closed to a per-client traffic report

Starting state this assumes: **Mosaic stopped, game client closed.** That is the ideal state; you
have the whole machine free.

## Just use the batch files

Double-click them in order. Each opens its own window and tells you what to do next.

| | | |
|---|---|---|
| `1-START-SERVER.bat` | window 1 | sets `_JAVA_OPTIONS`, restarts Mosaic with `-NoClient`, verifies `/metrics` |
| `2-START-CAPTURE.bat` | window 2 | snapshots the endpoint for 15 min. Optional arg = label |
| `3-START-BOTS.bat 0` | window 3 | **smoke test, one bot** — do this first |
| `3-START-BOTS.bat` | window 3 | all 14 |
| `4-ANALYZE.bat` | anywhere | analyses the newest capture, writes `report.html` |

Windows 2 and 3 run at the same time — that is the point. Window 1 stays open holding the server.

The rest of this document is the same thing done by hand, plus the reasoning and the failure modes.
Read it when something goes wrong.

---

You will need **two PowerShell windows**. Call them A (server + capture) and B (bots).
Do the steps in order. Each one says what you should see.

Total hands-on time: about 5 minutes, then a 10-minute wait.

---

## Step 0 — one-time only: firewall the metrics port

Skip if you have done this before. **Admin** PowerShell:

```powershell
New-NetFirewallRule -DisplayName "PZ metrics 9091 block external" `
  -Direction Inbound -LocalPort 9091 -Protocol TCP -Action Block
```

Why: the exporter binds every interface and publishes usernames and live world coordinates.
`-DprometheusHost` does **not** change the bind — it only relabels the instance name
(`StatisticManager.java:94-100`). Loopback is not filtered, so the local scraper still works.

---

## Step 1 — Window A: start Mosaic with metrics on

The environment variable must be set in the **same window** that launches Mosaic. That is the whole
trick: Mosaic builds the java command line itself, but the JVM reads `_JAVA_OPTIONS` from the
environment no matter who built the line.

```powershell
cd C:\VSCodeProjects\RequiemoftheDead
$env:_JAVA_OPTIONS = '-DprometheusPort=9091'
.\tools\launch-mosaic.ps1 -Restart -NoClient
```

**`-NoClient` is not optional.** The game client calls the same `StatisticManager.init()`
(`MainScreenState.java:279`); if it inherits this variable it tries to bind the same port,
`buildAndStart()` throws `IOException`, and `init()` rethrows it unchecked
(`StatisticManager.java:83-88`) — the client dies at startup with a trace that looks nothing like a
port conflict.

Expect: the usual sync-then-start output, ending in `OK  server started` and
`OK  tree matches the repo`.

You should also see, early in the boot spam, `Picked up _JAVA_OPTIONS: -DprometheusPort=9091`.

---

## Step 2 — Window A: verify the endpoint before doing anything else

```powershell
curl.exe -s http://127.0.0.1:9091/metrics | Select-String 'packet_send_bytes_sum' | Select-Object -First 3
```

**Good:** lines shaped like
`packet_send_bytes_sum{packetType="PlayerUpdateReliable",client="Omen"} 1.234E7`

**Empty result:** nobody is connected yet — that is fine at this stage, the histograms have no
series until someone logs in. Confirm the endpoint exists at all:

```powershell
curl.exe -s http://127.0.0.1:9091/metrics | Select-Object -First 3    # want "# HELP jvm_..."
netstat -ano | Select-String ':9091'                                   # want LISTENING
```

**Nothing at all:** the variable did not reach the JVM. Check what actually launched:

```powershell
Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Select-Object -Expand CommandLine
```

If `-DprometheusPort` is absent, fall back to Route B in `MOSAIC-SETUP.md` (launch the dedi
directly). Do not continue until this step passes — everything downstream depends on it.

---

## Step 3 — Window A: start the capture

```powershell
cd C:\VSCodeProjects\RequiemoftheDead
.\tools\netprobe\scrape-metrics.ps1 -DurationMin 15 -Label bots-14
```

It prints one line per snapshot. Leave this window alone from here.

If it exits immediately with `XX  No /metrics on 127.0.0.1:9091`, go back to step 2.

---

## Step 4 — Window B: smoke-test ONE bot first

Do not launch 14 straight away. One bot proves the login path works — in particular that Steam mode
(`-Dzomboid.steam=1`, `SteamVAC=true`) does not reject a non-Steam RakNet client. That is the one
thing in this whole setup that is a code reading rather than an observation.

```powershell
cd C:\VSCodeProjects\RequiemoftheDead
.\tools\fakeclient\run-bots.ps1 -Id 0
```

> Use the script, not a raw java command line. PowerShell mangles unquoted `-D` properties that
> contain dots — it splits `-Djava.awt.headless=true` into `-Djava` and `.awt.headless=true`, and
> java then reports `Could not find or load main class .awt.headless=true`, which looks like a
> classpath fault and is not one. The classpath and library path have the same problem for a
> different reason: both contain `;`, a PowerShell statement separator. `run-bots.ps1` quotes
> everything correctly.

It prints where it is pointing before it connects:

```
==> bot id 0 only -> 127.0.0.1:16261
 INFO : 13:30:43.273 , [ 0] > Start client (0) 0.0.0.0:17500 => 127.0.0.1:16261 / "bot00"
```

**Good:** within ~15s, `INFO ... Player   N connect in X.XXXs`.

**`Connection failed: 17`:** nothing answered. The server is not up — go back to step 1.

**`Network start failed: 5`:** RakNet `SOCKET_PORT_ALREADY_IN_USE` — an earlier bot process is
still alive holding port 17500. Kill it:

```powershell
Get-Process java | Where-Object { $_.Path -like 'D:\Steam*' } | Stop-Process -Force
```

**Kicked:** the reason is printed verbatim (`receiveKicked`, :1155) — version mismatch, checksum,
full, banned. Read it; it names the problem.

Confirm from the server side too — in a third window, or just check the log afterwards:

```powershell
Select-String 'Client0' C:\Mosaic\pzdata\Logs\*_user.txt | Select-Object -Last 3
```

Then **Ctrl-C** to stop the single bot.

---

## Step 5 — Window B: run all 14

Same command, **drop `-Id 0`**:

```powershell
.\tools\fakeclient\run-bots.ps1
```

They join staggered ~1.5s apart, so all 14 are in after ~21 seconds. Measured cost: ~80 MB working
set and roughly 7% of one core for the whole process.

**Let it run ~10 minutes.** You want enough counter movement that the deltas are not noise.

---

## Step 6 — stop, in this order

1. **Window B: Ctrl-C** — stops the bots.
2. **Window A:** let the scraper finish, or Ctrl-C it. Partial captures analyse fine.

---

## Step 7 — get the answer

```powershell
cd C:\VSCodeProjects\RequiemoftheDead
python .\tools\netprobe\analyze-capture.py (Get-ChildItem .\tools\netprobe\captures | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
```

Prints a per-client table and a per-packet-type table, and writes `report.html` into the capture
folder. `Client0`…`Client13` are the bots.

**What to look for:**

- One client far above the others → something is per-player and not scaling the way you assumed.
- One packet type dominating → that is your traffic, and its name tells you which subsystem.
- `Client13` (the chatter bot) heavier than the rest → something is hooking chat and broadcasting.

---

## Cleanup

The bots leave `Client0`…`Client13` characters in the world and the DB. Harmless, but tidy them
when you are done experimenting. `tools/netprobe/captures/` is gitignored; delete captures freely.

To turn metrics back off: close Window A, or `Remove-Item Env:\_JAVA_OPTIONS`, then restart Mosaic
normally. Leaving it on is harmless.

---

## The comparison run (this is where the real answers are)

One capture tells you the shape. **Two captures tell you the cause.** Repeat steps 1-7 with exactly
one thing changed — a mod removed from `MDS.ini`, or 7 bots instead of 14 — and diff the two
`report.html` files. That is the difference between "PlayerUpdate is 80% of traffic" and "mod X is
what makes PlayerUpdate 80% of traffic."

Use `-Label` to keep the runs apart. You will not remember which folder was which tomorrow.
