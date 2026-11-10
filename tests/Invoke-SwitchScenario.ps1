<#
.SYNOPSIS
    Runs one mocked switching scenario against the real logic of poc/Switch-Adapter.ps1.

.DESCRIPTION
    SAFE: reads and changes no real device and needs no administrator rights.
    The script's own statements are executed with three functions replaced
    (Find-Adapter, Test-Elevated, Get-PnputilPath), so every pnputil call goes to
    tests/mock/fake-pnputil.ps1, which keeps simulated device state in memory.

    Run each scenario in its own PowerShell process (Run-Tests.ps1 does this),
    because some scenarios stop the pipeline on purpose.

    Prints the script's log followed by one line starting with RESULT and ending
    in PASS or FAIL.
#>
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$ScriptPath
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside a param() default in Windows PowerShell 5.1 when
# another parameter is mandatory, so the default is resolved here instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptPath) { $ScriptPath = Join-Path $here '..\poc\Switch-Adapter.ps1' }
$SRC = 'USB\VID_33FA&PID_0012\SIM&EXT'          # simulated external adapter, starts active
$DST = 'USB\VID_0489&PID_E139&MI_00\SIM&INT'    # simulated internal adapter, starts disabled

$global:Sim = @{
    Status = [ordered]@{ $DST = 'Disabled'; $SRC = 'Started' }; Enum = $true
    Reads = 0; Pending = @(); Commands = @(); Violations = @()
    StopDelayReads = 2; StartDelayReads = 3; StartDelayFor = @{}
    StopOnRead = @(); GarbageOnRead = @(); FailOnRead = @()
    DisableExit = @{}; EnableExit = @{}; NeverStops = @(); NeverStarts = @()
}
$Target = 'Upstairs'
$expect = @{ Exit = 0; Src = 'Disabled'; Dst = 'Started'; Commands = 2 }

# The pre-checks make 2 state reads, so read 3 is the first poll after the disable
# and read 7 falls in the wait for the target to start.
switch ($Scenario) {
    'happy'               { }
    'stop-in-step2'       { $Sim.StopOnRead = @(3);    $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 2 } }
    'stop-in-step4'       { $Sim.StopOnRead = @(7);    $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 4 } }
    'stop-twice'          { $Sim.StopOnRead = @(3, 4); $expect = @{ Exit = 3; Src = $null; Dst = $null; Commands = $null } }
    'target-never-starts' { $Sim.NeverStarts = @($DST);             $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 4 } }
    'target-slow-start'   { $Sim.StartDelayFor[$DST] = 100000;      $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 4 } }
    'target-wont-disable' { $Sim.NeverStarts = @($DST); $Sim.DisableExit[$DST] = 5; $expect = @{ Exit = 3; Src = 'Disabled'; Dst = 'Problem'; Commands = 3 } }
    'disable-refused'     { $Sim.DisableExit[$SRC] = 5;             $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 1 } }
    'source-never-stops'  { $Sim.NeverStops = @($SRC);              $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 1 } }
    'rollback-fails'      { $Sim.NeverStarts = @($DST, $SRC);       $expect = @{ Exit = 3; Src = 'Problem'; Dst = 'Disabled'; Commands = 4 } }
    'unreadable-polls'    { $Sim.GarbageOnRead = @(3); $Sim.FailOnRead = @(4) }
    'already-on-target'   { $Target = 'Downstairs';                 $expect = @{ Exit = 0; Src = 'Started'; Dst = 'Disabled'; Commands = 0 } }
    'both-disabled'       { $Sim.Status[$SRC] = 'Disabled'; $Sim.Enum = $false; $expect = @{ Exit = 1; Src = 'Disabled'; Dst = 'Disabled'; Commands = 0 } }
    'both-enabled'        { $Sim.Status[$DST] = 'Started';          $expect = @{ Exit = 1; Src = 'Started'; Dst = 'Started'; Commands = 0 } }
    default               { throw "Unknown scenario '$Scenario'." }
}

# Script parameters, with short timeouts so the suite runs quickly.
$Execute = $true; $StopTimeoutSec = 2; $StartTimeoutSec = 2; $SettleSec = 0
$logDir = Join-Path ([IO.Path]::GetTempPath()) 'BluetoothSwitcher-tests'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogPath = Join-Path $logDir "scenario-$Scenario.log"
if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath }

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path, [ref]$null, [ref]$null)
$statements = @($ast.EndBlock.Statements)
$mainTry = @($statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[-1]

try {
    foreach ($st in $statements) {
        if ($st -is [System.Management.Automation.Language.ExitStatementAst]) { continue }
        if ($st -eq $mainTry) {
            # Test doubles, installed after the script's own functions are defined
            # and before its main block runs.
            $PollMs = 20; $RollbackGraceSec = 1
            function Test-Elevated   { $true }
            function Get-PnputilPath { Join-Path $here 'mock\fake-pnputil.ps1' }
            function Find-Adapter {
                param([string]$Role)
                if ($Role -eq 'Internal') { [pscustomobject]@{ Role = 'Internal'; Location = 'Upstairs';   Name = 'SIM MediaTek'; InstanceId = $DST } }
                else                      { [pscustomobject]@{ Role = 'External'; Location = 'Downstairs'; Name = 'SIM BARROT';   InstanceId = $SRC } }
            }
        }
        . ([scriptblock]::Create($st.Extent.Text))
    }
}
finally {
    $s = $global:Sim
    $got = @{ Exit = $script:ExitCode; Src = $s.Status[$SRC]; Dst = $s.Status[$DST]; Commands = $s.Commands.Count }
    $bad = @()
    foreach ($k in 'Exit', 'Src', 'Dst', 'Commands') {
        if ($null -ne $expect[$k] -and "$($expect[$k])" -ne "$($got[$k])") { $bad += "$k expected $($expect[$k]) got $($got[$k])" }
    }
    if ($s.Status[$SRC] -eq 'Started' -and $s.Status[$DST] -eq 'Started' -and $Scenario -ne 'both-enabled') { $bad += 'TWO ADAPTERS STARTED' }
    foreach ($v in $s.Violations) { $bad += "VIOLATION: $v" }
    if ("$script:Pnputil" -and "$script:Pnputil" -notlike '*fake-pnputil.ps1') { $bad += "REAL PNPUTIL WAS RESOLVED: $script:Pnputil" }
    $verdict = if ($bad.Count) { "FAIL ($($bad -join '; '))" } else { 'PASS' }
    $cmds = ($s.Commands -replace 'USB\\VID_33FA.*', 'EXT' -replace 'USB\\VID_0489.*', 'INT') -join ', '
    Write-Host ("RESULT {0,-20} exit={1} ext={2,-8} int={3,-8} cmds={4} [{5}] {6}" -f $Scenario, $got.Exit, $got.Src, $got.Dst, $got.Commands, $cmds, $verdict)
}
