namespace BluetoothSwitcher.Core;

/// <summary>The two adapters this app switches between.</summary>
public enum AdapterRole
{
    /// <summary>Internal adapter, used upstairs.</summary>
    Internal,

    /// <summary>External USB adapter, used downstairs.</summary>
    External,
}

public static class AdapterCatalog
{
    // Adapters are matched by hardware ID. An instance ID starts with the device's
    // hardware ID followed by a per-port suffix, and the dongle's suffix changes with
    // the USB port, so only the prefix is fixed.
    public const string InternalHardwareId = @"USB\VID_0489&PID_E139&MI_00";
    public const string ExternalHardwareId = @"USB\VID_33FA&PID_0012";

    /// <summary>Microsoft Bluetooth Enumerator. Started means the Bluetooth stack is up.</summary>
    public const string EnumeratorPrefix = @"BTH\MS_BTHBRB\";

    public static string HardwareId(AdapterRole role) =>
        role == AdapterRole.Internal ? InternalHardwareId : ExternalHardwareId;

    public static string Location(AdapterRole role) =>
        role == AdapterRole.Internal ? "Upstairs" : "Downstairs";

    public static AdapterRole Other(AdapterRole role) =>
        role == AdapterRole.Internal ? AdapterRole.External : AdapterRole.Internal;
}

/// <summary>One device as reported by pnputil.</summary>
public sealed record PnpDevice(string InstanceId, string Description, string Status);

/// <summary>One of the two adapters, as currently seen by Windows.</summary>
/// <param name="NeedsRestart">
/// Windows has flagged this device as needing a system restart (DN_NEED_RESTART). This
/// happens when a disable was vetoed because a program had a Bluetooth device open: the
/// adapter keeps running, cannot be disabled again, and will come up disabled after the
/// next restart.
/// </param>
public sealed record AdapterState(AdapterRole Role, string InstanceId, string Name, string Status, bool NeedsRestart = false)
{
    public bool IsDisabled => string.Equals(Status, "Disabled", StringComparison.OrdinalIgnoreCase);
    public bool IsStarted => string.Equals(Status, "Started", StringComparison.OrdinalIgnoreCase);
    public string Location => AdapterCatalog.Location(Role);
}

public enum BluetoothCondition
{
    /// <summary>Exactly one adapter is started with the stack up; the other is disabled.</summary>
    Clean,

    /// <summary>Both adapters are disabled. Bluetooth is off.</summary>
    BothDisabled,

    /// <summary>More than one adapter is enabled.</summary>
    BothEnabled,

    /// <summary>One or both adapters are not connected, or exist more than once.</summary>
    AdapterMissing,

    /// <summary>Anything else, for example an adapter that is enabled but failed to start.</summary>
    Unclear,

    /// <summary>
    /// An adapter is flagged as needing a system restart. Nothing can be switched until
    /// Windows has been restarted, whatever else the adapters report.
    /// </summary>
    RestartPending,
}

/// <summary>The state of both adapters at one moment, read from Windows.</summary>
public sealed class BluetoothSnapshot
{
    public BluetoothSnapshot(
        IReadOnlyList<AdapterState> internalAdapters,
        IReadOnlyList<AdapterState> externalAdapters,
        bool enumeratorStarted)
    {
        Internal = internalAdapters.Count == 1 ? internalAdapters[0] : null;
        External = externalAdapters.Count == 1 ? externalAdapters[0] : null;
        InternalCount = internalAdapters.Count;
        ExternalCount = externalAdapters.Count;
        EnumeratorStarted = enumeratorStarted;
        Condition = Classify();
    }

    public AdapterState? Internal { get; }
    public AdapterState? External { get; }
    public int InternalCount { get; }
    public int ExternalCount { get; }
    public bool EnumeratorStarted { get; }
    public BluetoothCondition Condition { get; }

    public AdapterState? Get(AdapterRole role) => role == AdapterRole.Internal ? Internal : External;

    /// <summary>The active adapter, or null unless the state is <see cref="BluetoothCondition.Clean"/>.</summary>
    public AdapterRole? Active =>
        Condition != BluetoothCondition.Clean ? null
        : Internal!.IsStarted ? AdapterRole.Internal : AdapterRole.External;

    /// <summary>
    /// True only when <paramref name="role"/> is started with the Bluetooth stack up
    /// and the other adapter is disabled. This is the only definition of "switched".
    /// </summary>
    public bool IsCleanlyOn(AdapterRole role) => Active == role;

    /// <summary>
    /// The adapter that is running right now with the Bluetooth stack up, even when the
    /// overall state is not clean. For display only; never use it to decide an outcome.
    /// </summary>
    public AdapterRole? Running =>
        !EnumeratorStarted ? null
        : Internal is { IsStarted: true } && External is not { IsStarted: true } ? AdapterRole.Internal
        : External is { IsStarted: true } && Internal is not { IsStarted: true } ? AdapterRole.External
        : null;

    /// <summary>The adapter flagged as needing a restart, if any.</summary>
    public AdapterState? RestartPendingAdapter =>
        Internal is { NeedsRestart: true } ? Internal : External is { NeedsRestart: true } ? External : null;

    private BluetoothCondition Classify()
    {
        if (Internal is null || External is null)
            return BluetoothCondition.AdapterMissing;
        if (Internal.NeedsRestart || External.NeedsRestart)
            return BluetoothCondition.RestartPending;
        if (Internal.IsDisabled && External.IsDisabled)
            return BluetoothCondition.BothDisabled;
        if (!Internal.IsDisabled && !External.IsDisabled)
            return BluetoothCondition.BothEnabled;

        var enabled = Internal.IsDisabled ? External : Internal;
        return enabled.IsStarted && EnumeratorStarted ? BluetoothCondition.Clean : BluetoothCondition.Unclear;
    }

    public string Describe()
    {
        static string One(string label, AdapterState? a, int count) =>
            a is not null ? $"{label}: {a.Status}{(a.NeedsRestart ? " (restart pending)" : "")}"
            : $"{label}: {(count == 0 ? "not connected" : $"{count} instances")}";
        return $"{One("Upstairs", Internal, InternalCount)}, {One("Downstairs", External, ExternalCount)}, " +
               $"Bluetooth stack {(EnumeratorStarted ? "running" : "not running")}";
    }
}
