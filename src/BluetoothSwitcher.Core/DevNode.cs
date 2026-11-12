using System.Runtime.InteropServices;

namespace BluetoothSwitcher.Core;

/// <summary>
/// Read-only queries against the Windows Configuration Manager. Needs no administrator
/// rights and changes nothing.
/// </summary>
public static class DevNode
{
    private const uint CrSuccess = 0;
    private const uint DnNeedRestart = 0x00000100;

    /// <summary>
    /// True when Windows has flagged the device as needing a system restart. Returns
    /// null when the device cannot be found or queried, so the caller can tell "not
    /// flagged" apart from "unknown".
    /// </summary>
    public static bool? NeedsRestart(string instanceId)
    {
        try
        {
            if (CM_Locate_DevNodeW(out var devInst, instanceId, 0) != CrSuccess)
                return null;
            if (CM_Get_DevNode_Status(out var status, out _, devInst, 0) != CrSuccess)
                return null;
            return (status & DnNeedRestart) != 0;
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return null;
        }
    }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint CM_Locate_DevNodeW(out uint devInst, string deviceId, uint flags);

    [DllImport("cfgmgr32.dll", ExactSpelling = true)]
    private static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint devInst, uint flags);
}
