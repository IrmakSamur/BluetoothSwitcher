# Simulated pnputil for the switching scenarios.
# Touches no real device: all state lives in $global:Sim (set up by Invoke-SwitchScenario.ps1).
$sim = $global:Sim
if ($null -eq $sim) { throw 'fake-pnputil.ps1 must be run through Invoke-SwitchScenario.ps1.' }
$verb = "$($args[0])"

function Step-Transitions {
    foreach ($t in @($sim.Pending)) {
        $t.Reads--
        if ($t.Reads -le 0) {
            & $t.Apply
            $sim.Pending = @($sim.Pending | Where-Object { $_ -ne $t })
        }
    }
}

switch ($verb) {
    '/enum-devices' {
        $sim.Reads++
        if ($sim.StopOnRead -contains $sim.Reads) {
            # The uncatchable stop that skipped 'catch' in the first real run.
            throw [System.Management.Automation.PipelineStoppedException]::new()
        }
        Step-Transitions
        if ($sim.GarbageOnRead -contains $sim.Reads) { 'this is not xml <<<'; exit 0 }
        if ($sim.FailOnRead -contains $sim.Reads)    { 'Access denied.'; exit 5 }
        '<?xml version="1.0" encoding="utf-8"?>'
        '<PnpUtil Version="sim">'
        foreach ($id in $sim.Status.Keys) {
            '    <Device InstanceId="{0}"><Status>{1}</Status></Device>' -f ($id -replace '&', '&amp;'), $sim.Status[$id]
        }
        if ($sim.Enum) { '    <Device InstanceId="BTH\MS_BTHBRB\c&amp;sim&amp;0&amp;1"><Status>Started</Status></Device>' }
        '</PnpUtil>'
        exit 0
    }
    '/disable-device' {
        $id = "$($args[1])"
        $sim.Commands += "disable $id"
        $code = [int]$sim.DisableExit[$id]
        if ($code -ne 0) { "Failed to disable device: $id"; exit $code }
        $sim.Pending = @($sim.Pending | Where-Object { $_.Id -ne $id })   # a disable cancels a pending start
        if (-not ($sim.NeverStops -contains $id)) {
            $wasStarted = ($sim.Status[$id] -eq 'Started')
            $apply = { $sim.Status[$id] = 'Disabled'; if ($wasStarted) { $sim.Enum = $false } }.GetNewClosure()
            $sim.Pending += @{ Id = $id; Kind = 'stop'; Reads = $sim.StopDelayReads; Apply = $apply }
        }
        'Device disabled successfully.'; exit 0
    }
    '/enable-device' {
        $id = "$($args[1])"
        $sim.Commands += "enable $id"
        # Safety invariant: an enable is only legal while every other adapter is
        # Disabled with no start pending.
        foreach ($other in @($sim.Status.Keys)) {
            if ($other -ne $id -and $sim.Status[$other] -ne 'Disabled') {
                $sim.Violations += "enable $id while $other is $($sim.Status[$other])"
            }
        }
        foreach ($p in @($sim.Pending)) {
            if ($p.Id -ne $id -and $p.Kind -eq 'start') { $sim.Violations += "enable $id while a start of $($p.Id) is pending" }
        }
        $code = [int]$sim.EnableExit[$id]
        if ($code -ne 0) { "Failed to enable device: $id"; exit $code }
        if ($sim.NeverStarts -contains $id) {
            $sim.Status[$id] = 'Problem'
        } else {
            $apply = { $sim.Status[$id] = 'Started'; $sim.Enum = $true }.GetNewClosure()
            $delay = if ($sim.StartDelayFor.ContainsKey($id)) { $sim.StartDelayFor[$id] } else { $sim.StartDelayReads }
            $sim.Pending += @{ Id = $id; Kind = 'start'; Reads = $delay; Apply = $apply }
        }
        'Device enabled successfully.'; exit 0
    }
    default { "unknown verb $verb"; exit 87 }
}
