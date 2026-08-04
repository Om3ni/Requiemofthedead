<#
.SYNOPSIS
    Launch FakeClientManager bots against a server.

.DESCRIPTION
    This exists because the raw java command line does not survive being pasted into PowerShell.

    In argument mode PowerShell mangles unquoted -D properties containing dots: it splits
    -Djava.awt.headless=true into "-Djava" and ".awt.headless=true", so java takes the second
    fragment as the main class and dies with

        Error: Could not find or load main class .awt.headless=true

    which looks like a classpath problem and is not one. The library path and classpath have the
    same hazard for a different reason - both contain ';', which PowerShell reads as a statement
    separator unless quoted.

    Every argument here is single-quoted and passed as one array element, which is the only form
    that reliably survives. Use this instead of pasting.

.PARAMETER Id
    Run only this movement id, on port 17500+Id. Omit to run every bot in the scenario.
    Always smoke-test with -Id 0 before running the full set.

.PARAMETER Scenario
    Scenario JSON. Defaults to scenario-14bots.json next to this script.

.PARAMETER PZ
    Project Zomboid install to borrow the engine and natives from. The bot sends THIS install's
    version at login (FakeClientManager.java:58, :790) and the server rejects a mismatch
    (LoginPacket.java:46-51), so it must match the server's build.

.PARAMETER HeapGB
    Max heap. Bots are tiny - measured ~80 MB working set for all 14 - so 2 is generous.

.EXAMPLE
    .\run-bots.ps1 -Id 0        # smoke test: one bot
    .\run-bots.ps1              # all 14
#>
[CmdletBinding()]
param(
    [int]    $Id       = -1,
    [string] $Scenario,
    [string] $PZ       = 'D:\Steam\steamapps\common\ProjectZomboid',
    [int]    $HeapGB   = 2
)

$ErrorActionPreference = 'Stop'

# Resolved here, not as a param default: $PSScriptRoot is not populated while param defaults are
# being evaluated under -File, which silently yields "\scenario-14bots.json" and a confusing
# not-found on a path that looks almost right.
if (-not $Scenario) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Scenario = Join-Path $here 'scenario-14bots.json'
}

foreach ($p in @($PZ, $Scenario, "$PZ\jre64\bin\java.exe", "$PZ\projectzomboid.jar")) {
    if (-not (Test-Path $p)) { Write-Host "XX  not found: $p" -ForegroundColor Red; exit 1 }
}

# Read the scenario's target so the operator can see where this is pointing BEFORE it connects.
# A bot run aimed at the wrong host is the kind of mistake you only notice an hour later.
try {
    $cfg  = Get-Content $Scenario -Raw | ConvertFrom-Json
    $host_ = $cfg.config.client.connection.serverHost
    if (-not $host_) { $host_ = '127.0.0.1 (default)' }
    $count = @($cfg.movements).Count
} catch {
    Write-Host "XX  scenario is not valid JSON: $Scenario" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)"
    exit 1
}

# Clear orphaned bot JVMs. A survivor from a previous run still holds UDP 17500 and this run dies
# with "Network start failed: 5" - RakNet's SOCKET_PORT_ALREADY_IN_USE, which names neither the
# port nor the offending process. Matching on the install path means a running GAME client is never
# caught by this (it is ProjectZomboid64.exe, not java.exe).
$orphans = @(Get-Process java -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($PZ, 'OrdinalIgnoreCase') })
if ($orphans.Count) {
    Write-Host ("  clearing {0} orphaned bot process(es) holding port 17500" -f $orphans.Count) -ForegroundColor Yellow
    $orphans | Stop-Process -Force
    Start-Sleep -Seconds 2
}

$which = if ($Id -ge 0) { "bot id $Id only" } else { "all $count bots" }
Write-Host "==> $which -> $host_`:16261" -ForegroundColor Cyan
Write-Host "    scenario: $Scenario"
Write-Host "    engine  : $PZ"
Write-Host "    Ctrl-C to stop.`n"

$javaArgs = @(
    '-Djava.awt.headless=true'
    '--enable-native-access=ALL-UNNAMED'
    '--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED'
    "-Xmx${HeapGB}g"
    '-Djava.library.path=./win64/;./'
    '-cp'
    './;projectzomboid.jar'
    'zombie.network.FakeClientManager'
    "-scenarios=$Scenario"
)
if ($Id -ge 0) { $javaArgs += "-id=$Id" }

# Must run from the install dir so the relative classpath and natives resolve.
Push-Location $PZ
try {
    & "$PZ\jre64\bin\java.exe" @javaArgs
} finally {
    Pop-Location
}
