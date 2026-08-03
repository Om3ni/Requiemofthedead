<#
.SYNOPSIS
    Start Mosaic, win the Steam clobber race, then launch the client in debug.

.DESCRIPTION
    The problem this exists to solve:

    The dedi's mod tree at
        C:\Mosaic\ProjectZomboidDedicatedServer\steamapps\workshop\content\108600\3772176444
    is a REAL DIRECTORY, not a junction, and MDS.ini carries
    WorkshopItems=3772176444. So every launch, Steam validates that workshop
    item and rewrites the tree with the PUBLISHED build - silently reverting
    whatever sync-trees.ps1 last pushed there.

    Evidence (2026-08-02): appworkshop_108600.acf stamped 23:43:55, the server
    JVM started 23:44:01. The clobber lands SIX SECONDS BEFORE the JVM, as part
    of launch, not during it.

    That ordering is what makes this scriptable. The window we need is:
        after Steam has finished        (so it cannot overwrite us)
        after the JVM is alive          (a reliable "Steam is done" signal)
        before the server scans mods    (so our Lua is what actually loads)
    which is exactly "the moment java appears". The mod scan is many seconds of
    boot work later, so the race is comfortable rather than tight.

    Syncing AFTER '*** SERVER STARTED ****' does NOT work and is the trap this
    script exists to stop you falling into: by then the Lua is already loaded,
    so the files would be correct on disk and stale in memory - and brand new
    files (RCFleet.lua, RCPartsView.lua) would not be loaded at all.

    The run finishes with a VERIFY pass. If drift reappears after boot, Steam
    touched the tree a second time and the sync-then-start assumption is wrong
    for that run - so it says so loudly rather than leaving you to discover it
    by testing published code and wondering why nothing changed.

.PARAMETER Restart
    Stop a server that is already running before starting a new one. Without
    this, an already-running server is left alone (and the sync still runs, so
    you can /reloadlua into it).

.PARAMETER NoClient
    Skip launching the game client.

.PARAMETER NoSync
    Skip the sync entirely - just start and wait.

.PARAMETER TimeoutSec
    How long to wait for '*** SERVER STARTED ****'. Mosaic's boot is slow; the
    default is deliberately generous.

.EXAMPLE
    .\tools\launch-mosaic.ps1
    .\tools\launch-mosaic.ps1 -Restart
    .\tools\launch-mosaic.ps1 -NoClient
#>
[CmdletBinding()]
param(
    [switch] $Restart,
    [switch] $NoClient,
    [switch] $NoSync,
    [int]    $TimeoutSec = 420,
    [string] $Launcher   = 'C:\Mosaic\Mosaic.exe',
    [string] $ServerRoot = 'C:\Mosaic\ProjectZomboidDedicatedServer',
    [string] $Console    = 'C:\Mosaic\pzdata\server-console.txt',
    [string] $ClientExe  = 'D:\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe'
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$syncPath = Join-Path $PSScriptRoot 'sync-trees.ps1'
$READY    = '*** SERVER STARTED ****'

function Say  ($m) { Write-Host $m }
function Step ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Good ($m) { Write-Host "OK  $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "XX  $m" -ForegroundColor Red }

# The server JVM, identified by living under the dedi root - so a random other
# java process on the machine can never be mistaken for it.
function Get-ServerProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($ServerRoot, 'OrdinalIgnoreCase') } |
        Select-Object -First 1
}

foreach ($p in @($Launcher, $syncPath)) {
    if (-not (Test-Path $p)) { Bad "not found: $p"; exit 1 }
}

# ---------------------------------------------------------------------------
# 1. Existing server
# ---------------------------------------------------------------------------
$existing = Get-ServerProcess
if ($existing -and -not $Restart) {
    Step "Server already running (pid $($existing.ProcessId)) - leaving it alone."
    Warn "Its Lua is ALREADY LOADED. A sync now needs /reloadlua per changed file,"
    Warn "and any brand-new file will not load at all until a real restart."
    $skipStart = $true
}
elseif ($existing -and $Restart) {
    Step "Stopping server (pid $($existing.ProcessId))"
    Stop-Process -Id $existing.ProcessId -Force
    $waited = 0
    while ((Get-ServerProcess) -and $waited -lt 60) { Start-Sleep -Seconds 1; $waited++ }
    if (Get-ServerProcess) { Bad "server would not stop"; exit 1 }
    Good "stopped"
    $skipStart = $false
}
else { $skipStart = $false }

# Remember where the console log ends now, so we only ever read THIS run's
# output. Without this a stale '*** SERVER STARTED ****' from the previous run
# satisfies the wait instantly and everything downstream fires too early.
$consoleOffset = 0
if (Test-Path $Console) { $consoleOffset = (Get-Item $Console).Length }

# ---------------------------------------------------------------------------
# 2. Launch
# ---------------------------------------------------------------------------
if (-not $skipStart) {
    Step "Launching $Launcher"
    Start-Process -FilePath $Launcher -WorkingDirectory (Split-Path -Parent $Launcher) | Out-Null

    Step "Waiting for the server JVM (this is the 'Steam is finished' signal)"
    $waited = 0
    while (-not (Get-ServerProcess) -and $waited -lt 180) { Start-Sleep -Seconds 1; $waited++ }
    $proc = Get-ServerProcess
    if (-not $proc) { Bad "server JVM never appeared after ${waited}s"; exit 1 }
    Good "JVM up (pid $($proc.ProcessId)) after ${waited}s"
}

# ---------------------------------------------------------------------------
# 3. Sync - the whole point of the timing above
# ---------------------------------------------------------------------------
if (-not $NoSync) {
    Step "Syncing repo -> trees (before the server scans mods)"
    & $syncPath -Lua
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { Warn "sync exited $LASTEXITCODE" }
    else { Good "sync applied" }
}
else { Warn "sync skipped (-NoSync)" }

# ---------------------------------------------------------------------------
# 4. Wait for ready
# ---------------------------------------------------------------------------
if (-not $skipStart) {
    Step "Waiting for '$READY' (timeout ${TimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ready    = $false
    $lastNote = Get-Date

    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ServerProcess)) { Bad "server JVM exited during boot - check $Console"; exit 1 }

        if (Test-Path $Console) {
            $len = (Get-Item $Console).Length
            # The log is rewritten per run on some launches; if it shrank, our
            # saved offset points past the end and we would read nothing.
            if ($len -lt $consoleOffset) { $consoleOffset = 0 }
            if ($len -gt $consoleOffset) {
                $fs = [System.IO.File]::Open($Console, 'Open', 'Read', 'ReadWrite')
                try {
                    $fs.Seek($consoleOffset, 'Begin') | Out-Null
                    $buf = New-Object byte[] ($len - $consoleOffset)
                    $read = $fs.Read($buf, 0, $buf.Length)
                    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                } finally { $fs.Dispose() }
                if ($text -like "*$READY*") { $ready = $true; break }
                $consoleOffset = $len
            }
        }

        if (((Get-Date) - $lastNote).TotalSeconds -ge 30) {
            Say ("    still booting... {0}s elapsed" -f [int]((Get-Date) - $deadline.AddSeconds(-$TimeoutSec)).TotalSeconds)
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 2
    }

    if (-not $ready) { Bad "timed out waiting for the server to report ready"; exit 1 }
    Good "server started"
}

# ---------------------------------------------------------------------------
# 5. Verify - did Steam touch the tree a second time?
# ---------------------------------------------------------------------------
if (-not $NoSync) {
    Step "Verifying the tree survived boot"
    $out = & $syncPath -DryRun -Lua 2>&1 | Out-String
    # sync-trees reports per-file lines only when something differs.
    if ($out -match 'Older|Newer|New File') {
        Bad "DRIFT AFTER BOOT - Steam rewrote the tree again."
        Bad "The running server is NOT on your code. Re-run with -Restart, or"
        Bad "drop WorkshopItems=3772176444 from MDS.ini to stop the validation."
        Say $out
    }
    else { Good "tree matches the repo - the server is running your code" }
}

# ---------------------------------------------------------------------------
# 6. Client
# ---------------------------------------------------------------------------
if (-not $NoClient) {
    if (-not (Test-Path $ClientExe)) { Warn "client not found: $ClientExe" }
    else {
        Step "Launching client (-debug)"
        Start-Process -FilePath $ClientExe -ArgumentList '-debug' `
            -WorkingDirectory (Split-Path -Parent $ClientExe) | Out-Null
        Good "client launched"
    }
}

Step "Done."
