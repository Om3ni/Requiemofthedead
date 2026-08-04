<#
.SYNOPSIS
    Wait for the engine's Prometheus endpoint and report what it is serving.

.DESCRIPTION
    Split out of 1-START-SERVER.bat on purpose. Doing this as an inline
    `powershell -Command` block inside a .bat means carets, nested quotes and
    escaped pipes, and it fails silently by hanging rather than erroring - which
    is the worst possible behaviour for the one step that tells you whether the
    whole setup worked. A real script file has none of those problems.

.PARAMETER Port
    Metrics port. Must match -DprometheusPort on the server JVM.

.PARAMETER TimeoutSec
    How long to keep trying. The endpoint comes up during StatisticManager.init()
    (GameServer.java:1414), which is late in boot, so give it room.
#>
[CmdletBinding()]
param(
    [int] $Port       = 9091,
    [int] $TimeoutSec = 60
)

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$body     = $null

while ((Get-Date) -lt $deadline) {
    try {
        $body = (Invoke-WebRequest "http://127.0.0.1:$Port/metrics" -UseBasicParsing -TimeoutSec 3).Content
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}

if (-not $body) {
    Write-Host ""
    Write-Host "  XX  no /metrics on port $Port after ${TimeoutSec}s" -ForegroundColor Red
    Write-Host ""
    Write-Host "  The server is up but the exporter never started, which means the JVM"
    Write-Host "  did not receive -DprometheusPort. Check what actually launched:"
    Write-Host ""
    Write-Host '      Get-CimInstance Win32_Process -Filter "Name=''java.exe''" | Select -Expand CommandLine'
    Write-Host ""
    Write-Host "  _JAVA_OPTIONS does not appear in that command line even when it worked -"
    Write-Host "  the JVM prints 'Picked up _JAVA_OPTIONS' to the console instead. If it is"
    Write-Host "  genuinely absent, see MOSAIC-SETUP.md Route B (launch the dedi directly)."
    exit 1
}

$lines = $body -split "`n"
$sendSeries = @($lines | Where-Object { $_.StartsWith('packet_send_bytes_sum') }).Count
$clients = @(
    $lines |
        Where-Object { $_.StartsWith('packet_send_bytes_sum') } |
        ForEach-Object { if ($_ -match 'client="([^"]*)"') { $Matches[1] } } |
        Where-Object { $_ } |
        Sort-Object -Unique
)

Write-Host ""
Write-Host "  OK  /metrics is live on port $Port" -ForegroundColor Green
Write-Host ("      {0:N0} bytes, {1} packet_send series" -f $body.Length, $sendSeries)

if ($clients.Count) {
    Write-Host ("      clients seen: {0}" -f ($clients -join ', ')) -ForegroundColor Green
} else {
    Write-Host "      no client series yet - normal until someone (or a bot) logs in" -ForegroundColor Yellow
}

exit 0
