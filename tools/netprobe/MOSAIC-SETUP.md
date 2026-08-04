# Turning on the engine's metrics endpoint for Mosaic

**Goal:** get `http://127.0.0.1:9091/metrics` serving on the Mosaic dedi so `scrape-metrics.ps1`
and `analyze-capture.py` can attribute traffic per client. No engine files modified, no mods
touched, no save-data risk. One JVM flag and one firewall rule.

Everything here is reversible in under a minute.

---

## What you already have

Checked against the live server on 2026-08-03 (`Get-CimInstance Win32_Process`):

```
C:\Mosaic\ProjectZomboidDedicatedServer\jre64\bin\java.exe
  -Djava.awt.headless=true -Dzomboid.steam=1 -Dzomboid.znetlog=1
  -XX:+UseZGC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow
  -Xms16g -Xmx16g -Djava.library.path=natives/
  -cp java/;java/projectzomboid.jar zombie.network.GameServer
  -statistic 0 -adminusername Omen -adminpassword admin -servername MDS -cachedir=C:\Mosaic\pzdata
```

No `-DprometheusPort`, so the exporter is dormant. `MDS.ini` already has
`MultiplayerStatisticsPeriod=1`, which is the gauge refresh cadence
(`StatisticManager.java:121`) — nothing to change there.

**The awkward part:** Mosaic builds that command line itself. `ProjectZomboid64.json` has a
`vmArgs` array but the running process does not match it (`-Xms16g` vs the JSON's `-Xmx3072m`), so
editing the JSON does nothing. `StartServer64.bat` matches the JVM flags exactly but ends in
`%1 %2` — only two passthrough args, and Mosaic passes four. So neither file is authoritative.

That leaves two routes.

---

## Route A — `_JAVA_OPTIONS` (recommended; no Mosaic internals needed)

The JVM reads `_JAVA_OPTIONS` from the environment and prepends it to any command line, whoever
built it. Scope it to the shell that launches Mosaic and it reaches the server and nothing else.

```powershell
$env:_JAVA_OPTIONS = '-DprometheusPort=9091'
Start-Process 'C:\Mosaic\Mosaic.exe' -WorkingDirectory 'C:\Mosaic'
```

Or with the repo's launcher — **note `-NoClient`, it is not optional here**:

```powershell
$env:_JAVA_OPTIONS = '-DprometheusPort=9091'
.\tools\launch-mosaic.ps1 -Restart -NoClient
```

> ### Why `-NoClient` matters
> The game client also calls `StatisticManager.init()` (`MainScreenState.java:279`), so a client
> that inherits this variable tries to bind the **same port**. `buildAndStart()` throws `IOException`
> when the port is taken, and `init()` rethrows it as an unchecked `RuntimeException`
> (`StatisticManager.java:83-88`) — **the client dies on startup**, with a stack trace that looks
> nothing like a port conflict.
>
> `launch-mosaic.ps1` starts the client from the same shell as the server, so it would inherit.
> Launch the client from a separate shell, or give it its own port:
> `$env:_JAVA_OPTIONS = '-DprometheusPort=9092'` — which is worth doing anyway, since a real
> client's own metrics are how you calibrate one bot against one human.
>
> Do **not** set this system-wide in `sysdm.cpl`. Every Java process you own would inherit it and
> the second one to start would crash.

---

## Route B — launch the dedi directly, bypassing Mosaic

Useful when you want the experiment fully under your control. Steam never runs, so the workshop
clobber that `launch-mosaic.ps1` exists to dodge cannot happen — the repo tree stays put.

```powershell
cd C:\Mosaic\ProjectZomboidDedicatedServer
.\jre64\bin\java.exe -Djava.awt.headless=true -Dzomboid.steam=1 -Dzomboid.znetlog=1 `
  -DprometheusPort=9091 `
  -XX:+UseZGC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow `
  -Xms16g -Xmx16g -Djava.library.path=natives/ `
  -cp "java/;java/projectzomboid.jar" zombie.network.GameServer `
  -statistic 0 -adminusername Omen -adminpassword admin -servername MDS -cachedir=C:\Mosaic\pzdata
```

Trade-off: you own restarts, and Mosaic's supervision is out of the loop for that session.

---

## Firewall it FIRST — before the flag ever goes live

The exporter binds without an explicit host, and `-DprometheusHost` only changes the *advertised*
instance name (`StatisticManager.java:94-100`), not the bind. Treat the port as fully exposed. It
publishes **player usernames and live world coordinates** (`playerX/playerY/playerLon/playerLat`,
`:79-82`, refreshed every second).

Admin PowerShell:

```powershell
New-NetFirewallRule -DisplayName "PZ metrics 9091 block external" `
  -Direction Inbound -LocalPort 9091 -Protocol TCP -Action Block
```

Windows Firewall does not filter loopback, so the local scraper keeps working.

---

## Verify

After restarting the server:

```powershell
netstat -ano | Select-String ':9091'                       # must show LISTENING
curl.exe -s http://127.0.0.1:9091/metrics | Select-Object -First 5   # must print "# HELP jvm_..."
```

The console log also carries, near boot:
`Prometheus HTTPServer listening on port http://localhost:9091/metrics` (`StatisticManager.java:89`).

Confirm the per-client labels are actually populating — this is the whole point:

```powershell
curl.exe -s http://127.0.0.1:9091/metrics | Select-String 'packet_send_bytes_sum' | Select-Object -First 5
```

You want lines shaped like:
`packet_send_bytes_sum{packetType="PlayerUpdateReliable",client="Omen"} 1.234567E7`

If `client=""` on everything, no one is logged in yet — connect once and re-check.

---

## Capture and attribute

```powershell
# baseline: real players only, no bots
.\tools\netprobe\scrape-metrics.ps1 -DurationMin 30 -Label baseline

# then the bots (see ../fakeclient/RUNBOOK.md)
.\tools\netprobe\scrape-metrics.ps1 -DurationMin 30 -Label bots-14

python .\tools\netprobe\analyze-capture.py .\tools\netprobe\captures\<stamp>_bots-14
```

The analyzer prints a per-client table and writes a self-contained `report.html` next to the
snapshots. Bots show up as `Client0`…`Client13`.

---

## Rollback

- **Flag:** close the shell, or `Remove-Item Env:\_JAVA_OPTIONS`; takes effect next restart. Leaving
  it on long-term is harmless — the per-username label set grows the metric count slightly, which is
  irrelevant at 32 players.
- **Firewall rule:** `Remove-NetFirewallRule -DisplayName "PZ metrics 9091 block external"`
- **Captures:** `tools/netprobe/captures/` is gitignored; delete whenever.

---

## The permanent fix

Mosaic owns the java command line, so the right long-term home for this is Mosaic itself — the
`mosaic-serve-roadmap.md` S-P slice already plans a `prometheusPort` config toggle plus write-only
passthrough for `-DlokiUrl`/`-DlokiUser`/`-DlokiPass`. Until that lands, Route A is the zero-change
workaround.

Worth knowing for later: the same engine ships **Loki** log shipping via TinyLoki
(`DebugLog.java:417-423`). Set `-DlokiUrl` and the server pushes its whole debug log to a Grafana
stack, labelled `service_name=pz.server` with `instance` matching the metrics. Metrics and logs were
designed as a pair. That needs a Grafana stack standing up, so it is a later step, not this one.
