<#
.SYNOPSIS
    Read-only: lists which programs hold an open handle on the active Bluetooth adapter
    or on any device below it (paired controllers, HID devices).

.DESCRIPTION
    Windows vetoes stopping an adapter while a program has one of these devices open.
    This script shows who that is WITHOUT trying to stop anything. It needs no
    administrator rights and changes no device state.

    How: it lists the device tree under the active adapter with each device's kernel
    object name, then looks through the handle tables of the processes it is allowed to
    inspect for file handles that point at one of those objects. To read a handle's
    name it makes a temporary copy of the handle in its own process and closes it again;
    the inspected program is not affected.

    Limits: without administrator rights only your own, unelevated programs can be
    inspected (Steam is one). Services such as DeviceAssociationService cannot, so "no
    holder found" does not prove the adapter can be stopped.

.PARAMETER Label
    Free text written to the output and the log, to tell steps of a comparison apart.

.PARAMETER LogPath
    Result file. Default: %LOCALAPPDATA%\BluetoothSwitcher\logs\holders-<timestamp>.log
#>
[CmdletBinding()]
param([string]$Label, [string]$LogPath)

$ErrorActionPreference = 'Stop'
$HardwareIds = 'USB\VID_0489&PID_E139&MI_00', 'USB\VID_33FA&PID_0012'

if (-not $LogPath) {
    $LogPath = Join-Path $env:LOCALAPPDATA ("BluetoothSwitcher\logs\holders-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
function Out-Line { param([string]$Text) Write-Host $Text; Add-Content -LiteralPath $LogPath -Value $Text -Encoding UTF8 }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class BtsHandles
{
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr handle, int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr handle);

    const int SystemExtendedHandleInformation = 64;
    const int ObjectNameInformation = 1;
    const int StatusInfoLengthMismatch = unchecked((int)0xC0000004);
    const uint ProcessDupHandle = 0x0040;
    const uint DuplicateSameAccess = 0x2;
    const int EntrySize = 40;   // SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX on 64-bit Windows

    public sealed class Hit { public int Pid; public string ObjectName; public long Handle; }

    public static int ProcessesInspected;
    public static int ProcessesNotInspectable;
    public static int FileHandlesChecked;
    public static int HandlesTimedOut;

    static string QueryName(IntPtr handle)
    {
        // Disk files (1) and pipes (3) are never Bluetooth devices, and pipes can block.
        uint type = GetFileType(handle);
        if (type == 1 || type == 3) return null;
        IntPtr buffer = Marshal.AllocHGlobal(2048);
        try
        {
            int returned;
            if (NtQueryObject(handle, ObjectNameInformation, buffer, 2048, out returned) != 0) return null;
            int length = Marshal.ReadInt16(buffer);
            IntPtr text = Marshal.ReadIntPtr(buffer, 8);
            return (length <= 0 || text == IntPtr.Zero) ? null : Marshal.PtrToStringUni(text, length / 2);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static List<Hit> Find(string[] deviceObjectNames)
    {
        if (IntPtr.Size != 8) throw new InvalidOperationException("Run this in 64-bit PowerShell.");
        var hits = new List<Hit>();
        ProcessesInspected = ProcessesNotInspectable = FileHandlesChecked = HandlesTimedOut = 0;

        int me = System.Diagnostics.Process.GetCurrentProcess().Id;
        using (var probe = File.OpenRead(Path.Combine(Environment.SystemDirectory, "ntdll.dll")))
        {
            long probeHandle = probe.SafeFileHandle.DangerousGetHandle().ToInt64();

            int size = 1 << 22;
            IntPtr table = Marshal.AllocHGlobal(size);
            try
            {
                int returned, status;
                while ((status = NtQuerySystemInformation(SystemExtendedHandleInformation, table, size, out returned)) == StatusInfoLengthMismatch)
                {
                    Marshal.FreeHGlobal(table);
                    size = Math.Max(size * 2, returned + (1 << 20));
                    table = Marshal.AllocHGlobal(size);
                }
                if (status != 0) throw new InvalidOperationException("NtQuerySystemInformation failed: 0x" + status.ToString("X8"));

                long count = Marshal.ReadInt64(table);
                IntPtr first = IntPtr.Add(table, 16);

                // Which object type number means "File"? Find our own known file handle.
                int fileType = -1;
                for (long i = 0; i < count; i++)
                {
                    IntPtr entry = IntPtr.Add(first, checked((int)(i * EntrySize)));
                    if (Marshal.ReadInt64(entry, 8) == me && Marshal.ReadInt64(entry, 16) == probeHandle)
                    {
                        fileType = (ushort)Marshal.ReadInt16(entry, 30);
                        break;
                    }
                }
                if (fileType < 0) throw new InvalidOperationException("Could not determine the File object type.");

                var processes = new Dictionary<int, IntPtr>();
                for (long i = 0; i < count; i++)
                {
                    IntPtr entry = IntPtr.Add(first, checked((int)(i * EntrySize)));
                    if ((ushort)Marshal.ReadInt16(entry, 30) != fileType) continue;
                    int pid = (int)Marshal.ReadInt64(entry, 8);
                    if (pid == me || pid <= 4) continue;

                    IntPtr process;
                    if (!processes.TryGetValue(pid, out process))
                    {
                        process = OpenProcess(ProcessDupHandle, false, pid);
                        processes[pid] = process;
                        if (process == IntPtr.Zero) ProcessesNotInspectable++; else ProcessesInspected++;
                    }
                    if (process == IntPtr.Zero) continue;

                    long handleValue = Marshal.ReadInt64(entry, 16);
                    IntPtr copy;
                    if (!DuplicateHandle(process, new IntPtr(handleValue), GetCurrentProcess(), out copy, 0, false, DuplicateSameAccess)) continue;
                    FileHandlesChecked++;

                    // A name query can block on some handles; give up on those.
                    var query = Task.Run(() => QueryName(copy));
                    if (!query.Wait(200)) { HandlesTimedOut++; continue; }
                    CloseHandle(copy);
                    string name = query.Result;
                    if (name == null) continue;

                    foreach (string device in deviceObjectNames)
                    {
                        if (name.Equals(device, StringComparison.OrdinalIgnoreCase) ||
                            name.StartsWith(device + "\\", StringComparison.OrdinalIgnoreCase))
                        {
                            hits.Add(new Hit { Pid = pid, ObjectName = device, Handle = handleValue });
                            break;
                        }
                    }
                }
                foreach (var p in processes.Values) if (p != IntPtr.Zero) CloseHandle(p);
            }
            finally { Marshal.FreeHGlobal(table); }
        }
        return hits;
    }
}
'@

# ---------------------------------------------------------------- device tree (read-only)

function Get-Tree {
    param([string]$InstanceId, [int]$Depth = 0)
    $device = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if (-not $device -or -not $device.Present) { return }
    [pscustomobject]@{
        Depth      = $Depth
        Name       = $device.FriendlyName
        Class      = $device.Class
        InstanceId = $InstanceId
        ObjectName = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_PDOName -ErrorAction SilentlyContinue).Data
    }
    foreach ($child in @((Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_Children -ErrorAction SilentlyContinue).Data)) {
        if ($child) { Get-Tree $child ($Depth + 1) }
    }
}

$adapters = @(Get-PnpDevice -Class Bluetooth -PresentOnly | Where-Object { $id = $_.InstanceId; $_.Status -eq 'OK' -and @($HardwareIds | Where-Object { $id.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count })
Out-Line ("=== Bluetooth handle holders, {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if ($Label) { Out-Line "LABEL: $Label" }
if ($adapters.Count -ne 1) { Out-Line "Expected exactly one running adapter, found $($adapters.Count). Nothing to inspect."; exit 1 }

$tree = @(Get-Tree $adapters[0].InstanceId)
$steam = @(Get-Process steam -ErrorAction SilentlyContinue)
Out-Line "Active adapter: $($adapters[0].FriendlyName)"
Out-Line ("Steam: {0}" -f $(if ($steam) { ($steam | ForEach-Object { "pid $($_.Id), started $($_.StartTime.ToString('HH:mm:ss'))" }) -join '; ' } else { 'not running' }))
foreach ($c in @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'BTHENUM\DEV_*' })) {
    $connected = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue).Data
    Out-Line "Paired device: $($c.FriendlyName), connected: $([bool]$connected)"
}
Out-Line "Device tree under the adapter ($($tree.Count) devices):"
foreach ($t in $tree) { Out-Line ("  {0}{1}  [{2}]  {3}" -f ('  ' * $t.Depth), $t.Name, $t.Class, $t.ObjectName) }

# ---------------------------------------------------------------- handle scan

$names = [string[]]@($tree | Where-Object ObjectName | ForEach-Object { $_.ObjectName })
$timer = [Diagnostics.Stopwatch]::StartNew()
$hits = [BtsHandles]::Find($names)
Out-Line ("Scan: {0} processes inspected, {1} not inspectable without administrator rights, {2:n0} file handles checked, {3} skipped (no answer), {4:n1}s" -f `
    [BtsHandles]::ProcessesInspected, [BtsHandles]::ProcessesNotInspectable, [BtsHandles]::FileHandlesChecked, [BtsHandles]::HandlesTimedOut, $timer.Elapsed.TotalSeconds)

if ($hits.Count -eq 0) {
    Out-Line 'HOLDERS: none found among the programs that could be inspected.'
} else {
    foreach ($group in ($hits | Group-Object Pid)) {
        $proc = Get-Process -Id $group.Name -ErrorAction SilentlyContinue
        foreach ($byDevice in ($group.Group | Group-Object ObjectName)) {
            $device = $tree | Where-Object ObjectName -eq $byDevice.Name | Select-Object -First 1
            Out-Line ("HOLDER: {0} (pid {1}) holds {2} handle(s) on '{3}' [{4}]" -f $(if ($proc) { $proc.ProcessName + '.exe' } else { 'unknown' }), $group.Name, $byDevice.Count, $device.Name, $device.Class)
        }
    }
}
Out-Line "Log: $LogPath"
exit 0
