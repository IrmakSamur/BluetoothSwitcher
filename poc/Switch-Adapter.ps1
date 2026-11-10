<#
.SYNOPSIS
    Proof of concept: switch the active Bluetooth adapter using pnputil.

.DESCRIPTION
    DRY RUN BY DEFAULT. Without -Execute this script only reads device state and
    prints the commands it would run. It changes nothing.

    With -Execute it disables the active adapter, confirms it has stopped, enables
    the target adapter, confirms it has started, and rolls back if anything fails.

    -Execute requires an already-elevated PowerShell. The script never requests
    elevation and never relaunches itself.

    While switching, every Bluetooth device disconnects. Have a non-Bluetooth
    keyboard and mouse available before using -Execute.

.PARAMETER Target
    Upstairs   = internal adapter.
    Downstairs = external USB adapter.
    Toggle     = whichever one is not currently active.

.PARAMETER Execute
    Actually change device state. Omit for a dry run.

.PARAMETER StopTimeoutSec
    How long to wait for the active adapter to stop after disabling it.

.PARAMETER StartTimeoutSec
    How long to wait for an adapter to start after enabling it.

.PARAMETER SettleSec
    Pause between "old adapter stopped" and "enable new adapter".

.PARAMETER LogPath
    Log file. Default: %LOCALAPPDATA%\BluetoothSwitcher\logs\switch-<timestamp>.log

.NOTES
    Exit codes:
      0  Success, already on the target, or dry run completed.
      1  Refused before changing anything (pre-check failed).
      2  Switch failed; rolled back to the original adapter.
      3  Switch failed AND rollback failed. Manual recovery needed.
      4  Another switch is already running.
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

# Adapters are found by hardware ID. Instance IDs are resolved at run time,
# because the external dongle's instance ID changes with the USB port.
$HardwareId = @{
    Internal = 'USB\VID_0489&PID_E139&MI_00'
    External = 'USB\VID_33FA&PID_0012'
}
$RoleForLocation = @{ Upstairs = 'Internal'; Downstairs = 'External' }
$LocationForRole = @{ Internal = 'Upstairs'; External = 'Downstairs' }

$MutexName        = 'Global\BluetoothSwitcher.Switch'
$PollMs           = 250
$RollbackGraceSec = 5

$script:ExitCode  = 1
$script:Changed   = $false   # a state-changing pnputil command has been issued
$script:Completed = $false   # the run reached a defined end state (success or handled failure)
$script:Caught    = $false   # the catch block ran (false after an uncatchable pipeline stop)
$script:Phase     = 'startup'
$script:SourceDisableIssued = $false
$script:DestEnableIssued    = $false
$script:Source    = $null    # adapter that is active now
$script:Dest      = $null    # adapter we are switching to

# ---------------------------------------------------------------- logging

if (-not $LogPath) {
    $LogPath = Join-Path $env:LOCALAPPDATA ("BluetoothSwitcher\logs\switch-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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

# A failure that was already logged. Carries no extra information.
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
    if ($info -and $info.Line) {
        Log 'ERROR' ("  at line {0}: {1}" -f $info.ScriptLineNumber, $info.Line.Trim())
    }
    foreach ($frame in @("$($ErrorRecord.ScriptStackTrace)" -split "`r?`n")) {
        if ($frame.Trim()) { Log 'ERROR' "  stack: $($frame.Trim())" }
    }
    $inner = $ex.InnerException
    while ($inner) {
        Log 'ERROR' "  inner: [$($inner.GetType().FullName)] $($inner.Message)"
        $inner = $inner.InnerException
    }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- device state (read-only)

function Get-Prop {
    param([string]$InstanceId, [string]$Key)
    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue
    if ($p) { $p.Data } else { $null }
}

function Find-Adapter {
    param([string]$Role)
    $wanted = $HardwareId[$Role]
    # Both adapters are USB devices; skipping the rest avoids slow property lookups.
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

# Reads every connected Bluetooth-class device with ONE native pnputil call and
# returns a map of lower-case instance ID -> status text ('Started', 'Disabled', ...).
#
# State polling deliberately does not use Get-PnpDevice / Get-PnpDeviceProperty.
# Those are WMI-backed, slow (~0.7s per poll), and ran inside the first real switch
# when the run was stopped uncatchably while the device tree was changing.
# pnputil talks to the Configuration Manager directly and takes ~20ms.
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

# EnumeratorUp means a Microsoft Bluetooth Enumerator (BTH\MS_BTHBRB) is started,
# i.e. the Bluetooth stack is running on some radio. Because the pre-checks only
# allow one enabled adapter at a time, a started adapter plus a started enumerator
# means the stack is running on that adapter.
function Get-State {
    param([string]$InstanceId)
    $state = [pscustomobject]@{
        Readable = $false; Status = 'Unreadable'; EnumeratorUp = $false
        IsDisabled = $false; IsActive = $false; IsRunning = $false; Text = 'unreadable'
    }
    try {
        $devices = Read-BluetoothDevices
        $enumUp = $false
        foreach ($key in $devices.Keys) {
            if ($key -like 'bth\ms_bthbrb\*' -and $devices[$key] -eq 'Started') { $enumUp = $true }
        }
        $status = $devices["$InstanceId".ToLowerInvariant()]
        if ($null -eq $status) { $status = 'NotConnected' }

        $state.Readable     = $true
        $state.Status       = $status
        $state.EnumeratorUp = $enumUp
        $state.IsDisabled   = ($status -eq 'Disabled')
        $state.IsRunning    = ($status -eq 'Started')
        $state.IsActive     = ($state.IsRunning -and $enumUp)
        $state.Text         = "status=$status enumerator=$enumUp"
    } catch {
        $state.Text = "unreadable: [$($_.Exception.GetType().Name)] $($_.Exception.Message)"
    }
    return $state
}

# Poll until the adapter is 'Stopped' or 'Active'. Returns $true on success.
# An unreadable poll is logged and retried; it never aborts the wait.
function Wait-ForState {
    param([string]$InstanceId, [ValidateSet('Stopped', 'Active')][string]$Want, [int]$TimeoutSec, [string]$Label)
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
        $ok = if ($Want -eq 'Stopped') { $s.IsDisabled -and -not $s.EnumeratorUp } else { $s.IsActive }
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

# ---------------------------------------------------------------- device changes (pnputil)

function Get-PnputilPath {
    $dir = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $dir = 'Sysnative' }
    $path = Join-Path $env:SystemRoot "$dir\pnputil.exe"
    if (-not (Test-Path -LiteralPath $path)) { Fail 1 "pnputil.exe not found at $path. Nothing was changed." }
    return $path
}

# Runs (or, in a dry run, only prints) one pnputil command. Returns the exit code.
function Invoke-Pnputil {
    param([ValidateSet('disable', 'enable')][string]$Verb, [string]$InstanceId)
    $switchName = "/$Verb-device"
    $display = "pnputil.exe $switchName `"$InstanceId`""
    if (-not $Execute) {
        Log 'DRY' "Would run: $display"
        return 0
    }
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

function Show-Recovery {
    $s = $script:Source; $d = $script:Dest
    Log 'WARN' '---------------- MANUAL RECOVERY ----------------'
    Log 'WARN' 'Use a wired keyboard/mouse. Open an elevated terminal (or Device Manager > Bluetooth).'
    if ($s -and $d) {
        Log 'WARN' "To go back to $($s.Location) ($($s.Name)):"
        Log 'WARN' "  pnputil /disable-device `"$($d.InstanceId)`""
        Log 'WARN' "  pnputil /enable-device `"$($s.InstanceId)`""
        Log 'WARN' "To use $($d.Location) ($($d.Name)) instead:"
        Log 'WARN' "  pnputil /disable-device `"$($s.InstanceId)`""
        Log 'WARN' "  pnputil /enable-device `"$($d.InstanceId)`""
    }
    Log 'WARN' 'Always disable one adapter before enabling the other. If an adapter will not start,'
    Log 'WARN' 'replug the dongle (external) or reboot (internal), then enable it again.'
    Log 'WARN' '--------------------------------------------------'
}

# State-based and idempotent: make sure the target is not running, then bring the
# original adapter back. Returns $true if the original adapter is active again.
function Invoke-Rollback {
    Log 'WARN' "ROLLBACK: restoring $($script:Source.Location) ($($script:Source.Name))."
    try {
        $d = Get-State $script:Dest.InstanceId
        Log 'INFO' "  target state: $($d.Text)"
        # If an enable was issued, do not trust a 'Disabled' reading: it may be stale.
        if ($script:DestEnableIssued -or -not $d.IsDisabled) {
            $null = Invoke-Pnputil 'disable' $script:Dest.InstanceId
            $stopped = Wait-ForState $script:Dest.InstanceId 'Stopped' $StopTimeoutSec 'target'
            if (-not $stopped) {
                $d = Get-State $script:Dest.InstanceId
                # Only a confirmed 'Disabled' reading is good enough. A target that is
                # enabled but not running (for example a start problem) could start
                # later, so the original must stay off.
                if (-not $d.IsDisabled) {
                    Log 'ERROR' "Target adapter is not confirmed disabled ($($d.Text)). Not enabling the original, to avoid two enabled adapters."
                    return $false
                }
                Log 'WARN' "  target is disabled ($($d.Text)); continuing."
            }
        }

        $s = Get-State $script:Source.InstanceId
        Log 'INFO' "  original state: $($s.Text)"
        if ($script:SourceDisableIssued -and -not $s.IsDisabled) {
            # A disable was issued but the adapter still reads as running. Give it a
            # moment to finish stopping, so a stale reading is not mistaken for success.
            Log 'INFO' "  a disable was issued for the original adapter; allowing ${RollbackGraceSec}s for it to take effect."
            $null = Wait-ForState $script:Source.InstanceId 'Stopped' $RollbackGraceSec 'original'
            $s = Get-State $script:Source.InstanceId
            Log 'INFO' "  original state: $($s.Text)"
        }
        if ($s.IsActive) {
            Log 'INFO' '  original adapter is already active.'
            return $true
        }
        if ($s.IsDisabled) {
            $code = Invoke-Pnputil 'enable' $script:Source.InstanceId
            if ($code -ne 0) { Log 'ERROR' "  enabling the original adapter returned exit code $code." }
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
    Log 'INFO' "BluetoothSwitcher switch PoC. Mode: $mode. Requested target: $Target."
    Log 'INFO' "Timeouts: stop=${StopTimeoutSec}s start=${StartTimeoutSec}s settle=${SettleSec}s. Log: $LogPath"

    # --- single instance lock
    try {
        $mutex = New-Object System.Threading.Mutex($false, $MutexName)
        try {
            $hasLock = $mutex.WaitOne(0)
        } catch {
            if ($_.Exception.GetBaseException() -is [System.Threading.AbandonedMutexException]) {
                Log 'WARN' 'A previous run ended without releasing the lock. Lock acquired.'
                $hasLock = $true
            } else { throw }
        }
    } catch {
        Log 'ERROR' "Could not open the switch lock (another run is probably active): $($_.Exception.GetBaseException().Message)"
        $hasLock = $false
    }
    if (-not $hasLock) { Fail 4 'Another switch operation is already running. Nothing was changed.' }

    # --- pre-checks (all read-only)
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

    $service = Get-Service bthserv -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') {
        Log 'WARN' 'Bluetooth Support Service (bthserv) is not running. Start-up verification may fail.'
    }

    # Exactly one adapter must be active and the other cleanly disabled.
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

    # --- step 1: disable the active adapter
    $script:Phase = 'step 1: disable active adapter'
    Log 'INFO' "Step 1/4: disable $($script:Source.Name)."
    if ($Execute) { $script:SourceDisableIssued = $true }
    $code = Invoke-Pnputil 'disable' $script:Source.InstanceId
    if ($code -ne 0) { Fail 2 "Disable returned exit code $code (3010 means a reboot is required)." }

    # --- step 2: confirm it has stopped
    $script:Phase = 'step 2: wait for active adapter to stop'
    Log 'INFO' "Step 2/4: wait up to ${StopTimeoutSec}s for it to stop."
    if ($Execute) {
        if (-not (Wait-ForState $script:Source.InstanceId 'Stopped' $StopTimeoutSec 'original')) {
            Fail 2 'The active adapter did not stop. The target will not be enabled.'
        }
        if ($SettleSec -gt 0) {
            Log 'INFO' "  settling for ${SettleSec}s."
            Start-Sleep -Seconds $SettleSec
        }
    } else {
        Log 'DRY' "Would poll every ${PollMs}ms until status = Disabled and no Bluetooth enumerator is started, then pause ${SettleSec}s."
    }

    # --- step 3: enable the target adapter
    $script:Phase = 'step 3: enable target adapter'
    Log 'INFO' "Step 3/4: enable $($script:Dest.Name)."
    if ($Execute) { $script:DestEnableIssued = $true }
    $code = Invoke-Pnputil 'enable' $script:Dest.InstanceId
    if ($code -ne 0) { Fail 2 "Enable returned exit code $code (3010 means a reboot is required)." }

    # --- step 4: confirm it has started
    $script:Phase = 'step 4: wait for target adapter to start'
    Log 'INFO' "Step 4/4: wait up to ${StartTimeoutSec}s for it to start."
    if ($Execute) {
        if (-not (Wait-ForState $script:Dest.InstanceId 'Active' $StartTimeoutSec 'target')) {
            Fail 2 'The target adapter did not start.'
        }
        $s = Get-State $script:Source.InstanceId
        if (-not $s.IsDisabled) {
            Fail 2 "The original adapter is no longer disabled ($($s.Text))."
        }
        Log 'INFO' "SUCCESS: now on $($script:Dest.Location) ($($script:Dest.Name))."
        Log 'INFO' 'Devices paired with the other adapter will not reconnect until you switch back.'
    } else {
        Log 'DRY' 'Would poll until status = Started and a Bluetooth enumerator is started.'
        Log 'DRY' 'On any failure after step 1: disable the target if it is not disabled, re-enable the original, and verify.'
        Log 'DRY' 'Dry run complete. Nothing was changed. Add -Execute in an elevated PowerShell to switch.'
    }

    $script:ExitCode = 0
    $script:Completed = $true
}
catch {
    # Only logs. Rollback lives in 'finally', because a pipeline stop
    # (PipelineStoppedException, e.g. Ctrl+C or a stopped command) skips every
    # 'catch' block and runs only 'finally'.
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
                Log 'ERROR' "The run was stopped during phase '$($script:Phase)' without a catchable error (pipeline stop). Attempting rollback."
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
