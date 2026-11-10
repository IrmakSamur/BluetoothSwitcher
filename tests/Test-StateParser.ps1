<#
.SYNOPSIS
    Tests Read-BluetoothDevices and Get-State from poc/Switch-Adapter.ps1.

.DESCRIPTION
    SAFE: changes no device and needs no administrator rights.
      1. Canned pnputil XML: started, disabled, problem, missing, empty, garbage.
      2. Unless -SkipLive: one read-only "pnputil /enum-devices" on this machine,
         checking that the XML status of each real adapter equals pnputil's
         plain-text status.

    Exit code = number of failed checks.
#>
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\poc\Switch-Adapter.ps1'),
    [switch]$SkipLive
)
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -in 'Read-BluetoothDevices', 'Get-State') { . ([scriptblock]::Create($f.Extent.Text)) }
}

$script:failed = 0
function Check {
    param([string]$Name, $Got, $Want)
    $ok = ("$Got" -eq "$Want")
    if (-not $ok) { $script:failed++ }
    "{0} {1,-52} got={2} want={3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Name, $Got, $Want
}

$INT = 'USB\VID_0489&PID_E139&MI_00\9&20D79C11&0&0000'
$EXT = 'USB\VID_33FA&PID_0012\B&1DBEFB94&0&1'
$BRB = 'BTH\MS_BTHBRB\c&399fdf75&0&1'
$head = '<?xml version="1.0" encoding="utf-8"?>' + "`n" +
        '<PnpUtil Version="10.0.26300" Command="/enum-devices /connected /class Bluetooth /format xml">'
$foot = '</PnpUtil>'

# Same shape as real pnputil output: lower-case instance IDs, '&' escaped, nested elements.
function Dev {
    param([string]$Id, [string]$Status)
    "    <Device InstanceId=`"$($Id.ToLower() -replace '&', '&amp;')`">`n" +
    "        <DeviceDescription>x</DeviceDescription>`n        <Status>$Status</Status>`n" +
    "        <DriverName>oem1.inf</DriverName>`n    </Device>"
}

$script:Pnputil = Join-Path $PSScriptRoot 'mock\canned-pnputil.ps1'

'--- canned XML ---'
$global:Canned = @($head, (Dev $BRB 'Started'), (Dev $INT 'Disabled'), (Dev $EXT 'Started'), $foot)
$e = Get-State $EXT; $i = Get-State $INT
Check 'external active: external IsActive'          $e.IsActive   $true
Check 'external active: external IsDisabled'        $e.IsDisabled $false
Check 'external active: internal IsDisabled'        $i.IsDisabled $true
Check 'external active: internal IsActive'          $i.IsActive   $false
Check 'instance ID match ignores case'              $e.Status     'Started'

$global:Canned = @($head, (Dev $BRB 'Started'), (Dev $INT 'Started'), (Dev $EXT 'Disabled'), $foot)
$e = Get-State $EXT; $i = Get-State $INT
Check 'internal active: internal IsActive'          $i.IsActive   $true
Check 'internal active: external IsDisabled'        $e.IsDisabled $true

$global:Canned = @($head, (Dev $INT 'Disabled'), (Dev $EXT 'Disabled'), $foot)
$e = Get-State $EXT; $i = Get-State $INT
Check 'both disabled: external IsDisabled'          $e.IsDisabled $true
Check 'both disabled: internal IsDisabled'          $i.IsDisabled $true
Check 'both disabled: EnumeratorUp'                 $e.EnumeratorUp $false

$global:Canned = @($head, (Dev $INT 'Disabled'), (Dev $EXT 'Started'), $foot)
$e = Get-State $EXT
Check 'started, no enumerator: IsRunning'           $e.IsRunning  $true
Check 'started, no enumerator: IsActive'            $e.IsActive   $false

$global:Canned = @($head, (Dev $INT 'Problem'), (Dev $EXT 'Disabled'), $foot)
$i = Get-State $INT
Check 'problem: IsDisabled'                         $i.IsDisabled $false
Check 'problem: IsRunning'                          $i.IsRunning  $false
Check 'problem: Status'                             $i.Status     'Problem'

$global:Canned = @($head, (Dev $EXT 'Disabled'), $foot)
$e = Get-State $EXT; $i = Get-State $INT
Check 'single device: external IsDisabled'          $e.IsDisabled $true
Check 'single device: missing adapter Status'       $i.Status     'NotConnected'
Check 'single device: missing adapter IsDisabled'   $i.IsDisabled $false

$global:Canned = @($head, 'No devices were found on the system.', $foot)
$e = Get-State $EXT
Check 'no devices: Readable'                        $e.Readable   $true
Check 'no devices: Status'                          $e.Status     'NotConnected'

$global:Canned = @('garbage <<<')
$e = Get-State $EXT
Check 'garbage: Readable'                           $e.Readable   $false
Check 'garbage: IsDisabled/IsActive'                "$($e.IsDisabled)/$($e.IsActive)" 'False/False'

if (-not $SkipLive) {
    '--- live read-only pnputil on this machine ---'
    $script:Pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $map = Read-BluetoothDevices
    "devices parsed: $($map.Count)"
    $usb = @($map.Keys | Where-Object { $_ -like 'usb\*' } | Sort-Object)
    if ($usb.Count -eq 0) { 'no USB Bluetooth adapters connected; nothing to compare.' }
    foreach ($id in $usb) {
        $text = (& $script:Pnputil /enum-devices /instanceid $id | Select-String '^Status:').Line -replace '^Status:\s*', ''
        Check "live: xml status = text status ($($id.Substring(0, 21)))" (Get-State $id).Status "$text".Trim()
    }
}

"parser checks failed: $script:failed"
exit $script:failed
