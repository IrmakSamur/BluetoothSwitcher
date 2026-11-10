<#
.SYNOPSIS
    Read-only proof of concept: detect the Bluetooth adapters and report their status.

.DESCRIPTION
    Makes no changes to any device. Uses only Get-PnpDevice / Get-PnpDeviceProperty.
    Does not require administrator rights.

    Adapters are discovered by what they are (present USB devices in the Bluetooth
    class driven by BTHUSB), not by a fixed instance ID, and classified as internal
    or external from properties Windows reports about them.

.PARAMETER AsJson
    Emit the result as JSON instead of formatted text.
#>
[CmdletBinding()]
param([switch]$AsJson)

$ErrorActionPreference = 'Stop'

# Hardware IDs seen during the investigation. Used only as a cross-check;
# discovery and classification do not depend on them.
$ExpectedHardwareId = @{
    Internal = 'USB\VID_0489&PID_E139&MI_00'
    External = 'USB\VID_33FA&PID_0012'
}

function Get-Prop {
    param([string]$InstanceId, [string]$Key)
    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue
    if ($p) { $p.Data } else { $null }
}

$allBluetooth = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue)

# A radio is a USB-enumerated Bluetooth-class device whose function driver is BTHUSB.
$radioNodes = @($allBluetooth | Where-Object {
    $_.InstanceId -like 'USB\*' -and (Get-Prop $_.InstanceId 'DEVPKEY_Device_Service') -eq 'BTHUSB'
})
$present = @($radioNodes | Where-Object { $_.Present })
$phantom = @($radioNodes | Where-Object { -not $_.Present })

$adapters = foreach ($dev in $present) {
    $id          = $dev.InstanceId
    $hardwareIds = @(Get-Prop $id 'DEVPKEY_Device_HardwareIds')
    $builtIn     = [bool](Get-Prop $id 'DEVPKEY_Device_InLocalMachineContainer')
    $removal     = Get-Prop $id 'DEVPKEY_Device_RemovalPolicy'
    $problem     = [int](Get-Prop $id 'DEVPKEY_Device_ProblemCode')
    $children    = @(Get-Prop $id 'DEVPKEY_Device_Children')
    $role        = if ($builtIn) { 'Internal' } else { 'External' }

    # The Bluetooth stack is hosted on this radio if the Microsoft enumerator child is present and OK.
    $enumerator = $children | Where-Object { $_ -like 'BTH\MS_BTHBRB\*' } | Select-Object -First 1
    $stackUp = $false
    if ($enumerator) {
        $e = Get-PnpDevice -InstanceId $enumerator -ErrorAction SilentlyContinue
        $stackUp = [bool]($e -and $e.Present -and $e.Status -eq 'OK')
    }

    $state =
        if     ($problem -eq 22)                         { 'Disabled' }
        elseif ($problem -ne 0)                          { "Error (problem code $problem)" }
        elseif ($dev.Status -eq 'OK' -and $stackUp)      { 'Active' }
        elseif ($dev.Status -eq 'OK')                    { 'Started, stack not up' }
        else                                             { "Unknown ($($dev.Status))" }

    [pscustomobject]@{
        Role             = $role
        Location         = if ($builtIn) { 'Upstairs' } else { 'Downstairs' }
        Name             = $dev.FriendlyName
        BusDescription   = Get-Prop $id 'DEVPKEY_Device_BusReportedDeviceDesc'
        State            = $state
        ProblemCode      = $problem
        StackHosted      = $stackUp
        InstanceId       = $id
        HardwareId       = $hardwareIds | Select-Object -Last 1
        MatchesExpected  = ($hardwareIds -contains $ExpectedHardwareId[$role])
        RemovalPolicy    = $removal
        DriverVersion    = Get-Prop $id 'DEVPKEY_Device_DriverVersion'
        DriverProvider   = Get-Prop $id 'DEVPKEY_Device_DriverProvider'
        Parent           = Get-Prop $id 'DEVPKEY_Device_Parent'
        LocationInfo     = Get-Prop $id 'DEVPKEY_Device_LocationInfo'
        PhantomInstances = @($phantom | Where-Object {
                               ($_.InstanceId -replace '\\[^\\]+$', '') -eq ($id -replace '\\[^\\]+$', '')
                           }).Count
    }
}
$adapters = @($adapters | Sort-Object Role -Descending)

$internal = @($adapters | Where-Object Role -eq 'Internal')
$external = @($adapters | Where-Object Role -eq 'External')
$active   = @($adapters | Where-Object State -eq 'Active')

$problems = @()
if ($internal.Count -ne 1) { $problems += "Expected exactly 1 internal adapter, found $($internal.Count)." }
if ($external.Count -ne 1) { $problems += "Expected exactly 1 external adapter, found $($external.Count)." }
foreach ($a in $adapters) {
    if (-not $a.MatchesExpected) { $problems += "$($a.Role) adapter '$($a.Name)' has an unexpected hardware ID ($($a.HardwareId))." }
}
$notDisabled = @($adapters | Where-Object ProblemCode -ne 22)
if ($notDisabled.Count -gt 1) { $problems += 'More than one adapter is enabled; Windows supports only one active adapter.' }

$overall =
    if     ($problems.Count -gt 0)  { 'Inconsistent' }
    elseif ($active.Count -eq 1)    { "$($active[0].Location) ($($active[0].Role) adapter active)" }
    elseif ($active.Count -eq 0)    { 'No active adapter' }
    else                            { 'Inconsistent' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
$service  = Get-Service bthserv -ErrorAction SilentlyContinue

$result = [pscustomobject]@{
    Timestamp       = (Get-Date).ToString('s')
    Overall         = $overall
    SafeToSwitch    = ($problems.Count -eq 0 -and $active.Count -eq 1)
    Problems        = $problems
    Elevated        = $elevated
    BluetoothService = if ($service) { "$($service.Status)" } else { 'Not found' }
    Adapters        = $adapters
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 4
    return
}

"BluetoothSwitcher - adapter status (read-only)"
"Time:              $($result.Timestamp)"
"Current location:  $($result.Overall)"
"Safe to switch:    $($result.SafeToSwitch)"
"Elevated shell:    $($result.Elevated)"
"bthserv service:   $($result.BluetoothService)"
foreach ($a in $adapters) {
    ""
    "[$($a.Location)] $($a.Role): $($a.Name) ($($a.BusDescription))"
    "  State:            $($a.State)"
    "  Stack hosted:     $($a.StackHosted)"
    "  Instance ID:      $($a.InstanceId)"
    "  Hardware ID:      $($a.HardwareId)  (expected: $($a.MatchesExpected))"
    "  Driver:           $($a.DriverProvider) $($a.DriverVersion)"
    "  Parent:           $($a.Parent)  [$($a.LocationInfo)]"
    "  Removal policy:   $($a.RemovalPolicy)"
    "  Stale instances:  $($a.PhantomInstances)"
}
if ($problems.Count -gt 0) {
    ""
    "PROBLEMS:"
    $problems | ForEach-Object { "  - $_" }
}
