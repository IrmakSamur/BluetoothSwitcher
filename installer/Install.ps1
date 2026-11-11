<#
.SYNOPSIS
    Installs or updates BluetoothSwitcher in C:\Program Files\BluetoothSwitcher.

.DESCRIPTION
    Run from a PowerShell you opened as administrator. The script never requests
    elevation itself. Build the package first with installer\Build-Package.ps1.

    What it does:
      1. Checks the package against its file list (package.sha256).
      2. Copies it to a staging folder next to the install folder and checks it again.
      3. Replaces the install folder with the staging folder.
      4. Makes Administrators the owner and sets permissions so that only SYSTEM and
         Administrators can change the folder; standard users can read and run.
      5. Creates the Start menu shortcut "BluetoothSwitcher" for all users.

    What it does NOT do: it does not start the app, does not touch any Bluetooth
    device, and installs no service, scheduled task, or auto-start entry.

    Updating is the same command again. Uninstall with Uninstall.ps1 in the install folder.

.PARAMETER WhatIf
    Validate the package and print every step without changing anything.
    Works without administrator rights.

.PARAMETER TestInstall
    For testing the installer only: allows a non-elevated install into a folder that
    is NOT under Program Files, and skips the ownership change. The app will refuse
    to switch from such a folder.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$InstallDir  = (Join-Path $env:ProgramFiles 'BluetoothSwitcher'),
    [string]$ShortcutDir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
    [switch]$WhatIf,
    [switch]$TestInstall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $here '..\dist\BluetoothSwitcher' }

# Well-known SIDs, so this works on any display language.
$SID_SYSTEM = '*S-1-5-18'; $SID_ADMINS = '*S-1-5-32-544'; $SID_USERS = '*S-1-5-32-545'

function Step { param([string]$Text) Write-Host "[install] $Text" }

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UnderProgramFiles {
    param([string]$Path)
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemRoot) {
        if ($base -and $Path.StartsWith($base.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Compares every file in $Folder with package.sha256 and reports extra or missing files.
function Test-Package {
    param([string]$Folder)
    $manifest = Join-Path $Folder 'package.sha256'
    if (-not (Test-Path -LiteralPath $manifest)) { throw "No package.sha256 in $Folder. Run installer\Build-Package.ps1 first." }
    $expected = @{}
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ($line -match '^([0-9A-Fa-f]{64})\s\s(.+)$') { $expected[$Matches[2]] = $Matches[1] }
    }
    if ($expected.Count -eq 0) { throw "package.sha256 in $Folder is empty or unreadable." }
    $root = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\')
    $seen = 0
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        $relative = $file.FullName.Substring($root.Length + 1)
        if ($relative -eq 'package.sha256') { continue }
        if (-not $expected.ContainsKey($relative)) { throw "Unexpected file in package: $relative" }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $expected[$relative]) { throw "File is damaged or was changed: $relative" }
        $seen++
    }
    if ($seen -ne $expected.Count) { throw "Package is incomplete: $seen of $($expected.Count) files present in $Folder." }
    return $seen
}

function Invoke-Icacls {
    param([string[]]$Arguments)
    $output = & icacls.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "icacls $($Arguments -join ' ') failed ($LASTEXITCODE): $($output | Select-Object -Last 2)" }
}

# ---------------------------------------------------------------- checks (nothing is changed yet)

$Source     = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$staging    = "$InstallDir.staging"
$shortcut   = Join-Path $ShortcutDir 'BluetoothSwitcher.lnk'
$elevated   = Test-Elevated

if ((Split-Path -Leaf $InstallDir) -ne 'BluetoothSwitcher') {
    throw "The install folder must be named 'BluetoothSwitcher' (got '$InstallDir'). This protects other folders from being replaced."
}
if ($TestInstall) {
    if ((Test-UnderProgramFiles $InstallDir) -or (Test-UnderProgramFiles $ShortcutDir)) {
        throw '-TestInstall is only for throwaway folders outside Program Files, ProgramData and Windows.'
    }
} elseif (-not $WhatIf -and -not $elevated) {
    throw 'Not elevated. Open PowerShell as administrator and run this script again. It never requests elevation itself.'
}

$count = Test-Package $Source
foreach ($required in 'BluetoothSwitcher.exe', 'BluetoothSwitcher.pri', 'Switch-Adapter.ps1', 'Uninstall.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $Source $required))) { throw "Package is missing $required." }
}
$scriptHash = (Get-FileHash -LiteralPath (Join-Path $Source 'Switch-Adapter.ps1') -Algorithm SHA256).Hash

if (Test-Path -LiteralPath $InstallDir) {
    $existing = @(Get-ChildItem -LiteralPath $InstallDir -Force)
    if ($existing.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'BluetoothSwitcher.exe'))) {
        throw "$InstallDir exists and does not look like a BluetoothSwitcher install. Refusing to replace it."
    }
}

$running = @(Get-Process -Name 'BluetoothSwitcher' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) { throw 'BluetoothSwitcher is running. Close it (and wait for any switch to finish), then run this again.' }

$mode = if ($WhatIf) { 'PREVIEW (nothing will be changed)' } elseif ($TestInstall) { 'TEST INSTALL' } else { 'INSTALL' }
$verb = if (Test-Path -LiteralPath $InstallDir) { 'Update' } else { 'New install' }
Step "Mode:           $mode"
Step "Package:        $Source ($count files verified)"
Step "Switch script:  SHA-256 $scriptHash"
Step "Install folder: $InstallDir ($verb)"
Step "Shortcut:       $shortcut"
Step "Elevated:       $elevated"

$plan = @(
    "Copy the package to $staging and verify every file",
    "Replace $InstallDir with the staging folder",
    $(if ($TestInstall) { 'SKIP ownership change (test install)' } else { "Set owner of $InstallDir to Administrators" }),
    "Set permissions on $InstallDir`: SYSTEM and Administrators full control, Users read and run, nothing inherited",
    "Create Start menu shortcut $shortcut"
)
if ($WhatIf) {
    $n = 0; foreach ($item in $plan) { $n++; Step "Would do $n. $item" }
    Step 'Preview complete. Nothing was changed.'
    exit 0
}

# ---------------------------------------------------------------- install

if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
try {
    Step "1. $($plan[0])"
    Copy-Item -LiteralPath $Source -Destination $staging -Recurse
    [void](Test-Package $staging)

    Step "2. $($plan[1])"
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    Rename-Item -LiteralPath $staging -NewName (Split-Path -Leaf $InstallDir)
}
catch {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}

Step "3. $($plan[2])"
if (-not $TestInstall) {
    Invoke-Icacls @($InstallDir, '/setowner', $SID_ADMINS, '/T', '/C', '/Q')
}

Step "4. $($plan[3])"
# Folder: drop inherited entries, grant exactly three. Children: reset so they inherit from it.
Invoke-Icacls @($InstallDir, '/inheritance:r', '/grant:r', "${SID_SYSTEM}:(OI)(CI)F", "${SID_ADMINS}:(OI)(CI)F", "${SID_USERS}:(OI)(CI)RX", '/Q')
Invoke-Icacls @((Join-Path $InstallDir '*'), '/reset', '/T', '/C', '/Q')

Step "5. $($plan[4])"
if (-not (Test-Path -LiteralPath $ShortcutDir)) { New-Item -ItemType Directory -Path $ShortcutDir -Force | Out-Null }
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath       = Join-Path $InstallDir 'BluetoothSwitcher.exe'
$link.WorkingDirectory = $InstallDir
$link.Description      = 'Switch between the upstairs and downstairs Bluetooth adapters'
$link.Save()

# ---------------------------------------------------------------- verify

[void](Test-Package $InstallDir)
$installedHash = (Get-FileHash -LiteralPath (Join-Path $InstallDir 'Switch-Adapter.ps1') -Algorithm SHA256).Hash
if ($installedHash -ne $scriptHash) { throw 'The installed switch script does not match the package.' }
Step "Installed files verified. Switch script SHA-256 $installedHash"
Step 'Permissions:'
& icacls.exe $InstallDir | Where-Object { $_ -and $_ -notmatch 'Successfully processed' } | ForEach-Object { Write-Host "            $($_.Trim())" }
Step "Owner: $((Get-Acl -LiteralPath $InstallDir).Owner)"
Step 'Done. Start "BluetoothSwitcher" from the Start menu. The app runs without administrator rights.'
Step "To uninstall: run `"$InstallDir\Uninstall.ps1`" from PowerShell opened as administrator."
