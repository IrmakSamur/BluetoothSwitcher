namespace BluetoothSwitcher.Core;

public enum SimulationMode
{
    /// <summary>Switches succeed.</summary>
    Normal,

    /// <summary>The target fails to start; the engine rolls back.</summary>
    FailAndRollBack,

    /// <summary>The engine dies after disabling the active adapter; Bluetooth ends up off.</summary>
    DieMidSwitch,

    /// <summary>The UAC prompt is declined.</summary>
    DeclineApproval,

    /// <summary>The engine logs success but the adapters do not change.</summary>
    LieAboutSuccess,
}

/// <summary>
/// In-memory stand-in for both adapters and the switch engine. Used by "--demo" and by
/// the tests. Touches no real device.
/// </summary>
public sealed class SimulatedHardware : IDeviceStateReader, ISwitchRunner
{
    private const string InternalId = @"USB\VID_0489&PID_E139&MI_00\SIM&INTERNAL";
    private const string ExternalId = @"USB\VID_33FA&PID_0012\SIM&EXTERNAL";

    private readonly object _gate = new();
    private string _internalStatus = "Disabled";
    private string _externalStatus = "Started";
    private bool _enumerator = true;

    public SimulationMode Mode { get; set; } = SimulationMode.Normal;

    /// <summary>Scales every simulated wait. Tests use 0.</summary>
    public double Speed { get; set; } = 1.0;

    public int RunCount { get; private set; }

    public void Set(string internalStatus, string externalStatus, bool enumerator)
    {
        lock (_gate)
        {
            _internalStatus = internalStatus;
            _externalStatus = externalStatus;
            _enumerator = enumerator;
        }
    }

    public Task<BluetoothSnapshot> ReadAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            var devices = new List<PnpDevice>
            {
                new(InternalId, "MediaTek Bluetooth Adapter", _internalStatus),
                new(ExternalId, "BARROT Bluetooth 6.0 Adapter", _externalStatus),
            };
            if (_enumerator)
                devices.Add(new(AdapterCatalog.EnumeratorPrefix + "SIM&0&1", "Microsoft Bluetooth Enumerator", "Started"));
            return Task.FromResult(PnpUtilParser.ToSnapshot(devices));
        }
    }

    public async Task<ScriptRunResult> RunAsync(AdapterRole target, Action<int>? onStarted, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RunCount++;
        var lines = new List<string>();

        void Log(string level, string message)
        {
            var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level,-5}] {message}";
            lines.Add(line);
        }
        Task Wait(int milliseconds) => Task.Delay(TimeSpan.FromMilliseconds(milliseconds * Speed), CancellationToken.None);
        void SetStatus(AdapterRole role, string status)
        {
            lock (_gate)
            {
                if (role == AdapterRole.Internal) _internalStatus = status; else _externalStatus = status;
            }
        }
        void SetEnumerator(bool up) { lock (_gate) { _enumerator = up; } }
        ScriptRunResult Exit(int? code)
        {
            if (code is { } c) Log("INFO", $"Exit code: {c}.");
            return new(ScriptRunStatus.Exited, code ?? -1, code, "(simulated)", lines, null);
        }

        await Wait(1200); // the UAC prompt
        if (Mode == SimulationMode.DeclineApproval)
            return new(ScriptRunStatus.Declined, null, null, null, [], null);

        onStarted?.Invoke(0);
        var source = AdapterCatalog.Other(target);
        Log("INFO", $"BluetoothSwitcher switch PoC. Mode: SIMULATION. Requested target: {AdapterCatalog.Location(target)}.");
        await Wait(1600); // adapter detection

        if (Mode == SimulationMode.LieAboutSuccess)
        {
            Log("INFO", "SUCCESS: (simulated lie)");
            return Exit(0);
        }

        Log("INFO", "Step 1/4: disable the active adapter.");
        await Wait(300);
        SetStatus(source, "Disabled");
        SetEnumerator(false);

        if (Mode == SimulationMode.DieMidSwitch)
            return Exit(null);

        Log("INFO", "Step 2/4: wait up to 15s for it to stop.");
        await Wait(2000); // settle pause

        Log("INFO", "Step 3/4: enable the target adapter.");
        await Wait(1000);

        Log("INFO", "Step 4/4: wait up to 30s for it to start.");
        if (Mode == SimulationMode.FailAndRollBack)
        {
            SetStatus(target, "Problem");
            await Wait(2500);
            Log("ERROR", "The target adapter did not start.");
            Log("WARN", "ROLLBACK: restoring the original adapter.");
            SetStatus(target, "Disabled");
            await Wait(1500);
            SetStatus(source, "Started");
            SetEnumerator(true);
            Log("WARN", "Rolled back.");
            return Exit(2);
        }

        SetStatus(target, "Started");
        await Wait(300);
        SetEnumerator(true);
        Log("INFO", $"SUCCESS: now on {AdapterCatalog.Location(target)}.");
        return Exit(0);
    }
}
