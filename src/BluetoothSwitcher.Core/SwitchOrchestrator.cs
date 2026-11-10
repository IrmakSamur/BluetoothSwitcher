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

        if (before.Condition != BluetoothCondition.Clean)
            return new(SwitchResultKind.Refused, "Switch not started",
                "The adapters are not in a clean state, so nothing was changed. " + before.Describe() + ".",
                before, null, RecoveryCommands(before, target));

        // 2. Run the engine. One UAC prompt; declining it is the only way to cancel.
        progress?.Report(new(SwitchPhase.WaitingForApproval, "Waiting for administrator approval"));
        var sawLog = false;
        var lineProgress = new InlineProgress<string>(line =>
        {
            if (!sawLog)
            {
                sawLog = true;
                progress?.Report(new(SwitchPhase.Starting, "Starting"));
            }
            if (PhaseFor(line, originalName, targetName) is { } update)
                progress?.Report(update);
        });

        ScriptRunResult run;
        try
        {
            run = await runner.RunAsync(target, lineProgress, cancellationToken).ConfigureAwait(false);
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
        progress?.Report(new(SwitchPhase.Verifying, "Verifying adapter state"));
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
                if (singleRead || last.Condition == BluetoothCondition.Clean)
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

    private static SwitchProgress? PhaseFor(string line, string originalName, string targetName)
    {
        if (line.Contains("ROLLBACK", StringComparison.Ordinal))
            return new(SwitchPhase.RollingBack, $"Switch failed, restoring {originalName}");
        if (line.Contains("Step 1/4", StringComparison.Ordinal))
            return new(SwitchPhase.DisablingCurrent, $"Turning off {originalName}");
        if (line.Contains("Step 2/4", StringComparison.Ordinal))
            return new(SwitchPhase.WaitingForStop, $"Waiting for {originalName} to stop");
        if (line.Contains("Step 3/4", StringComparison.Ordinal))
            return new(SwitchPhase.EnablingTarget, $"Turning on {targetName}");
        if (line.Contains("Step 4/4", StringComparison.Ordinal))
            return new(SwitchPhase.WaitingForStart, $"Waiting for {targetName} to start");
        return null;
    }

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

    /// <summary>Reports on the calling thread, so log lines are handled in order.</summary>
    private sealed class InlineProgress<T>(Action<T> handler) : IProgress<T>
    {
        public void Report(T value) => handler(value);
    }
}
