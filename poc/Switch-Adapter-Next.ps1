<#
.SYNOPSIS
    EXPERIMENTAL switch script using a two-phase stop. Not the installed engine.

.DESCRIPTION
    DRY RUN BY DEFAULT. Without -Execute it only reads state and prints its plan.

    Why this exists. poc\Switch-Adapter.ps1 disables the active adapter with
    "pnputil /disable-device". When Windows refuses that (seen with Steam and a paired
    controller), pnputil still writes the "disabled" flag: the adapter keeps running,
    is flagged as needing a restart, and comes up disabled after the next restart.

    This script never writes anything persistent until the adapter has really stopped:

      1. STOP    Ask Windows to stop the active adapter, non-persistently
                 (CM_Query_And_Remove_SubTree, no restart). If Windows refuses, nothing
                 has been written: report who is blocking and exit. No rollback needed.
      2. PERSIST Only once it has stopped: mark it disabled (CM_Disable_DevNode with
                 the persist flag), and confirm.
      3. ENABLE  Enable the target with pnputil, as the validated script does, and
                 confirm it starts.

    Every step is verified by re-reading device state, and a restart flag on either
    adapter is treated as a failure at every check. On failure the original adapter is
    restored; the same two-phase stop is used for the target during rollback.

    -Execute needs an elevated PowerShell. The script never requests elevation.

.NOTES
    Exit codes:
      0  Success, already on the target, or dry run completed.
      1  Refused before changing anything (pre-check failed).
      2  Switch failed; the original adapter was restored.
      3  Switch failed AND restoring failed. Manual recovery needed.
      4  Another switch is already running.
      5  Refused: an adapter is flagged as needing a restart. Nothing was changed.
      6  Blocked: Windows refused to stop the active adapter. Nothing was changed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Upstairs', 'Downstairs', 'Toggle')]
    [string]$Target,

    [switch]$Execute,

    [ValidateRange(5, 120)]
    [int]$StopTimeoutSec = 15,

    [ValidateRange(5, 180)]
    [int]$StartTimeoutSec = 30,

    [ValidateRange(0, 30)]
    [int]$SettleSec = 2,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$HardwareId = @{
    Internal = 'USB\VID_0489&PID_E139&MI_00'
    External = 'USB\VID_33FA&PID_0012'
}
$RoleForLocation = @{ Upstairs = 'Internal'; Downstairs = 'External' }
$LocationForRole = @{ Internal = 'Upstairs'; External = 'Downstairs' }

$MutexName = 'Global\BluetoothSwitcher.Switch'
$PollMs    = 250

$script:ExitCode  = 1
$script:Changed   = $false   # a device has actually been stopped or a state-changing command issued
$script:Completed = $false
$script:Caught    = $false
$script:Phase     = 'startup'
$script:Source    = $null
$script:Dest      = $null
$script:DestEnableIssued = $false

# ---------------------------------------------------------------- logging

if (-not $LogPath) {
    $LogPath = Join-Path $env:LOCALAPPDATA ("BluetoothSwitcher\logs\switch-next-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
try {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
} catch {
    Write-Host "WARNING: cannot create log folder, logging to console only: $($_.Exception.Message)"
    $LogPath = $null
}

function Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Write-Host $line
    if ($LogPath) {
        try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    }
}

function Fail {
    param([int]$Code, [string]$Message)
    Log 'ERROR' $Message
    $script:ExitCode = $Code
    throw [System.OperationCanceledException]::new($Message)
}

function Write-ExceptionDetail {
    param($ErrorRecord, [string]$Context)
    $ex = $ErrorRecord.Exception
    Log 'ERROR' "${Context}: [$($ex.GetType().FullName)] $($ex.Message)"
    $info = $ErrorRecord.InvocationInfo
    if ($info -and $info.Line) { Log 'ERROR' ("  at line {0}: {1}" -f $info.ScriptLineNumber, $info.Line.Trim()) }
    foreach ($frame in @("$($ErrorRecord.ScriptStackTrace)" -split "`r?`n")) {
        if ($frame.Trim()) { Log 'ERROR' "  stack: $($frame.Trim())" }
    }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- Configuration Manager

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BtsSwitchCm
{
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint CM_Locate_DevNodeW(out uint devInst, string deviceId, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    public static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint CM_Query_And_Remove_SubTreeW(uint devInst, out int vetoType, StringBuilder vetoName, uint nameLength, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    public static extern uint CM_Setup_DevNode(uint devInst, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    public static extern uint CM_Disable_DevNode(uint devInst, uint flags);
}
'@

$CR_REMOVE_VETOED     = 0x17
$DN_NEED_RESTART      = 0x100
$CM_REMOVE_UI_NOT_OK  = 0x1
$CM_REMOVE_NO_RESTART = 0x2
$CM_DISABLE_UI_NOT_OK = 0x4
$CM_DISABLE_PERSIST   = 0x8
$VetoTypes = @('Unknown', 'LegacyDevice', 'PendingClose', 'WindowsApp', 'WindowsService', 'OutstandingOpen',
               'Device', 'Driver', 'IllegalDeviceRequest', 'InsufficientPower', 'NonDisableable',
               'LegacyDriver', 'InsufficientRights', 'AlreadyRemoved')

function Get-DevInst {
    param([string]$InstanceId)
    $devInst = [uint32]0
    $cr = [BtsSwitchCm]::CM_Locate_DevNodeW([ref]$devInst, $InstanceId, 0)
    if ($cr -ne 0) { throw "CM_Locate_DevNode failed for $InstanceId (0x$('{0:X}' -f $cr))." }
    return $devInst
}

# The four functions below are the only Configuration Manager calls. The tests replace them.

# Read-only: problem code and restart flag of a device.
function Get-CmStatus {
    param([string]$InstanceId)
    $status = [uint32]0; $problem = [uint32]0
    $cr = [BtsSwitchCm]::CM_Get_DevNode_Status([ref]$status, [ref]$problem, (Get-DevInst $InstanceId), 0)
    if ($cr -ne 0) { throw "CM_Get_DevNode_Status failed (0x$('{0:X}' -f $cr))." }
    [pscustomobject]@{ Problem = [int]$problem; NeedsRestart = [bool]($status -band $DN_NEED_RESTART) }
}

# Asks Windows to stop a device WITHOUT writing anything persistent.
function Invoke-CmQueryRemove {
    param([string]$InstanceId)
    $name = New-Object System.Text.StringBuilder 520
    $vetoType = 0
    $cr = [BtsSwitchCm]::CM_Query_And_Remove_SubTreeW((Get-DevInst $InstanceId), [ref]$vetoType, $name, 260,
              ($CM_REMOVE_UI_NOT_OK -bor $CM_REMOVE_NO_RESTART))
    $typeName = if ($vetoType -ge 0 -and $vetoType -lt $VetoTypes.Count) { $VetoTypes[$vetoType] } else { "$vetoType" }
    [pscustomobject]@{ Code = [int]$cr; VetoType = $typeName; VetoName = $name.ToString() }
}

# Marks an already-stopped device as disabled across restarts. Returns the CM code.
function Invoke-CmDisablePersist {
    param([string]$InstanceId)
    return [int][BtsSwitchCm]::CM_Disable_DevNode((Get-DevInst $InstanceId), ($CM_DISABLE_UI_NOT_OK -bor $CM_DISABLE_PERSIST))
}

# Starts a device again after a non-persistent stop. Returns the CM code.
function Invoke-CmSetupDevNode {
    param([string]$InstanceId)
    return [int][BtsSwitchCm]::CM_Setup_DevNode((Get-DevInst $InstanceId), 0)
}

# ---------------------------------------------------------------- device state (read-only)

function Get-Prop {
    param([string]$InstanceId, [string]$Key)
    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue
    if ($p) { $p.Data } else { $null }
}

# Used once, before any change. After that only pnputil and the Configuration Manager are used.
function Find-Adapter {
    param([string]$Role)
    $wanted = $HardwareId[$Role]
    $found = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'USB\*' -and
        @(Get-Prop $_.InstanceId 'DEVPKEY_Device_HardwareIds') -contains $wanted
    })
    if ($found.Count -ne 1) {
        Fail 1 "Expected exactly 1 present $Role adapter with hardware ID $wanted, found $($found.Count). Nothing was changed."
    }
    [pscustomobject]@{
        Role       = $Role
        Location   = $LocationForRole[$Role]
        Name       = $found[0].FriendlyName
        InstanceId = $found[0].InstanceId
    }
}

function Read-BluetoothDevices {
    $output = & $script:Pnputil '/enum-devices' '/connected' '/class' 'Bluetooth' '/format' 'xml'
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "pnputil /enum-devices returned exit code $code." }
    $doc = [xml](@($output) -join "`n")
    $map = @{}
    foreach ($node in @($doc.PnpUtil.Device)) {
        if ($null -eq $node) { continue }
        $map["$($node.InstanceId)".ToLowerInvariant()] = "$($node.Status)"
    }
    return $map
}

function Get-State {
    param([string]$InstanceId)
    $state = [pscustomobject]@{
        Readable = $false; Status = 'Unreadable'; EnumeratorUp = $false; Problem = -1; NeedsRestart = $false
        IsDisabled = $false; IsRunning = $false; IsActive = $false; Text = 'unreadable'
    }
    try {
        $devices = Read-BluetoothDevices
        $enumUp = $false
        foreach ($key in $devices.Keys) {
            if ($key -like 'bth\ms_bthbrb\*' -and $devices[$key] -eq 'Started') { $enumUp = $true }
        }
        $status = $devices["$InstanceId".ToLowerInvariant()]
        if ($null -eq $status) { $status = 'NotConnected' }
        $cm = Get-CmStatus $InstanceId

        $state.Readable     = $true
        $state.Status       = $status
        $state.EnumeratorUp = $enumUp
        $state.Problem      = $cm.Problem
        $state.NeedsRestart = $cm.NeedsRestart
        $state.IsDisabled   = ($status -eq 'Disabled')
        $state.IsRunning    = ($status -eq 'Started')
        $state.IsActive     = ($state.IsRunning -and $enumUp)
        $state.Text         = "status=$status problem=$($cm.Problem) enumerator=$enumUp needsRestart=$($cm.NeedsRestart)"
    } catch {
        $state.Text = "unreadable: [$($_.Exception.GetType().Name)] $($_.Exception.Message)"
    }
    return $state
}

# Stopped  = not running and the Bluetooth stack is down (after a non-persistent stop).
# Disabled = marked disabled and the stack is down.
# Active   = running with the stack up.
function Wait-ForState {
    param([string]$InstanceId, [ValidateSet('Stopped', 'Disabled', 'Active')][string]$Want, [int]$TimeoutSec, [string]$Label)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = ''
    $polls = 0
    Log 'INFO' "  polling $Label for '$Want' (timeout ${TimeoutSec}s, every ${PollMs}ms)."
    while ($true) {
        $polls++
        $s = Get-State $InstanceId
        if ($s.Text -ne $last) {
            Log 'INFO' ("  {0}: {1} (+{2:n1}s, poll {3})" -f $Label, $s.Text, $sw.Elapsed.TotalSeconds, $polls)
            $last = $s.Text
        }
        $ok = switch ($Want) {
            'Stopped'  { $s.Readable -and -not $s.IsRunning -and -not $s.EnumeratorUp }
            'Disabled' { $s.IsDisabled -and -not $s.EnumeratorUp }
            'Active'   { $s.IsActive }
        }
        if ($ok) {
            Log 'INFO' ("  {0} reached '{1}' after {2:n1}s ({3} polls)" -f $Label, $Want, $sw.Elapsed.TotalSeconds, $polls)
            return $true
        }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
            Log 'ERROR' ("  {0} did not reach '{1}' within {2}s ({3} polls). Last state: {4}" -f $Label, $Want, $TimeoutSec, $polls, $s.Text)
            return $false
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

# ---------------------------------------------------------------- device changes

function Get-PnputilPath {
    $dir = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $dir = 'Sysnative' }
    $path = Join-Path $env:SystemRoot "$dir\pnputil.exe"
    if (-not (Test-Path -LiteralPath $path)) { Fail 1 "pnputil.exe not found at $path. Nothing was changed." }
    return $path
}

function Invoke-Pnputil {
    param([ValidateSet('disable', 'enable')][string]$Verb, [string]$InstanceId)
    $switchName = "/$Verb-device"
    $display = "pnputil.exe $switchName `"$InstanceId`""
    if (-not $Execute) { Log 'DRY' "Would run: $display"; return 0 }
    Log 'INFO' "Running: $display"
    $script:Changed = $true
    $output = & $script:Pnputil $switchName $InstanceId
    $code = $LASTEXITCODE
    foreach ($line in @($output)) {
        if ("$line".Trim()) { Log 'INFO' "  pnputil> $("$line".Trim())" }
    }
    Log 'INFO' "  pnputil exit code: $code"
    return $code
}

# Two-phase stop. Returns 'Disabled', 'Vetoed' (nothing was changed) or 'Failed'.
function Stop-AdapterSafely {
    param($Adapter, [string]$Label)

    # Phase 1: non-persistent stop. A refusal here leaves nothing behind.
    Log 'INFO' "  asking Windows to stop $($Adapter.Name) (non-persistent)."
    $r = Invoke-CmQueryRemove $Adapter.InstanceId
    Log 'INFO' ("  stop request returned 0x{0:X}" -f $r.Code)
    if ($r.Code -eq $CR_REMOVE_VETOED) {
        Log 'ERROR' "Windows refused to stop $($Adapter.Name): it is in use by '$($r.VetoName)' (veto type $($r.VetoType)). Nothing was written."
        return 'Vetoed'
    }
    if ($r.Code -ne 0) {
        Log 'ERROR' ("Stop request for $($Adapter.Name) failed with code 0x{0:X}." -f $r.Code)
        return 'Failed'
    }
    $script:Changed = $true
    if (-not (Wait-ForState $Adapter.InstanceId 'Stopped' $StopTimeoutSec $Label)) { return 'Failed' }

    # Phase 2: it has stopped, so marking it disabled can no longer be refused.
    $code = Invoke-CmDisablePersist $Adapter.InstanceId
    Log 'INFO' ("  persistent disable returned 0x{0:X}" -f $code)
    if ($code -ne 0) {
        Log 'WARN' '  CM_Disable_DevNode did not succeed; falling back to pnputil on the stopped device.'
        if ((Invoke-Pnputil 'disable' $Adapter.InstanceId) -ne 0) { return 'Failed' }
    }
    if (-not (Wait-ForState $Adapter.InstanceId 'Disabled' $StopTimeoutSec $Label)) { return 'Failed' }

    $s = Get-State $Adapter.InstanceId
    if ($s.NeedsRestart) {
        Log 'ERROR' "$($Adapter.Name) is flagged as needing a restart after the stop."
        return 'Failed'
    }
    return 'Disabled'
}

function Show-Recovery {
    $s = $script:Source; $d = $script:Dest
    Log 'WARN' '---------------- MANUAL RECOVERY ----------------'
    Log 'WARN' 'Open an elevated terminal (or Device Manager > Bluetooth).'
    if ($s -and $d) {
        Log 'WARN' "To go back to $($s.Location) ($($s.Name)):"
        Log 'WARN' "  pnputil /disable-device `"$($d.InstanceId)`""
        Log 'WARN' "  pnputil /enable-device `"$($s.InstanceId)`""
        Log 'WARN' "  pnputil /restart-device `"$($s.InstanceId)`"   (if it is enabled but not running)"
    }
    Log 'WARN' 'If an adapter is flagged as needing a restart, restart Windows first.'
    Log 'WARN' '--------------------------------------------------'
}

# State-based: make sure the target is disabled, then bring the original back.
function Invoke-Rollback {
    Log 'WARN' "ROLLBACK: restoring $($script:Source.Location) ($($script:Source.Name))."
    try {
        $d = Get-State $script:Dest.InstanceId
        Log 'INFO' "  target state: $($d.Text)"
        if ($script:DestEnableIssued -or -not $d.IsDisabled) {
            if ($d.IsDisabled) {
                Log 'INFO' '  target reads as disabled; nothing to stop.'
            } else {
                $result = Stop-AdapterSafely $script:Dest 'target'
                $d = Get-State $script:Dest.InstanceId
                if ($result -ne 'Disabled' -and -not $d.IsDisabled) {
                    Log 'ERROR' "Target adapter is not confirmed disabled ($($d.Text)). Not starting the original, to avoid two enabled adapters."
                    return $false
                }
            }
        }

        $s = Get-State $script:Source.InstanceId
        Log 'INFO' "  original state: $($s.Text)"
        if ($s.NeedsRestart) {
            Log 'ERROR' 'The original adapter is flagged as needing a restart.'
            return $false
        }
        if ($s.IsActive) { Log 'INFO' '  original adapter is already active.'; return $true }
        if ($s.IsDisabled) {
            $code = Invoke-Pnputil 'enable' $script:Source.InstanceId
            if ($code -ne 0) { Log 'ERROR' "  enabling the original adapter returned exit code $code." }
        } elseif (-not $s.IsRunning) {
            # Stopped but never marked disabled: start it again.
            $code = Invoke-CmSetupDevNode $script:Source.InstanceId
            Log 'INFO' ("  restart request returned 0x{0:X}" -f $code)
        }
        return (Wait-ForState $script:Source.InstanceId 'Active' $StartTimeoutSec 'original')
    } catch {
        Write-ExceptionDetail $_ 'Rollback hit an unexpected error'
        return $false
    }
}

# ---------------------------------------------------------------- main

$mutex   = $null
$hasLock = $false

try {
    $mode = if ($Execute) { 'EXECUTE' } else { 'DRY RUN (no changes will be made)' }
    Log 'INFO' "BluetoothSwitcher switch (EXPERIMENTAL two-phase stop). Mode: $mode. Requested target: $Target."
    Log 'INFO' "Timeouts: stop=${StopTimeoutSec}s start=${StartTimeoutSec}s settle=${SettleSec}s. Log: $LogPath"

    try {
        $mutex = New-Object System.Threading.Mutex($false, $MutexName)
        try {
            $hasLock = $mutex.WaitOne(0)
        } catch {
            if ($_.Exception.GetBaseException() -is [System.Threading.AbandonedMutexException]) { $hasLock = $true } else { throw }
        }
    } catch {
        Log 'ERROR' "Could not open the switch lock: $($_.Exception.GetBaseException().Message)"
        $hasLock = $false
    }
    if (-not $hasLock) { Fail 4 'Another switch operation is already running. Nothing was changed.' }

    # --- pre-checks (read-only)
    $script:Phase = 'pre-checks'
    $elevated = Test-Elevated
    Log 'INFO' "Elevated: $elevated."
    if ($Execute -and -not $elevated) {
        Fail 1 'Not elevated. -Execute needs a PowerShell you opened as administrator. This script never requests elevation. Nothing was changed.'
    }

    $script:Pnputil = Get-PnputilPath
    $internal = Find-Adapter 'Internal'
    $external = Find-Adapter 'External'
    $si = Get-State $internal.InstanceId
    $se = Get-State $external.InstanceId
    Log 'INFO' "Internal / Upstairs:   $($internal.Name) [$($internal.InstanceId)] $($si.Text)"
    Log 'INFO' "External / Downstairs: $($external.Name) [$($external.InstanceId)] $($se.Text)"

    if ($si.NeedsRestart -or $se.NeedsRestart) {
        Fail 5 'An adapter is flagged as needing a restart. Restart Windows before switching. Nothing was changed.'
    }

    if     ($si.IsActive -and $se.IsDisabled) { $script:Source = $internal; $script:Dest = $external }
    elseif ($se.IsActive -and $si.IsDisabled) { $script:Source = $external; $script:Dest = $internal }
    else {
        Show-Recovery
        Fail 1 'Adapters are not in a clean "one active, one disabled" state. Refusing to switch. Nothing was changed.'
    }
    Log 'INFO' "Currently active: $($script:Source.Location) ($($script:Source.Name))."

    if ($Target -ne 'Toggle' -and $RoleForLocation[$Target] -eq $script:Source.Role) {
        Log 'INFO' "Already on $Target. Nothing to do."
        $script:ExitCode = 0
        $script:Completed = $true
        return
    }
    Log 'INFO' "Plan: $($script:Source.Location) -> $($script:Dest.Location)."

    if (-not $Execute) {
        Log 'DRY' "Step 1/3 would ask Windows to stop $($script:Source.Name) without writing anything (CM_Query_And_Remove_SubTree)."
        Log 'DRY' '          If refused: exit 6, naming the blocker. Nothing changed, no restart flag.'
        Log 'DRY' "Step 2/3 would mark the stopped adapter disabled (CM_Disable_DevNode, persistent) and verify."
        Log 'DRY' "Step 3/3 would run: pnputil.exe /enable-device `"$($script:Dest.InstanceId)`" and wait for it to start."
        Log 'DRY' 'On failure after step 1: stop the target the same way if needed, restart the original, verify.'
        Log 'DRY' 'Dry run complete. Nothing was changed.'
        $script:ExitCode = 0
        $script:Completed = $true
        return
    }

    # --- steps 1 and 2: stop, then persist
    $script:Phase = 'steps 1-2: stop the active adapter and mark it disabled'
    Log 'INFO' "Step 1/3 and 2/3: stop $($script:Source.Name), then mark it disabled."
    $result = Stop-AdapterSafely $script:Source 'original'
    if ($result -eq 'Vetoed') {
        # Nothing was written. Confirm the adapter is still fine before saying so.
        $s = Get-State $script:Source.InstanceId
        if (-not $s.IsActive) { [void](Wait-ForState $script:Source.InstanceId 'Active' 10 'original') ; $s = Get-State $script:Source.InstanceId }
        if ($s.IsActive -and -not $s.NeedsRestart) {
            Log 'WARN' "Blocked. Still on $($script:Source.Location) ($($script:Source.Name)); no restart is needed."
            # Leave through the catch block (not 'return') so the final 'exit' sets the
            # process exit code. Completed is set, so no rollback runs.
            $script:ExitCode = 6
            $script:Completed = $true
            throw [System.OperationCanceledException]::new('blocked')
        }
        $script:Changed = $true
        Fail 2 "The stop was refused and the adapter is not as before ($($s.Text))."
    }
    if ($result -ne 'Disabled') { Fail 2 'The active adapter could not be stopped and marked disabled.' }

    if ($SettleSec -gt 0) {
        Log 'INFO' "  settling for ${SettleSec}s."
        Start-Sleep -Seconds $SettleSec
    }

    # --- step 3: enable the target
    $script:Phase = 'step 3: enable the target adapter'
    Log 'INFO' "Step 3/3: enable $($script:Dest.Name)."
    $script:DestEnableIssued = $true
    $code = Invoke-Pnputil 'enable' $script:Dest.InstanceId
    if ($code -ne 0) { Fail 2 "Enable returned exit code $code (3010 means a restart is required)." }
    if (-not (Wait-ForState $script:Dest.InstanceId 'Active' $StartTimeoutSec 'target')) { Fail 2 'The target adapter did not start.' }

    $s = Get-State $script:Source.InstanceId
    $d = Get-State $script:Dest.InstanceId
    if (-not $s.IsDisabled)                   { Fail 2 "The original adapter is no longer disabled ($($s.Text))." }
    if ($s.NeedsRestart -or $d.NeedsRestart)  { Fail 2 'An adapter is flagged as needing a restart after the switch.' }

    Log 'INFO' "SUCCESS: now on $($script:Dest.Location) ($($script:Dest.Name)). No restart flags."
    $script:ExitCode = 0
    $script:Completed = $true
}
catch {
    $script:Caught = $true
    if ($_.Exception -isnot [System.OperationCanceledException]) {
        Write-ExceptionDetail $_ "Unexpected error during phase '$($script:Phase)'"
        if (-not $script:Changed) { $script:ExitCode = 1 }
    }
}
finally {
    try {
        if ($script:Changed -and -not $script:Completed) {
            if (-not $script:Caught) {
                Log 'ERROR' "The run was stopped during phase '$($script:Phase)' without a catchable error. Attempting rollback."
            }
            $restored = $null
            try {
                $restored = Invoke-Rollback
            }
            finally {
                if ($restored -eq $true) {
                    Log 'WARN' "Rolled back. Still on $($script:Source.Location) ($($script:Source.Name))."
                    $script:ExitCode = 2
                } else {
                    if ($null -eq $restored) { Log 'ERROR' 'Rollback itself was stopped before it finished. Adapter state is unknown.' }
                    else                     { Log 'ERROR' 'ROLLBACK FAILED. Bluetooth may be unavailable.' }
                    Show-Recovery
                    $script:ExitCode = 3
                }
                $script:Completed = $true
            }
        }
    }
    finally {
        if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex)   { $mutex.Dispose() }
        Log 'INFO' "Exit code: $($script:ExitCode)."
    }
}

exit $script:ExitCode
