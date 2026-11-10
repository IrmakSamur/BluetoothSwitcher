<#
.SYNOPSIS
    Runs every test for the switching PoC.

.DESCRIPTION
    SAFE to run at any time: no administrator rights, no real device is changed.
    The only contact with real hardware is read-only "pnputil /enum-devices"
    (skip it with -SkipLive).

      1. Syntax check of the PoC scripts.
      2. State parser tests (Test-StateParser.ps1).
      3. Mocked switching scenarios (Invoke-SwitchScenario.ps1), each in its own process.

    Exit code 0 when everything passes, 1 otherwise.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>
param(
    [switch]$SkipLive,
    [switch]$ShowLogs   # print the full script log of every scenario
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
function Get-DeviceSnapshot { (& $pnputil /enum-devices /class Bluetooth /connected | Out-String) }
$before = if ($SkipLive) { $null } else { Get-DeviceSnapshot }

'=== 1. syntax ==='
foreach ($file in Get-ChildItem -Path (Join-Path $root 'poc'), $PSScriptRoot -Filter *.ps1 -Recurse) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) { $failures++ }
    "{0} {1}" -f $(if ($errors.Count) { 'FAIL' } else { 'PASS' }), $file.FullName.Substring($root.Length + 1)
    foreach ($e in $errors) { "     line $($e.Extent.StartLineNumber): $($e.Message)" }
}

'=== 2. state parser ==='
$parserArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Test-StateParser.ps1'))
if ($SkipLive) { $parserArgs += '-SkipLive' }
& powershell.exe @parserArgs
if ($LASTEXITCODE -ne 0) { $failures++ }

'=== 3. mocked switching scenarios ==='
$scenarios = 'happy', 'stop-in-step2', 'stop-in-step4', 'stop-twice', 'target-never-starts', 'target-slow-start',
             'target-wont-disable', 'disable-refused', 'source-never-stops', 'rollback-fails', 'unreadable-polls',
             'already-on-target', 'both-disabled', 'both-enabled'
$passed = 0
foreach ($name in $scenarios) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-SwitchScenario.ps1') -Scenario $name
    $result = @($out | Where-Object { $_ -like 'RESULT*' })
    if ($ShowLogs) { $out | Where-Object { $_ -notlike 'RESULT*' } | ForEach-Object { "    $_" } }
    if ($result.Count -eq 1 -and $result[0] -match 'PASS$') { $passed++; $result[0] }
    else {
        $failures++
        if ($result.Count) { $result } else { "RESULT $name produced no result line FAIL" }
        if (-not $ShowLogs) { $out | Select-Object -Last 12 | ForEach-Object { "    $_" } }
    }
}
"scenarios passed: $passed of $($scenarios.Count)"

if (-not $SkipLive) {
    '=== 4. real devices untouched ==='
    $same = ($before -eq (Get-DeviceSnapshot))
    if (-not $same) { $failures++ }
    "{0} real Bluetooth device listing identical before and after" -f $(if ($same) { 'PASS' } else { 'FAIL' })
}

''
if ($failures) { "FAILED: $failures problem(s)."; exit 1 }
'ALL TESTS PASSED.'
exit 0
