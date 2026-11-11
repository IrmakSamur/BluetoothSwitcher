<#
.SYNOPSIS
    Harmless stand-in for poc/Switch-Adapter.ps1, used to test how the app launches
    and follows the real engine.

.DESCRIPTION
    Takes the same parameters as the real script and writes a log in the same format,
    but never runs pnputil and touches no device. Its behaviour is chosen by its own
    file name, because an elevated process does not inherit environment variables:

      engine-ok.ps1     logs the four steps, "Exit code: 0.", exits 0
      engine-fail.ps1   logs a failure and rollback, "Exit code: 2.", exits 2
      engine-die.ps1    logs two steps, then exits 77 WITHOUT the final log line
      engine-chatty.ps1 logs 200 lines quickly, then finishes normally
      engine-slow.ps1   logs its process ID, waits 20 s, then finishes normally
      engine-late.ps1   waits 4 s, then finishes normally (outlives a short timeout)
#>
param(
    [string]$Target,
    [switch]$Execute,
    [string]$LogPath
)
$mode = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path) -replace '^engine-', ''

function Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8   # same call as the real script
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Log 'INFO' "FAKE ENGINE (no device is touched). Mode: $mode. Requested target: $Target. Execute: $Execute."
Log 'INFO' "PID: $PID"
Log 'INFO' "Elevated: $elevated."

switch ($mode) {
    'die' {
        Log 'INFO' 'Step 1/4: disable (simulated).'
        Log 'INFO' 'Step 2/4: wait (simulated).'
        [Environment]::Exit(77)
    }
    'chatty' { foreach ($i in 1..200) { Log 'INFO' "chatty line $i"; Start-Sleep -Milliseconds 10 } }
    'slow' { Log 'INFO' 'Step 1/4: disable (simulated).'; Start-Sleep -Seconds 20 }
    'late' { Log 'INFO' 'Step 1/4: disable (simulated).'; Start-Sleep -Seconds 4 }
}

if ($mode -eq 'fail') {
    Log 'INFO'  'Step 1/4: disable (simulated).'
    Log 'ERROR' 'The target adapter did not start.'
    Log 'WARN'  'ROLLBACK: restoring (simulated).'
    Log 'INFO'  'Exit code: 2.'
    exit 2
}

foreach ($step in 'Step 1/4: disable (simulated).', 'Step 2/4: wait (simulated).',
                  'Step 3/4: enable (simulated).', 'Step 4/4: wait (simulated).') {
    Log 'INFO' $step
    Start-Sleep -Milliseconds 150
}
Log 'INFO' 'SUCCESS: (simulated).'
Log 'INFO' 'Exit code: 0.'
exit 0
