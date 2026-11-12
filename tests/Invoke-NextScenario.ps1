<#
.SYNOPSIS
    Runs one mocked scenario against the real logic of poc/Switch-Adapter-Next.ps1
    (the experimental two-phase stop).

.DESCRIPTION
    SAFE: reads and changes no real device and needs no administrator rights. The
    script's own statements are executed with its device functions replaced by an
    in-memory simulation: Find-Adapter, Test-Elevated, Get-PnputilPath (-> the fake
    pnputil) and the four Configuration Manager functions.

    Run each scenario in its own PowerShell process (Run-Tests.ps1 does this).
    Prints the script's log and one line starting with RESULT, ending in PASS or FAIL.
#>
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$ScriptPath
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptPath) { $ScriptPath = Join-Path $here '..\poc\Switch-Adapter-Next.ps1' }
$SRC = 'USB\VID_33FA&PID_0012\SIM&EXT'          # simulated external adapter, starts active
$DST = 'USB\VID_0489&PID_E139&MI_00\SIM&INT'    # simulated internal adapter, starts disabled

$global:Sim = @{
    Status = [ordered]@{ $DST = 'Disabled'; $SRC = 'Started' }; Enum = $true
    Reads = 0; Pending = @(); Commands = @(); Violations = @()
    StopDelayReads = 2; StartDelayReads = 3; StartDelayFor = @{}
    StopOnRead = @(); GarbageOnRead = @(); FailOnRead = @()
    DisableExit = @{}; EnableExit = @{}; NeedsRestart = @(); NeverStops = @(); NeverStarts = @()
    VetoStop = @(); PersistFails = @(); PersistSetsRestart = @(); StopNeverCompletes = @()
}
$Target = 'Upstairs'
$expect = @{ Exit = 0; Src = 'Disabled'; Dst = 'Started'; Commands = 3 }   # stop EXT, persist EXT, enable INT

switch ($Scenario) {
    'happy'               { }
    # Windows refuses the stop (Steam). Nothing may be written and no restart flag may appear.
    'vetoed'              { $Sim.VetoStop = @($SRC);           $expect = @{ Exit = 6; Src = 'Started'; Dst = 'Disabled'; Commands = 1 } }
    'restart-pending'     { $Sim.NeedsRestart = @($SRC);       $expect = @{ Exit = 5; Src = 'Started'; Dst = 'Disabled'; Commands = 0 } }
    'stop-never-completes'{ $Sim.StopNeverCompletes = @($SRC); $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 1 } }
    # Persisting fails both ways: the stopped adapter must be started again.
    'persist-fails'       { $Sim.PersistFails = @($SRC); $Sim.DisableExit[$SRC] = 5; $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 4 } }
    'persist-falls-back'  { $Sim.PersistFails = @($SRC);       $expect = @{ Exit = 0; Src = 'Disabled'; Dst = 'Started'; Commands = 4 } }
    'target-never-starts' { $Sim.NeverStarts = @($DST);        $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 6 } }
    'target-enable-fails' { $Sim.EnableExit[$DST] = 3010;      $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = 4 } }
    # Rollback cannot stop the target (vetoed): the original must NOT be started.
    'rollback-target-vetoed' { $Sim.NeverStarts = @($DST); $Sim.VetoStop = @($DST); $expect = @{ Exit = 3; Src = 'Disabled'; Dst = 'Problem'; Commands = 4 } }
    'stop-in-wait'        { $Sim.StopOnRead = @(3);            $expect = @{ Exit = 2; Src = 'Started'; Dst = 'Disabled'; Commands = $null } }
    'already-on-target'   { $Target = 'Downstairs';            $expect = @{ Exit = 0; Src = 'Started'; Dst = 'Disabled'; Commands = 0 } }
    'both-disabled'       { $Sim.Status[$SRC] = 'Disabled'; $Sim.Enum = $false; $expect = @{ Exit = 1; Src = 'Disabled'; Dst = 'Disabled'; Commands = 0 } }
    default               { throw "Unknown scenario '$Scenario'." }
}

$Execute = $true; $StopTimeoutSec = 2; $StartTimeoutSec = 2; $SettleSec = 0
$logDir = Join-Path ([IO.Path]::GetTempPath()) 'BluetoothSwitcher-tests'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$LogPath = Join-Path $logDir "next-$Scenario.log"
if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath }

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path, [ref]$null, [ref]$null)
$statements = @($ast.EndBlock.Statements)
$mainTry = @($statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[-1]

function Add-Pending { param($Id, $Kind, $Reads, $Apply) $global:Sim.Pending += @{ Id = $Id; Kind = $Kind; Reads = $Reads; Apply = $Apply } }

try {
    foreach ($st in $statements) {
        if ($st -is [System.Management.Automation.Language.ExitStatementAst]) { continue }
        # The real cfgmgr32 declarations are not needed: every caller is replaced below.
        if ($st.Extent.Text -like '$script:Cm = *') { continue }
        if ($st -eq $mainTry) {
            $PollMs = 20
            function Test-Elevated   { $true }
            function Get-PnputilPath { Join-Path $here 'mock\fake-pnputil.ps1' }
            function Find-Adapter {
                param([string]$Role)
                if ($Role -eq 'Internal') { [pscustomobject]@{ Role = 'Internal'; Location = 'Upstairs';   Name = 'SIM MediaTek'; InstanceId = $DST } }
                else                      { [pscustomobject]@{ Role = 'External'; Location = 'Downstairs'; Name = 'SIM BARROT';   InstanceId = $SRC } }
            }
            function Get-CmStatus {
                param([string]$InstanceId)
                $s = $global:Sim
                [pscustomobject]@{ Problem = $(switch ($s.Status[$InstanceId]) { 'Disabled' { 22 } 'Problem' { 21 } default { 0 } }); NeedsRestart = ($s.NeedsRestart -contains $InstanceId) }
            }
            function Invoke-CmQueryRemove {
                param([string]$InstanceId)
                $s = $global:Sim; $s.Commands += "stop $InstanceId"
                if ($s.VetoStop -contains $InstanceId) { return [pscustomobject]@{ Code = 0x17; VetoType = 'OutstandingOpen'; VetoName = 'steam.exe' } }
                $s.Pending = @($s.Pending | Where-Object { $_.Id -ne $InstanceId })
                if (-not ($s.StopNeverCompletes -contains $InstanceId)) {
                    $wasStarted = ($s.Status[$InstanceId] -eq 'Started')
                    Add-Pending $InstanceId 'stop' $s.StopDelayReads ({ $global:Sim.Status[$InstanceId] = 'Problem'; if ($wasStarted) { $global:Sim.Enum = $false } }.GetNewClosure())
                }
                [pscustomobject]@{ Code = 0; VetoType = 'Unknown'; VetoName = '' }
            }
            function Invoke-CmDisablePersist {
                param([string]$InstanceId)
                $s = $global:Sim; $s.Commands += "persist $InstanceId"
                if ($s.Status[$InstanceId] -eq 'Started') { $s.Violations += "persist issued while $InstanceId is still started" }
                if ($s.PersistFails -contains $InstanceId) { return 0x13 }
                # The device has stopped; a still-pending simulated "stopped" event must not undo this.
                $s.Pending = @($s.Pending | Where-Object { $_.Id -ne $InstanceId })
                $s.Status[$InstanceId] = 'Disabled'
                return 0
            }
            function Invoke-CmSetupDevNode {
                param([string]$InstanceId)
                $s = $global:Sim; $s.Commands += "restart $InstanceId"
                foreach ($other in @($s.Status.Keys)) {
                    if ($other -ne $InstanceId -and $s.Status[$other] -ne 'Disabled') { $s.Violations += "restart $InstanceId while $other is $($s.Status[$other])" }
                }
                Add-Pending $InstanceId 'start' $s.StartDelayReads ({ $global:Sim.Status[$InstanceId] = 'Started'; $global:Sim.Enum = $true }.GetNewClosure())
                return 0
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
    if ($s.Status[$SRC] -eq 'Started' -and $s.Status[$DST] -eq 'Started') { $bad += 'TWO ADAPTERS STARTED' }
    foreach ($v in $s.Violations) { $bad += "VIOLATION: $v" }
    # The point of the new method: a refused stop must leave no trace.
    if ($Scenario -eq 'vetoed' -and @($s.Commands | Where-Object { $_ -notlike 'stop *' }).Count) { $bad += 'something was written after a veto' }
    $verdict = if ($bad.Count) { "FAIL ($($bad -join '; '))" } else { 'PASS' }
    $cmds = ($s.Commands -replace 'USB\\VID_33FA.*', 'EXT' -replace 'USB\\VID_0489.*', 'INT') -join ', '
    Write-Host ("RESULT {0,-22} exit={1} ext={2,-8} int={3,-8} cmds={4} [{5}] {6}" -f $Scenario, $got.Exit, $got.Src, $got.Dst, $got.Commands, $cmds, $verdict)
}
