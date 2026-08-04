# scrape-metrics.ps1 - snapshot PZ B42's built-in Prometheus endpoint through a test window.
#
# WHY THIS EXISTS: the engine is already the exporter (StatisticManager.java:68-90 starts a real
# /metrics HTTP server when -DprometheusPort is set), but Prometheus itself is a whole stack to
# stand up for what is usually a 20-minute experiment. This just walks the endpoint on a timer and
# writes the raw text, so the capture is a folder of files you can diff, archive, and re-analyse
# later without having kept any infrastructure alive.
#
# WHAT IT DOES NOT DO: it does not attribute anything. summary.csv is a health overview only.
# The per-client, per-packet-type attribution - the entire reason this tooling exists - lives in
# the .prom snapshots and is extracted by analyze-capture.py. Do not read summary.csv and think you
# have the answer.
#
# PREREQ: -DprometheusPort must be on the server JVM, and the port must be firewalled.
# See MOSAIC-SETUP.md - the endpoint binds all interfaces and publishes live player coordinates.
#
# Usage (on the box running the server; for Mosaic that is this machine):
#   .\scrape-metrics.ps1                                     # 9091, every 10s, 30 min
#   .\scrape-metrics.ps1 -IntervalSec 5 -DurationMin 60 -Label ramp-14bots
#
# -Label just names the output folder, so consecutive experiment runs do not overwrite each other.
# Use it. A bisection run is worthless if you cannot tell the two captures apart afterwards.

param(
    [int]$Port        = 9091,
    [int]$IntervalSec = 10,
    [int]$DurationMin = 30,
    [string]$Label    = "capture",
    [string]$OutRoot
)

$ErrorActionPreference = 'Stop'

# Resolved here, not as a param default: $PSScriptRoot is not populated while param defaults are
# evaluated under -File, which would silently write captures to "\captures" (i.e. C:\captures)
# instead of next to this script.
if (-not $OutRoot) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $OutRoot = Join-Path $here 'captures'
}

# Fail loud and immediately if the endpoint is not there, rather than after 30 minutes of
# writing nothing useful. Checked BEFORE creating the output folder, so a failed start does not
# litter captures/ with empty directories you later mistake for real runs.
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/metrics" -UseBasicParsing -TimeoutSec 5
} catch {
    Write-Host "XX  No /metrics on 127.0.0.1:$Port - is -DprometheusPort=$Port on the server JVM?" -ForegroundColor Red
    Write-Host "    Check:  Get-CimInstance Win32_Process -Filter `"Name='java.exe'`" | Select CommandLine"
    Write-Host "    Setup:  see MOSAIC-SETUP.md"
    exit 1
}

$stamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$OutDir = Join-Path $OutRoot "${stamp}_$Label"
New-Item -ItemType Directory -Force $OutDir | Out-Null

$csv = Join-Path $OutDir "summary.csv"
"timestamp,update_ms,avg_update_ms,max_update_ms,players,zombies_loaded,zombies_simulated,zombies_culled,zombies_total,loaded_cells,heap_used_mb,resend_buffer_bytes,recv_bytes_total,sent_bytes_total" |
    Out-File $csv -Encoding utf8

function Get-Val([string[]]$lines, [string]$pattern) {
    $line = $lines | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if ($line -and $line -match '([\d\.E\-+]+)\s*$') { return $Matches[1] }
    return ""
}

function Get-SeriesSum([string[]]$lines, [string]$prefix) {
    ($lines | Where-Object { $_.StartsWith($prefix) } |
        ForEach-Object { if ($_ -match '([\d\.E+\-]+)\s*$') { [double]$Matches[1] } } |
        Measure-Object -Sum).Sum
}

Write-Host "==> Capturing to $OutDir"
Write-Host "    every ${IntervalSec}s for ${DurationMin}min. Ctrl-C stops early; partial data is still usable."

$deadline = (Get-Date).AddMinutes($DurationMin)
$n = 0
while ((Get-Date) -lt $deadline) {
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    try {
        $body = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/metrics" -UseBasicParsing -TimeoutSec 8).Content
        $body | Out-File (Join-Path $OutDir "$ts.prom") -Encoding utf8
        $lines = $body -split "`n"

        $row = @(
            $ts
            Get-Val $lines '^performance\{parameter="fps"\}'                 # update cycle duration, ms
            Get-Val $lines '^performance\{parameter="avg-update-period"\}'
            Get-Val $lines '^performance\{parameter="max-update-period"\}'
            Get-Val $lines '^game\{parameter="players"\}'
            Get-Val $lines '^game\{parameter="zombies-loaded"\}'
            Get-Val $lines '^game\{parameter="zombies-simulated"\}'
            Get-Val $lines '^game\{parameter="zombies-culled"\}'
            Get-Val $lines '^game\{parameter="zombies-total"\}'
            Get-Val $lines '^game\{parameter="loaded-cells"\}'
            Get-Val $lines '^performance\{parameter="memory-used"\}'
            Get-Val $lines '^network\{parameter="bytes-in-resend-buffer"\}'
            Get-SeriesSum $lines 'packet_receive_bytes_sum'
            Get-SeriesSum $lines 'packet_send_bytes_sum'
        ) -join ","
        Add-Content $csv $row
        $n++
        Write-Host "$ts  captured ($n)"
    } catch {
        Write-Host "$ts  scrape failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $IntervalSec
}

Write-Host "`nOK  $n snapshots in $OutDir" -ForegroundColor Green
Write-Host "    Now attribute it:"
Write-Host "      python `"$PSScriptRoot\analyze-capture.py`" `"$OutDir`""
