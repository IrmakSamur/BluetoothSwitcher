<#
.SYNOPSIS
    Builds the installable package in dist\BluetoothSwitcher. Needs no administrator rights.

.DESCRIPTION
    1. Runs the test suite (skip with -SkipTests).
    2. Builds the WinUI 3 app (Release, win-x64). The build embeds the SHA-256 of
       poc\Switch-Adapter-Next.ps1 in the app and copies that script next to the exe.
    3. Adds Uninstall.ps1.
    4. Writes package.sha256, a list of every file and its hash, which Install.ps1
       uses to detect a damaged or incomplete copy.

    Changes nothing outside the repository. Install with installer\Install.ps1.
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    # Also write dist\BluetoothSwitcher-<version>.zip: the package, Install.ps1 and INSTALL.txt.
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$package = Join-Path $root 'dist\BluetoothSwitcher'
$env:DOTNET_NOLOGO = '1'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

if (-not $SkipTests) {
    'Running tests...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1') | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed. Package not built.' }
}

if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }

'Building...'
# The package is the Release BUILD output, not "dotnet publish" output: publish leaves
# out the compiled XAML resources (BluetoothSwitcher.pri, *.xbf) for this unpackaged
# WinUI 3 app, and the result crashes at startup.
$project  = Join-Path $root 'src\BluetoothSwitcher.App'
$buildOut = Join-Path $project 'bin\x64\Release\net10.0-windows10.0.19041.0\win-x64'
if (Test-Path -LiteralPath $buildOut) { Remove-Item -LiteralPath $buildOut -Recurse -Force }
& dotnet build $project -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed with exit code $LASTEXITCODE." }

New-Item -ItemType Directory -Path (Split-Path -Parent $package) -Force | Out-Null
Copy-Item -LiteralPath $buildOut -Destination $package -Recurse
Get-ChildItem -LiteralPath $package -Recurse -File -Filter *.pdb | Remove-Item -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination $package

foreach ($required in 'BluetoothSwitcher.exe', 'BluetoothSwitcher.pri', 'App.xbf', 'MainWindow.xbf', 'Switch-Adapter.ps1', 'Uninstall.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $package $required))) { throw "Package is missing $required." }
}

# The packaged script must be byte-identical to the validated one in poc\.
$sourceHash  = (Get-FileHash -LiteralPath (Join-Path $root 'poc\Switch-Adapter-Next.ps1') -Algorithm SHA256).Hash
$packageHash = (Get-FileHash -LiteralPath (Join-Path $package 'Switch-Adapter.ps1') -Algorithm SHA256).Hash
if ($sourceHash -ne $packageHash) { throw 'The packaged switch script differs from poc\Switch-Adapter-Next.ps1.' }

# File list with hashes. package.sha256 itself is not listed.
$manifest = Join-Path $package 'package.sha256'
$lines = Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($package.Length + 1)
}
Set-Content -LiteralPath $manifest -Value $lines -Encoding UTF8

$size = (Get-ChildItem -LiteralPath $package -Recurse -File | Measure-Object Length -Sum).Sum
''
"Package:        $package"
"Files:          $($lines.Count)"
"Size:           {0:n0} MB" -f ($size / 1MB)
"Switch script:  SHA-256 $packageHash"
if ($Zip) {
    [xml]$props = Get-Content -LiteralPath (Join-Path $root 'Directory.Build.props')
    $version = "$($props.Project.PropertyGroup.Version)".Trim()
    $stage   = Join-Path $root "dist\release-$version"
    $zipPath = Join-Path $root "dist\BluetoothSwitcher-$version.zip"
    if (Test-Path -LiteralPath $stage)   { Remove-Item -LiteralPath $stage -Recurse -Force }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $package -Destination (Join-Path $stage 'BluetoothSwitcher') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install.ps1') -Destination $stage
    @"
BluetoothSwitcher $version

This is a personal tool for one specific PC. The two Bluetooth adapters are identified by
hard-coded hardware IDs; on other hardware it will show "Adapter not found" and do nothing.

Requirements: Windows 11 (x64) and the .NET 10 Desktop Runtime.

Install or update
  1. Extract this zip to any folder.
  2. Close BluetoothSwitcher if it is running.
  3. Open PowerShell as administrator, go to the extracted folder, and run:
       powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
     Add -WhatIf to preview without changing anything.
  4. Start "BluetoothSwitcher" from the Start menu. It runs without administrator rights;
     Windows asks for approval once per switch.

The installer copies the app to C:\Program Files\BluetoothSwitcher, restricts write access
to administrators, and creates a Start menu shortcut. It installs no service or scheduled
task and does not touch any Bluetooth device.

Uninstall (PowerShell as administrator)
       powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\BluetoothSwitcher\Uninstall.ps1"

Switch script SHA-256: $packageHash
"@ | Set-Content -LiteralPath (Join-Path $stage 'INSTALL.txt') -Encoding UTF8
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Remove-Item -LiteralPath $stage -Recurse -Force
    "Release zip:    $zipPath"
    "Zip size:       {0:n0} MB" -f ((Get-Item -LiteralPath $zipPath).Length / 1MB)
    "Zip SHA-256:    $((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash)"
}

''
'Next: open PowerShell as administrator and run installer\Install.ps1 (add -WhatIf to preview).'
