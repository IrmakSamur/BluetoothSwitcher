<#
.SYNOPSIS
    Experiment: can the active Bluetooth adapter be stopped while a program (Steam) holds
    a paired controller open, and can a refused stop be made to fail cleanly?

.DESCRIPTION
    Background. "pnputil /disable-device" asks Windows to remove the adapter's device
    stack. If a program has a Bluetooth device open, Windows vetoes the removal, and
    pnputil then marks the adapter "disabled, pending restart": it keeps running, cannot
    be disabled again, and comes up disabled after the next restart. That is the state
    the switch script left behind on 2026-11-11.

    WITHOUT -Execute this script only reads and reports (no administrator rights needed):
    adapter states and restart flags, the Bluetooth radio state, paired Bluetooth devices,
    whether Steam is running, and recent removal vetoes from the event log.

    WITH -Execute (elevated PowerShell; the script never requests elevation) it runs two
    tests on the ACTIVE adapter, both NON-PERSISTENT:

      Test 1  Ask Windows to stop the adapter with CM_Query_And_Remove_SubTree and
              "do not restart" (the same request pnputil makes, but without writing the
              persistent "disabled" flag). Expected with Steam running: a veto that names
              the blocker and leaves no restart flag.
      Test 2  Only if test 1 was vetoed: turn the Bluetooth radio off (as the Settings
              toggle does), which should make Windows drop the paired devices' device
              nodes, then ask again.

    After each test the adapter is started again and the radio is turned back on, and the
    final state is compared with the initial one.

    What can go wrong, and how to recover:
      - Bluetooth drops for some seconds during the tests.
      - If the adapter does not come back, nothing persistent was written: restarting
        Windows restores the state from before the test.
      - If a restart flag appears anyway, the script says so; a restart clears it.

    This script does not switch adapters and does not enable or disable anything
    persistently.

.PARAMETER Execute
    Run the tests. Omit for the read-only report.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    # Run test 1 only: "is the active adapter blocked right now, and by whom?"
    [switch]$StopRequestOnly,
    # Free text written to the log, to tell the steps of a comparison apart.
    [string]$Label,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$HardwareId = @{ Internal = 'USB\VID_0489&PID_E139&MI_00'; External = 'USB\VID_33FA&PID_0012' }
$MutexName  = 'Global\BluetoothSwitcher.Switch'   # same lock as the switch script

if (-not $LogPath) {
    $LogPath = Join-Path $env:LOCALAPPDATA ("BluetoothSwitcher\logs\probe-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

function Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- Configuration Manager access

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BtsCfgMgr
{
    public const uint CR_SUCCESS = 0x00;
    public const uint CR_REMOVE_VETOED = 0x17;
    public const uint DN_STARTED = 0x00000008;
    public const uint DN_NEED_RESTART = 0x00000100;
    public const uint CM_REMOVE_UI_NOT_OK = 0x1;
    public const uint CM_REMOVE_NO_RESTART = 0x2;
    public const uint CM_SETUP_DEVNODE_READY = 0x0;

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint CM_Locate_DevNodeW(out uint devInst, string deviceId, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    public static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint CM_Query_And_Remove_SubTreeW(uint devInst, out int vetoType, StringBuilder vetoName, uint nameLength, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    public static extern uint CM_Setup_DevNode(uint devInst, uint flags);
}
'@

$VetoTypes = @('Unknown', 'LegacyDevice', 'PendingClose', 'WindowsApp', 'WindowsService', 'OutstandingOpen',
               'Device', 'Driver', 'IllegalDeviceRequest', 'InsufficientPower', 'NonDisableable',
               'LegacyDriver', 'InsufficientRights', 'AlreadyRemoved')

function Get-Node {
    param([string]$InstanceId)
    $devInst = [uint32]0
    $cr = [BtsCfgMgr]::CM_Locate_DevNodeW([ref]$devInst, $InstanceId, 0)
    if ($cr -ne 0) { throw "CM_Locate_DevNode failed for $InstanceId (0x$('{0:X}' -f $cr))." }
    return $devInst
}

# One adapter's full state: pnputil status, devnode flags, and the registry "disabled" flag.
function Get-AdapterState {
    param([string]$Role)
    $prefix = $HardwareId[$Role] + '\'
    $xml = [xml]((& "$env:SystemRoot\System32\pnputil.exe" /enum-devices /connected /class Bluetooth /format xml) -join "`n")
    $nodes = @($xml.PnpUtil.Device | Where-Object { $_ -and "$($_.InstanceId)".StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($nodes.Count -ne 1) { throw "Expected exactly 1 connected $Role adapter, found $($nodes.Count)." }
    $id = "$($nodes[0].InstanceId)"
    $enumeratorUp = [bool]@($xml.PnpUtil.Device | Where-Object { $_ -and "$($_.InstanceId)" -like 'BTH\MS_BTHBRB\*' -and "$($_.Status)" -eq 'Started' }).Count

    $status = [uint32]0; $problem = [uint32]0
    [void][BtsCfgMgr]::CM_Get_DevNode_Status([ref]$status, [ref]$problem, (Get-Node $id), 0)
    $configFlags = 0
    try { $configFlags = [int](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$id" -ErrorAction Stop).ConfigFlags } catch { }

    [pscustomobject]@{
        Role = $Role; InstanceId = $id; Name = "$($nodes[0].DeviceDescription)"
        Status = "$($nodes[0].Status)"; Problem = $problem
        Started = [bool]($status -band [BtsCfgMgr]::DN_STARTED)
        NeedsRestart = [bool]($status -band [BtsCfgMgr]::DN_NEED_RESTART)
        MarkedDisabled = [bool]($configFlags -band 1)
        EnumeratorUp = $enumeratorUp
        Text = "status=$($nodes[0].Status) problem=$problem needsRestart=$([bool]($status -band 0x100)) markedDisabled=$([bool]($configFlags -band 1)) enumerator=$enumeratorUp"
    }
}

# Paired Bluetooth devices whose device node is present (present does not mean connected).
function Get-PairedDevices {
    @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'BTHENUM\DEV_*' -or $_.InstanceId -like 'BTHLE\DEV_*' } | ForEach-Object {
        $connected = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue).Data
        [pscustomobject]@{ Name = $_.FriendlyName; Connected = [bool]$connected }
    })
}

# ---------------------------------------------------------------- Bluetooth radio (WinRT)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
$script:AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRt {
    param($Operation, [Type]$ResultType)
    $task = $script:AsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(15000)) { throw 'A Windows radio operation did not finish within 15 seconds.' }
    return $task.Result
}

function Get-BluetoothRadio {
    $radios = Wait-WinRt ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    return @($radios | Where-Object { $_.Kind -eq [Windows.Devices.Radios.RadioKind]::Bluetooth }) | Select-Object -First 1
}

function Get-RadioStateText {
    try { $r = Get-BluetoothRadio; if ($r) { return "$($r.State) ($($r.Name))" } else { return 'no Bluetooth radio present' } }
    catch { return "unreadable: $($_.Exception.Message)" }
}

function Set-BluetoothRadio {
    param([ValidateSet('On', 'Off')][string]$State)
    $radio = Get-BluetoothRadio
    if (-not $radio) { throw 'No Bluetooth radio present.' }
    $access = Wait-WinRt ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
    if ("$access" -ne 'Allowed') { throw "Radio access was not allowed: $access." }
    $result = Wait-WinRt ($radio.SetStateAsync([Windows.Devices.Radios.RadioState]::$State)) ([Windows.Devices.Radios.RadioAccessStatus])
    Log 'INFO' "  radio set $State -> $result"
    if ("$result" -ne 'Allowed') { throw "Setting the radio $State was not allowed: $result." }
}

# ---------------------------------------------------------------- report (read-only)

function Write-Report {
    param([string]$Title)
    Log 'INFO' "--- $Title ---"
    foreach ($role in 'Internal', 'External') {
        try { $a = Get-AdapterState $role; Log 'INFO' ("  {0,-8} {1}: {2}" -f $role, $a.Name, $a.Text) }
        catch { Log 'WARN' "  ${role}: $($_.Exception.Message)" }
    }
    Log 'INFO' "  Bluetooth radio: $(Get-RadioStateText)"
    $paired = Get-PairedDevices
    if ($paired.Count -eq 0) { Log 'INFO' '  Paired devices present: none' }
    foreach ($p in $paired) { Log 'INFO' "  Paired device present: $($p.Name) (connected: $($p.Connected))" }
    Log 'INFO' "  Steam running: $([bool](Get-Process steam -ErrorAction SilentlyContinue))"
}

function Write-RecentVetoes {
    param([datetime]$Since)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 225; StartTime = $Since } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    if ($events.Count -eq 0) { Log 'INFO' "  No removal vetoes logged since $($Since.ToString('HH:mm:ss'))."; return }
    foreach ($e in $events) {
        $data = @{}; ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { $data[$_.Name] = $_.'#text' }
        Log 'INFO' ("  veto {0:HH:mm:ss} by {1} (pid {2})" -f $e.TimeCreated, ($data['ProcessName'] -replace '.*\\', ''), $data['ProcessId'])
    }
}

# Asks Windows to stop the adapter without persisting anything. Returns what happened.
function Invoke-StopAttempt {
    param($Adapter, [string]$Label)
    $name = New-Object System.Text.StringBuilder 520
    $vetoType = 0
    $began = Get-Date
    Log 'INFO' "$Label`: CM_Query_And_Remove_SubTree (no restart, no persistent flag) on $($Adapter.Name)"
    $cr = [BtsCfgMgr]::CM_Query_And_Remove_SubTreeW((Get-Node $Adapter.InstanceId), [ref]$vetoType, $name, 260,
        ([BtsCfgMgr]::CM_REMOVE_UI_NOT_OK -bor [BtsCfgMgr]::CM_REMOVE_NO_RESTART))
    Start-Sleep -Milliseconds 800
    $after = Get-AdapterState $Adapter.Role
    $outcome =
        if     ($cr -eq [BtsCfgMgr]::CR_SUCCESS)       { 'Stopped' }
        elseif ($cr -eq [BtsCfgMgr]::CR_REMOVE_VETOED) { 'Vetoed' }
        else                                           { 'Error' }
    $typeName = if ($vetoType -ge 0 -and $vetoType -lt $VetoTypes.Count) { $VetoTypes[$vetoType] } else { "$vetoType" }
    Log 'INFO' ("  result: {0} (code 0x{1:X}); veto type: {2}; veto name: '{3}'" -f $outcome, $cr, $typeName, $name.ToString())
    Log 'INFO' "  adapter afterwards: $($after.Text)"
    Write-RecentVetoes $began
    [pscustomobject]@{ Outcome = $outcome; Code = $cr; VetoType = $typeName; VetoName = $name.ToString(); After = $after }
}

# Starts the adapter again after a successful non-persistent stop, and waits for the stack.
function Restore-Adapter {
    param($Adapter)
    $state = Get-AdapterState $Adapter.Role
    if (-not $state.Started) {
        $cr = [BtsCfgMgr]::CM_Setup_DevNode((Get-Node $Adapter.InstanceId), [BtsCfgMgr]::CM_SETUP_DEVNODE_READY)
        Log 'INFO' ("  restart requested (CM_Setup_DevNode -> 0x{0:X})" -f $cr)
    }
    try { $radio = Get-BluetoothRadio; if ($radio -and "$($radio.State)" -ne 'On') { Set-BluetoothRadio 'On' } }
    catch { Log 'WARN' "  could not turn the radio on: $($_.Exception.Message)" }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $state = Get-AdapterState $Adapter.Role
        # The radio object only exists once the adapter is back.
        if ($state.Started -and -not $state.EnumeratorUp) {
            try { $radio = Get-BluetoothRadio; if ($radio -and "$($radio.State)" -ne 'On') { Set-BluetoothRadio 'On' } } catch { }
        }
    } while (-not ($state.Started -and $state.EnumeratorUp) -and (Get-Date) -lt $deadline)

    Log 'INFO' "  restored: $($state.Text); radio: $(Get-RadioStateText)"
    return ($state.Started -and $state.EnumeratorUp)
}

# ---------------------------------------------------------------- main

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mode = if ($Execute) { 'EXECUTE' } else { 'REPORT ONLY (nothing will be changed)' }
Log 'INFO' "BluetoothSwitcher stop probe. Mode: $mode. Elevated: $elevated. Log: $LogPath"
if ($Label) { Log 'INFO' "LABEL: $Label" }
$steam = @(Get-Process steam -ErrorAction SilentlyContinue)
foreach ($s in $steam) { Log 'INFO' "Steam: pid $($s.Id), started $($s.StartTime.ToString('HH:mm:ss'))" }
Log 'INFO' "Last boot: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Report 'Current state'
Log 'INFO' '--- Removal vetoes in the last 24 hours ---'
Write-RecentVetoes (Get-Date).AddHours(-24)

if (-not $Execute) {
    Log 'INFO' 'Report complete. Nothing was changed. Add -Execute in an elevated PowerShell to run the tests.'
    exit 0
}

if (-not $elevated) { Log 'ERROR' 'Not elevated. Open PowerShell as administrator. This script never requests elevation.'; exit 1 }

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) { Log 'ERROR' 'A switch or another probe is running. Nothing was changed.'; exit 4 }

$exit = 1
try {
    $internal = Get-AdapterState 'Internal'; $external = Get-AdapterState 'External'
    if ($internal.NeedsRestart -or $external.NeedsRestart) {
        Log 'ERROR' 'An adapter is flagged as needing a restart. Restart Windows first; the tests would tell us nothing now. Nothing was changed.'
        exit 1
    }
    $active = @($internal, $external | Where-Object { $_.Started -and $_.EnumeratorUp })
    $idle   = @($internal, $external | Where-Object { $_.Status -eq 'Disabled' })
    if ($active.Count -ne 1 -or $idle.Count -ne 1) {
        Log 'ERROR' 'Need exactly one active and one disabled adapter. Nothing was changed.'
        exit 1
    }
    $adapter = $active[0]
    Log 'INFO' "Active adapter under test: $($adapter.Role) / $($adapter.Name)"

    # ---- Test 1: clean, non-persistent stop request with the radio on
    $t1 = Invoke-StopAttempt $adapter 'TEST 1 (radio on)'
    $t1Clean = (-not $t1.After.NeedsRestart) -and (-not $t1.After.MarkedDisabled)
    if ($t1.Outcome -eq 'Stopped') { Log 'INFO' '  the adapter stopped; starting it again.' }
    $restored1 = Restore-Adapter $adapter

    # ---- Test 2: the same request after turning the radio off
    $t2 = $null; $restored2 = $true; $pairedAfterOff = @()
    if ($StopRequestOnly) {
        Log 'INFO' 'TEST 2 skipped: -StopRequestOnly.'
    }
    elseif ($t1.Outcome -eq 'Vetoed' -and $restored1 -and $t1Clean) {
        Log 'INFO' 'TEST 2: turning the Bluetooth radio off first.'
        try {
            Set-BluetoothRadio 'Off'
            Start-Sleep -Seconds 3
            $pairedAfterOff = Get-PairedDevices
            Log 'INFO' "  paired device nodes still present with the radio off: $($pairedAfterOff.Count)"
            foreach ($p in $pairedAfterOff) { Log 'INFO' "    $($p.Name)" }
            $t2 = Invoke-StopAttempt $adapter 'TEST 2 (radio off)'
            if ($t2.Outcome -eq 'Stopped') { Log 'INFO' '  the adapter stopped; starting it again.' }
        }
        catch { Log 'ERROR' "  test 2 failed: $($_.Exception.Message)" }
        finally { $restored2 = Restore-Adapter $adapter }
    }
    elseif ($t1.Outcome -ne 'Vetoed') {
        Log 'INFO' 'TEST 2 skipped: test 1 was not vetoed, so there is nothing to work around right now.'
    }
    else {
        Log 'WARN' 'TEST 2 skipped: the state after test 1 was not clean.'
    }

    # ---- Conclusions
    Write-Report 'Final state'
    $final = Get-AdapterState $adapter.Role
    Log 'INFO' '=== CONCLUSIONS ==='
    if ($Label) { Log 'INFO' "LABEL: $Label" }
    Log 'INFO' ("BLOCKED RIGHT NOW: {0}" -f $(if ($t1.Outcome -eq 'Vetoed') { "YES, by $($t1.VetoType) '$($t1.VetoName)'" } elseif ($t1.Outcome -eq 'Stopped') { 'no' } else { "unknown (error code 0x$('{0:X}' -f $t1.Code))" }))
    Log 'INFO' ("Test 1, radio on : {0}{1}" -f $t1.Outcome, $(if ($t1.Outcome -eq 'Vetoed') { " by $($t1.VetoType) '$($t1.VetoName)'" } else { '' }))
    Log 'INFO' "  a refused stop left NO restart flag and NO persistent 'disabled' flag: $t1Clean"
    if ($t2) {
        Log 'INFO' ("Test 2, radio off: {0}{1}" -f $t2.Outcome, $(if ($t2.Outcome -eq 'Vetoed') { " by $($t2.VetoType) '$($t2.VetoName)'" } else { '' }))
        Log 'INFO' "  paired device nodes that survived the radio being off: $($pairedAfterOff.Count)"
    }
    $back = $final.Started -and $final.EnumeratorUp -and -not $final.NeedsRestart -and -not $final.MarkedDisabled
    Log 'INFO' "Adapter is back exactly as before: $back"
    if (-not $back) {
        Log 'WARN' 'The adapter is NOT back as before. Nothing persistent was written, so restarting Windows restores it.'
        Log 'WARN' "Or try, as administrator: pnputil /restart-device `"$($adapter.InstanceId)`""
    }
    $exit = if ($back) { 0 } else { 3 }
}
catch {
    Log 'ERROR' "Unexpected error: [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
    if ($_.InvocationInfo) { Log 'ERROR' "  at line $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim())" }
    try { Write-Report 'State after the error' } catch { }
    $exit = 3
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    Log 'INFO' "Exit code: $exit."
}
exit $exit
