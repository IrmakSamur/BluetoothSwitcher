namespace BluetoothSwitcher.Core;

public enum SwitchPhase
{
    Checking,
    WaitingForApproval,
    Starting,
    DisablingCurrent,
    WaitingForStop,
    EnablingTarget,
    WaitingForStart,
    RollingBack,
    Verifying,
}

public sealed record SwitchProgress(SwitchPhase Phase, string Message);

public enum SwitchResultKind
{
    /// <summary>Verified: the target is active and the other adapter is disabled.</summary>
    Switched,

    /// <summary>Verified: the target was already active. Nothing was run.</summary>
    AlreadyActive,

    /// <summary>The UAC prompt was declined. Verified: nothing changed.</summary>
    Cancelled,

    /// <summary>The switch was not attempted because the starting state was not clean.</summary>
    Refused,

    /// <summary>The switch failed. Verified: the original adapter is active again.</summary>
    StillOnOriginal,

    /// <summary>Verified: no adapter is active. Bluetooth is off and needs manual recovery.</summary>
    BluetoothOff,

    /// <summary>The adapters ended in a state that is neither clean nor off.</summary>
    Inconsistent,

    /// <summary>The adapter state could not be read, so nothing can be claimed.</summary>
    StateUnknown,

    /// <summary>
    /// Verified: Windows has flagged an adapter as needing a restart. Bluetooth may still
    /// be working, but nothing can be switched until Windows has been restarted, and the
    /// flagged adapter will come up disabled.
    /// </summary>
    RestartRequired,
}

public sealed record SwitchResult(
    SwitchResultKind Kind,
    string Title,
    string Detail,
    BluetoothSnapshot? Snapshot,
    ScriptRunResult? Run,
    IReadOnlyList<string> RecoveryCommands)
{
    public bool IsSuccess => Kind is SwitchResultKind.Switched or SwitchResultKind.AlreadyActive;
}

/// <summary>
/// Runs one switch: check the state, run the engine, then decide the outcome from the
/// real adapter state. The engine's exit code and log only explain a failure; they never
/// establish success.
/// </summary>
public sealed class SwitchOrchestrator(IDeviceStateReader reader, ISwitchRunner runner)
{
    /// <summary>How long to keep re-reading for a clean state after the engine finishes.</summary>
    public TimeSpan VerifyWindow { get; init; } = TimeSpan.FromSeconds(6);

    public TimeSpan VerifyInterval { get; init; } = TimeSpan.FromMilliseconds(500);

    /// <summary>How often the adapters are read for the progress display while the engine runs.</summary>
    public TimeSpan ProgressInterval { get; init; } = TimeSpan.FromMilliseconds(400);

    public async Task<SwitchResult> SwitchAsync(
        AdapterRole target, IProgress<SwitchProgress>? progress, CancellationToken cancellationToken = default)
    {
        var targetName = AdapterCatalog.Location(target);
        var original = AdapterCatalog.Other(target);
        var originalName = AdapterCatalog.Location(original);

        // 1. Pre-check (read-only).
        progress?.Report(new(SwitchPhase.Checking, "Checking adapters"));
        BluetoothSnapshot before;
        try
        {
            before = await reader.ReadAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return new(SwitchResultKind.StateUnknown, "Could not read the adapters",
                "Nothing was changed. " + ex.Message, null, null, []);
        }

        if (before.IsCleanlyOn(target))
            return new(SwitchResultKind.AlreadyActive, $"Already on {targetName}", "Nothing was changed.", before, null, []);

        if (before.Condition == BluetoothCondition.RestartPending)
            return RestartRequired(before, null, "Nothing was changed. ");

        if (before.Condition != BluetoothCondition.Clean)
            return new(SwitchResultKind.Refused, "Switch not started",
                "The adapters are not in a clean state, so nothing was changed. " + before.Describe() + ".",
                before, null, RecoveryCommands(before, target));

        // 2. Run the engine. One UAC prompt; declining it is the only way to cancel.
        //    Progress comes from the adapters themselves, read with the same read-only
        //    query as everywhere else. The engine's log is not touched while it runs.
        var gate = new object();
        SwitchPhase? lastPhase = null;
        void Publish(SwitchPhase phase)
        {
            lock (gate)
            {
                if (lastPhase == phase)
                    return;
                lastPhase = phase;
                progress?.Report(new(phase, Describe(phase, originalName, targetName)));
            }
        }

        Publish(SwitchPhase.WaitingForApproval);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var tracker = new SwitchProgressTracker(target);

        ScriptRunResult run;
        try
        {
            var runTask = runner.RunAsync(target, _ =>
            {
                Publish(SwitchPhase.Starting);
                started.TrySetResult();
            }, cancellationToken);

            while (await Task.WhenAny(runTask, Task.Delay(ProgressInterval, CancellationToken.None)).ConfigureAwait(false) != runTask)
            {
                if (!started.Task.IsCompleted)
                    continue;   // still at the UAC prompt: nothing can have changed yet
                try
                {
                    var now = await reader.ReadAsync(CancellationToken.None).ConfigureAwait(false);
                    if (tracker.Next(now) is { } phase)
                        Publish(phase);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // A failed progress read only means the display is not updated.
                }
            }
            run = await runTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Only possible before the engine was started.
            return new(SwitchResultKind.Cancelled, "Switch cancelled", "Nothing was changed.", before, null, []);
        }

        if (run.Status == ScriptRunStatus.StartFailed)
            return new(SwitchResultKind.Refused, "Switch not started",
                "Nothing was changed. " + run.Error, before, run, []);

        // 3. Verify against real hardware state, whatever the engine reported.
        Publish(SwitchPhase.Verifying);
        BluetoothSnapshot after;
        try
        {
            after = await ReadSettledAsync(run.Status == ScriptRunStatus.Declined).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return new(SwitchResultKind.StateUnknown, "Could not verify the result",
                $"The adapter state could not be read after the switch: {ex.Message} {Explain(run)}",
                null, run, RecoveryCommands(before, original));
        }

        // 4. Decide from the verified state.
        //    A restart-pending flag comes first: even if an adapter is running, the state
        //    is not one a rollback restored. It is a state Windows will change at the
        //    next restart, and it must not be reported as "still on the original".
        if (after.Condition == BluetoothCondition.RestartPending)
            return RestartRequired(after, run, string.Empty);

        if (after.IsCleanlyOn(target))
        {
            if (run.Status == ScriptRunStatus.Declined)
                return new(SwitchResultKind.AlreadyActive, $"Already on {targetName}", "Nothing was changed by this app.", after, run, []);
            return new(SwitchResultKind.Switched, $"Now on {targetName}",
                "Devices paired with the other adapter will not reconnect until you switch back.", after, run, []);
        }

        if (after.IsCleanlyOn(original))
        {
            if (run.Status == ScriptRunStatus.Declined)
                return new(SwitchResultKind.Cancelled, "Switch cancelled",
                    $"Administrator approval was declined. Still on {originalName}.", after, run, []);
            return new(SwitchResultKind.StillOnOriginal, $"Switch failed, still on {originalName}",
                Explain(run), after, run, []);
        }

        if (after.Condition == BluetoothCondition.BothDisabled)
            return new(SwitchResultKind.BluetoothOff, "Bluetooth is off",
                "Both adapters are disabled. " + Explain(run) + " Use the commands below in an administrator terminal.",
                after, run, RecoveryCommands(after, original));

        return new(SwitchResultKind.Inconsistent, "Adapters are in an unexpected state",
            after.Describe() + ". " + Explain(run), after, run, RecoveryCommands(after, original));
    }

    private static SwitchResult RestartRequired(BluetoothSnapshot snapshot, ScriptRunResult? run, string prefix) =>
        new(SwitchResultKind.RestartRequired, "Restart required", prefix + DescribeRestartPending(snapshot), snapshot, run, []);

    /// <summary>What a restart-pending flag means for the user, in plain words.</summary>
    public static string DescribeRestartPending(BluetoothSnapshot snapshot)
    {
        var flagged = snapshot.RestartPendingAdapter;
        if (flagged is null)
            return string.Empty;
        var running = snapshot.Running is { } role ? AdapterCatalog.Location(role) : null;
        return
            $"Windows could not stop {flagged.Location} ({flagged.Name}) because another program had a Bluetooth device open, " +
            "and has marked the adapter as needing a restart. " +
            (running is not null ? $"Bluetooth keeps working on {running} until then. " : string.Empty) +
            "Switching is not possible until Windows has been restarted. " +
            $"After the restart {flagged.Location} will be disabled: open this app and choose an adapter to turn Bluetooth back on.";
    }

    /// <summary>
    /// Re-reads until the state is clean or the window passes, so a state that is
    /// still settling is not reported as a failure. Returns the last reading.
    /// </summary>
    private async Task<BluetoothSnapshot> ReadSettledAsync(bool singleRead)
    {
        var deadline = DateTime.UtcNow + VerifyWindow;
        Exception? lastError = null;
        BluetoothSnapshot? last = null;
        while (true)
        {
            try
            {
                last = await reader.ReadAsync(CancellationToken.None).ConfigureAwait(false);
                lastError = null;
                // A restart-pending flag does not clear by waiting.
                if (singleRead || last.Condition is BluetoothCondition.Clean or BluetoothCondition.RestartPending)
                    return last;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                lastError = ex;
            }

            if (DateTime.UtcNow >= deadline)
                break;
            await Task.Delay(VerifyInterval, CancellationToken.None).ConfigureAwait(false);
        }

        if (last is not null && lastError is null)
            return last;
        throw lastError ?? new InvalidOperationException("Adapter state could not be read.");
    }

    private static string Describe(SwitchPhase phase, string originalName, string targetName) => phase switch
    {
        SwitchPhase.Checking => "Checking adapters",
        SwitchPhase.WaitingForApproval => "Waiting for administrator approval",
        SwitchPhase.Starting => "Starting",
        SwitchPhase.DisablingCurrent => $"Turning off {originalName}",
        SwitchPhase.WaitingForStop => $"Waiting for {originalName} to stop",
        SwitchPhase.EnablingTarget => $"Turning on {targetName}",
        SwitchPhase.WaitingForStart => $"Waiting for {targetName} to start",
        SwitchPhase.RollingBack => $"Switch failed, restoring {originalName}",
        _ => "Verifying adapter state",
    };

    private static string Explain(ScriptRunResult run)
    {
        if (run.Status == ScriptRunStatus.Declined)
            return "Administrator approval was declined.";
        if (run.Status == ScriptRunStatus.TimedOut)
            return run.Error ?? "The switch script did not finish in time.";
        if (run.EndedUnexpectedly)
            return "The switch script ended unexpectedly" +
                   (run.ProcessExitCode is { } code ? $" (process exit code {code})." : ".");

        var reason = run.ExitCode switch
        {
            0 => "The switch script reported success, but the adapters do not confirm it.",
            1 => "The switch script refused to start a switch.",
            2 => "The switch script failed and rolled back.",
            3 => "The switch script failed and its rollback also failed.",
            4 => "Another switch was already running.",
            { } other => $"The switch script exited with code {other}.",
            null => "The switch script gave no exit code.",
        };
        var error = run.LogLines.LastOrDefault(l => l.Contains("[ERROR]", StringComparison.Ordinal));
        if (error is not null)
        {
            var text = error[(error.IndexOf("[ERROR]", StringComparison.Ordinal) + 7)..].Trim();
            if (text.Length > 0)
                reason += " " + text;
        }
        return reason;
    }

    /// <summary>Manual commands that leave <paramref name="wanted"/> as the only enabled adapter.</summary>
    public static IReadOnlyList<string> RecoveryCommands(BluetoothSnapshot snapshot, AdapterRole wanted)
    {
        var keep = snapshot.Get(wanted);
        var other = snapshot.Get(AdapterCatalog.Other(wanted));
        var commands = new List<string>();
        if (other is not null && !other.IsDisabled)
            commands.Add($"pnputil /disable-device \"{other.InstanceId}\"");
        if (keep is not null && !keep.IsStarted)
        {
            if (!keep.IsDisabled)
                commands.Add($"pnputil /disable-device \"{keep.InstanceId}\"");
            commands.Add($"pnputil /enable-device \"{keep.InstanceId}\"");
        }
        return commands;
    }

}

/// <summary>
/// Works out which step a running switch is in from successive adapter readings.
/// This only drives the progress display; the outcome is decided separately, after
/// the engine has exited.
/// </summary>
public sealed class SwitchProgressTracker(AdapterRole target)
{
    private readonly AdapterRole _original = AdapterCatalog.Other(target);
    private bool _originalWentDown;
    private bool _targetCameUp;

    /// <summary>Returns the phase the reading indicates, or null if it says nothing new.</summary>
    public SwitchPhase? Next(BluetoothSnapshot snapshot)
    {
        var original = snapshot.Get(_original);
        var wanted = snapshot.Get(target);
        if (original is null || wanted is null)
            return null;

        if (original.IsDisabled) _originalWentDown = true;
        if (!wanted.IsDisabled) _targetCameUp = true;

        if (snapshot.IsCleanlyOn(target))
            return SwitchPhase.Verifying;

        if (snapshot.IsCleanlyOn(_original))
            // Unchanged so far (the engine is still preparing), or changed and back again.
            return _originalWentDown ? SwitchPhase.RollingBack : null;

        if (original.IsDisabled && wanted.IsDisabled)
            // Normal gap between "old one off" and "new one on", unless the new one
            // had already been turned on: then the engine is undoing the switch.
            return _targetCameUp ? SwitchPhase.RollingBack : SwitchPhase.EnablingTarget;

        if (original.IsDisabled)
            return SwitchPhase.WaitingForStart;   // target enabled, not fully up yet

        if (!wanted.IsDisabled)
            return null;                          // both enabled: not a step of a normal switch

        // The original is enabled but not cleanly active: stopping, or coming back.
        return _originalWentDown ? SwitchPhase.RollingBack : SwitchPhase.DisablingCurrent;
    }
}
