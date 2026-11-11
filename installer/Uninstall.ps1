<#
.SYNOPSIS
    Removes BluetoothSwitcher: the install folder and the Start menu shortcut.

.DESCRIPTION
    Run from a PowerShell you opened as administrator:

        powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\BluetoothSwitcher\Uninstall.ps1"

    The script never requests elevation itself. It does not touch any Bluetooth
    device: whichever adapter is active stays active, and the other stays disabled.
    Nothing else was installed (no service, scheduled task, or registry entry).

.PARAMETER RemoveLogs
    Also delete the switch logs in %LOCALAPPDATA%\BluetoothSwitcher.

.PARAMETER WhatIf
    Print what would be removed without changing anything.

.PARAMETER TestInstall
    For testing only: allows removing a non-elevated test install outside Program Files.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$ShortcutDir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
    [switch]$RemoveLogs,
    [switch]$WhatIf,
    [switch]$TestInstall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $InstallDir) {
    # Default: the folder this script is in, when it is an install folder.
    $InstallDir = if (Test-Path -LiteralPath (Join-Path $here 'BluetoothSwitcher.exe')) { $here } else { Join-Path $env:ProgramFiles 'BluetoothSwitcher' }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$shortcut   = Join-Path $ShortcutDir 'BluetoothSwitcher.lnk'

function Step { param([string]$Text) Write-Host "[uninstall] $Text" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ((Split-Path -Leaf $InstallDir) -ne 'BluetoothSwitcher') {
    throw "Refusing to remove '$InstallDir': the folder is not named 'BluetoothSwitcher'."
}
if ((Test-Path -LiteralPath $InstallDir) -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'BluetoothSwitcher.exe'))) {
    throw "Refusing to remove '$InstallDir': it does not contain BluetoothSwitcher.exe."
}
if (-not $WhatIf -and -not $TestInstall -and -not $elevated) {
    throw 'Not elevated. Open PowerShell as administrator and run this script again. It never requests elevation itself.'
}
if (@(Get-Process -Name 'BluetoothSwitcher' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'BluetoothSwitcher is running. Close it (and wait for any switch to finish), then run this again.'
}

$logs = Join-Path $env:LOCALAPPDATA 'BluetoothSwitcher'
$targets = @()
if (Test-Path -LiteralPath $shortcut)   { $targets += "shortcut $shortcut" }
if (Test-Path -LiteralPath $InstallDir) { $targets += "folder $InstallDir" }
if ($RemoveLogs -and (Test-Path -LiteralPath $logs)) { $targets += "logs $logs" }

if ($targets.Count -eq 0) { Step 'Nothing to remove.'; exit 0 }
if ($WhatIf) {
    foreach ($t in $targets) { Step "Would remove $t" }
    Step 'Preview complete. Nothing was changed.'
    exit 0
}

# The script may be running from inside the folder it removes.
Set-Location -LiteralPath $env:TEMP

if (Test-Path -LiteralPath $shortcut) {
    Remove-Item -LiteralPath $shortcut -Force
    Step "Removed shortcut $shortcut"
}
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Step "Removed folder $InstallDir"
}
if ($RemoveLogs -and (Test-Path -LiteralPath $logs)) {
    Remove-Item -LiteralPath $logs -Recurse -Force
    Step "Removed logs $logs"
}
Step 'Done. Bluetooth adapters were not changed.'
