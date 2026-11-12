// Unit tests for BluetoothSwitcher.Core. No real device is read or changed:
// everything runs against canned XML or SimulatedHardware.
using System.Text;
using BluetoothSwitcher.Core;

var failed = 0;
var passed = 0;

void Check(string name, object? got, object? want)
{
    var ok = Equals(got, want);
    if (ok) passed++; else failed++;
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {name}{(ok ? "" : $"  got=<{got}> want=<{want}>")}");
}

async Task Test(string name, Func<Task> body)
{
    try { await body(); }
    catch (Exception ex)
    {
        failed++;
        Console.WriteLine($"FAIL {name}  threw {ex.GetType().Name}: {ex.Message}");
    }
}

// The stand-in engine (tests/mock/fake-engine.ps1) picks its behaviour from its file name.
static string FakeEngine(string mode, string workDir)
{
    var dir = new DirectoryInfo(AppContext.BaseDirectory);
    while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "tests", "mock", "fake-engine.ps1")))
        dir = dir.Parent;
    if (dir is null)
        throw new FileNotFoundException("tests/mock/fake-engine.ps1 not found above " + AppContext.BaseDirectory);
    var copy = Path.Combine(workDir, $"engine-{mode}.ps1");
    File.Copy(Path.Combine(dir.FullName, "tests", "mock", "fake-engine.ps1"), copy, overwrite: true);
    return copy;
}

// Read-only: print what the app's own reader sees on this machine right now.
// Run:  dotnet run --project tests\BluetoothSwitcher.Core.Tests -c Release -- --live-state
if (args.Contains("--live-state"))
{
    var live = await new PnpUtilStateReader().ReadAsync();
    Console.WriteLine($"condition:       {live.Condition}");
    Console.WriteLine($"active:          {live.Active?.ToString() ?? "(none)"}");
    Console.WriteLine($"running:         {live.Running?.ToString() ?? "(none)"}");
    Console.WriteLine($"restart pending: {live.RestartPendingAdapter?.Location ?? "(none)"}");
    Console.WriteLine($"description:     {live.Describe()}");
    if (live.Condition == BluetoothCondition.RestartPending)
        Console.WriteLine($"message:         {SwitchOrchestrator.DescribeRestartPending(live)}");
    return 0;
}

// Interactive check of the real elevated launch, with the harmless stand-in engine.
// Run:  dotnet run --project tests\BluetoothSwitcher.Core.Tests -c Release -- --uac-check
if (args.Contains("--uac-check"))
{
    if (Environment.IsPrivilegedProcess)
    {
        Console.WriteLine("Run this from a NORMAL terminal, not an administrator one.");
        Console.WriteLine("From an elevated terminal Windows shows no UAC prompt, so nothing can be checked.");
        return 1;
    }

    var work = Directory.CreateTempSubdirectory("bts-uac-").FullName;
    var engine = FakeEngine("ok", work);
    // Refuse to continue if the stand-in could change a device.
    var engineText = File.ReadAllText(engine);
    foreach (var forbidden in new[] { "pnputil.exe", "/disable-device", "/enable-device", "Disable-PnpDevice", "Enable-PnpDevice" })
    {
        if (engineText.Contains(forbidden, StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"Refusing to run: the stand-in script contains '{forbidden}'.");
            return 1;
        }
    }

    var runner = new ElevatedScriptRunner(engine, Path.Combine(work, "logs"));
    Console.WriteLine("This starts a HARMLESS script elevated. It only writes a log file; no device is touched.");
    Console.WriteLine($"Script: {engine}");
    Console.WriteLine();
    Console.WriteLine("Run 1 of 2: a UAC prompt will appear. Click NO.");
    var declined = await runner.RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("declining UAC is reported as Declined", declined.Status, ScriptRunStatus.Declined);
    Check("declining UAC leaves no log file", declined.LogPath, null);

    Console.WriteLine();
    Console.WriteLine("Run 2 of 2: a UAC prompt will appear. Click YES.");
    var startedPid = -1;
    var accepted = await runner.RunAsync(AdapterRole.Internal, pid => startedPid = pid, CancellationToken.None);
    Check("accepted: status", accepted.Status, ScriptRunStatus.Exited);
    Check("accepted: the start was signalled with a process id", startedPid > 0, true);
    Check("accepted: script really ran elevated", accepted.LogLines.Any(l => l.Contains("Elevated: True.")), true);
    Check("accepted: exit code read from the elevated process", accepted.ProcessExitCode, 0);
    Check("accepted: exit code read from the log", accepted.LoggedExitCode, 0);
    Check("accepted: the whole log was read after exit", accepted.LogLines.Count >= 8, true);
    Check("accepted: all four steps were seen", accepted.LogLines.Count(l => l.Contains("Step ")), 4);
    Check("accepted: not flagged as an unexpected end", accepted.EndedUnexpectedly, false);
    Console.WriteLine();
    Console.WriteLine($"log file: {accepted.LogPath}");
    Console.WriteLine($"uac check: {passed} passed, {failed} failed");
    return failed;
}

const string Int = @"USB\VID_0489&PID_E139&MI_00\9&20d79c11&0&0000";
const string Ext = @"USB\VID_33FA&PID_0012\b&1dbefb94&0&1";
const string Brb = @"BTH\MS_BTHBRB\c&399fdf75&0&1";

static string Xml(params (string Id, string Status)[] devices)
{
    var sb = new StringBuilder();
    sb.AppendLine("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
    sb.AppendLine("<PnpUtil Version=\"10.0.26300\" Command=\"/enum-devices /connected /class Bluetooth /format xml\">");
    foreach (var (id, status) in devices)
    {
        sb.AppendLine($"    <Device InstanceId=\"{id.Replace("&", "&amp;")}\">");
        sb.AppendLine("        <DeviceDescription>Some Adapter</DeviceDescription>");
        sb.AppendLine($"        <Status>{status}</Status>");
        sb.AppendLine("    </Device>");
    }
    sb.AppendLine("</PnpUtil>");
    return sb.ToString();
}

static BluetoothSnapshot Snap(params (string Id, string Status)[] devices) =>
    PnpUtilParser.ToSnapshot(PnpUtilParser.Parse(Xml(devices)));

// ---------------------------------------------------------------- parser and classification

await Test("parser", () =>
{
    var s = Snap((Brb, "Started"), (Int, "Disabled"), (Ext, "Started"));
    Check("external active: condition", s.Condition, BluetoothCondition.Clean);
    Check("external active: active role", s.Active, AdapterRole.External);
    Check("external active: IsCleanlyOn(External)", s.IsCleanlyOn(AdapterRole.External), true);
    Check("external active: IsCleanlyOn(Internal)", s.IsCleanlyOn(AdapterRole.Internal), false);
    Check("description is parsed", s.External!.Name, "Some Adapter");
    Check("instance id keeps its ampersands", s.External!.InstanceId, Ext);

    s = Snap((Brb, "Started"), (Int, "Started"), (Ext, "Disabled"));
    Check("internal active: active role", s.Active, AdapterRole.Internal);

    s = Snap((Brb, "Started"), (Int.ToUpperInvariant(), "Disabled"), (Ext.ToUpperInvariant(), "Started"));
    Check("hardware id match ignores case", s.Active, AdapterRole.External);

    s = Snap((Int, "Disabled"), (Ext, "Disabled"));
    Check("both disabled: condition", s.Condition, BluetoothCondition.BothDisabled);
    Check("both disabled: no active role", s.Active, null);

    s = Snap((Brb, "Started"), (Int, "Started"), (Ext, "Started"));
    Check("both started: condition", s.Condition, BluetoothCondition.BothEnabled);

    s = Snap((Brb, "Started"), (Int, "Problem"), (Ext, "Started"));
    Check("problem + started: condition (both enabled)", s.Condition, BluetoothCondition.BothEnabled);

    s = Snap((Int, "Disabled"), (Ext, "Started"));
    Check("started without enumerator: condition", s.Condition, BluetoothCondition.Unclear);
    Check("started without enumerator: not active", s.Active, null);

    s = Snap((Int, "Problem"), (Ext, "Disabled"));
    Check("problem: condition", s.Condition, BluetoothCondition.Unclear);

    s = Snap((Brb, "Started"), (Ext, "Started"));
    Check("internal missing: condition", s.Condition, BluetoothCondition.AdapterMissing);

    s = Snap((Brb, "Started"), (Int, "Disabled"), (Ext, "Started"), (@"USB\VID_33FA&PID_0012\7&1ff05f00&1&2", "Started"));
    Check("two dongle instances: condition", s.Condition, BluetoothCondition.AdapterMissing);
    Check("two dongle instances: count", s.ExternalCount, 2);

    s = PnpUtilParser.ToSnapshot(PnpUtilParser.Parse(
        "<?xml version=\"1.0\"?><PnpUtil Version=\"x\">No devices were found on the system.</PnpUtil>"));
    Check("no devices: condition", s.Condition, BluetoothCondition.AdapterMissing);

    foreach (var bad in new[] { "", "garbage <<<", "<Other/>" })
    {
        var threw = false;
        try { PnpUtilParser.Parse(bad); } catch (FormatException) { threw = true; }
        Check($"bad output '{bad}' throws FormatException", threw, true);
    }
    return Task.CompletedTask;
});

// ---------------------------------------------------------------- engine command line and log parsing

await Test("runner helpers", () =>
{
    Check("command line",
        ElevatedScriptRunner.BuildArguments(@"C:\app\Switch-Adapter.ps1", AdapterRole.Internal, @"C:\logs\a.log"),
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File \"C:\\app\\Switch-Adapter.ps1\" -Target Upstairs -Execute -LogPath \"C:\\logs\\a.log\"");
    Check("command line target for external",
        ElevatedScriptRunner.BuildArguments("s.ps1", AdapterRole.External, "l.log").Contains("-Target Downstairs "), true);

    var threw = false;
    try { ElevatedScriptRunner.BuildArguments("a\" -Evil \"b.ps1", AdapterRole.Internal, "l.log"); }
    catch (ArgumentException) { threw = true; }
    Check("quote in path is rejected", threw, true);

    Check("exit code line is parsed", ElevatedScriptRunner.ParseLoggedExitCode(new[]
    {
        "2026-11-10 20:52:02.892 [INFO ] SUCCESS: now on Upstairs (MediaTek Bluetooth Adapter).",
        "2026-11-10 20:52:02.921 [INFO ] Exit code: 0.",
    }), 0);
    Check("exit code 3 is parsed", ElevatedScriptRunner.ParseLoggedExitCode(new[] { "x [INFO ] Exit code: 3." }), 3);
    Check("no exit line gives null", ElevatedScriptRunner.ParseLoggedExitCode(new[]
    {
        "2026-11-10 20:23:51.520 [INFO ]   pnputil exit code: 0",
        "2026-11-10 20:23:51.521 [INFO ] Step 2/4: wait up to 15s for it to stop.",
    }), null);

    var path = Path.Combine(Path.GetTempPath(), $"bts-logtail-{Guid.NewGuid():N}.log");
    try
    {
        var tail = new LogTail(path);
        Check("log tail: missing file gives nothing", tail.ReadNewLines().Count, 0);
        File.WriteAllBytes(path, [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("first line\r\nsecond li")]);
        var lines = tail.ReadNewLines();
        Check("log tail: complete lines only", string.Join("|", lines), "first line");
        File.AppendAllText(path, "ne\r\nthird\r\n");
        lines = tail.ReadNewLines();
        Check("log tail: joins a split line", string.Join("|", lines), "second line|third");
        Check("log tail: nothing new", tail.ReadNewLines().Count, 0);
    }
    finally { File.Delete(path); }
    return Task.CompletedTask;
});

// ---------------------------------------------------------------- orchestration

static (SwitchOrchestrator Orchestrator, SimulatedHardware Hardware) Rig(SimulationMode mode)
{
    var hw = new SimulatedHardware { Mode = mode, Speed = 0 };
    var orchestrator = new SwitchOrchestrator(hw, hw)
    {
        VerifyWindow = TimeSpan.FromMilliseconds(60),
        VerifyInterval = TimeSpan.FromMilliseconds(10),
    };
    return (orchestrator, hw);
}

await Test("orchestrator", async () =>
{
    var (o, hw) = Rig(SimulationMode.Normal);
    var phases = new List<SwitchPhase>();
    var r = await o.SwitchAsync(AdapterRole.Internal, new Recorder(phases));
    Check("normal: kind", r.Kind, SwitchResultKind.Switched);
    Check("normal: hardware really is on the target", (await hw.ReadAsync()).Active, AdapterRole.Internal);
    // The simulation runs instantly here, so only the fixed phases are certain.
    Check("normal: opening phases", string.Join(",", phases.Take(3)), "Checking,WaitingForApproval,Starting");
    Check("normal: last phase", phases[^1], SwitchPhase.Verifying);
    Check("normal: no phase is reported twice in a row", phases.Zip(phases.Skip(1)).Any(p => p.First == p.Second), false);

    r = await o.SwitchAsync(AdapterRole.External, null);
    Check("switch back: kind", r.Kind, SwitchResultKind.Switched);
    Check("switch back: active", (await hw.ReadAsync()).Active, AdapterRole.External);

    (o, hw) = Rig(SimulationMode.Normal);
    r = await o.SwitchAsync(AdapterRole.External, null);
    Check("already active: kind", r.Kind, SwitchResultKind.AlreadyActive);
    Check("already active: engine not run", hw.RunCount, 0);

    (o, hw) = Rig(SimulationMode.LieAboutSuccess);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("engine reports success but nothing changed: kind", r.Kind, SwitchResultKind.StillOnOriginal);
    Check("engine reports success but nothing changed: not success", r.IsSuccess, false);
    Check("engine reports success but nothing changed: exit code was 0", r.Run!.ExitCode, 0);

    (o, hw) = Rig(SimulationMode.FailAndRollBack);
    phases.Clear();
    r = await o.SwitchAsync(AdapterRole.Internal, new Recorder(phases));
    Check("rollback: kind", r.Kind, SwitchResultKind.StillOnOriginal);
    Check("rollback: detail names the script error", r.Detail.Contains("did not start"), true);
    Check("rollback: no recovery commands needed", r.RecoveryCommands.Count, 0);

    (o, hw) = Rig(SimulationMode.DieMidSwitch);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("engine dies mid-switch: kind", r.Kind, SwitchResultKind.BluetoothOff);
    Check("engine dies mid-switch: flagged as unexpected end", r.Run!.EndedUnexpectedly, true);
    Check("engine dies mid-switch: recovery re-enables the original",
        string.Join(" ; ", r.RecoveryCommands), "pnputil /enable-device \"USB\\VID_33FA&PID_0012\\SIM&EXTERNAL\"");

    (o, hw) = Rig(SimulationMode.DeclineApproval);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("UAC declined: kind", r.Kind, SwitchResultKind.Cancelled);
    Check("UAC declined: still on original", (await hw.ReadAsync()).Active, AdapterRole.External);

    (o, hw) = Rig(SimulationMode.Normal);
    hw.Set("Disabled", "Disabled", enumerator: false);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("both disabled: kind", r.Kind, SwitchResultKind.Refused);
    Check("both disabled: engine not run", hw.RunCount, 0);
    Check("both disabled: recovery enables the requested adapter",
        string.Join(" ; ", r.RecoveryCommands), "pnputil /enable-device \"USB\\VID_0489&PID_E139&MI_00\\SIM&INTERNAL\"");

    (o, hw) = Rig(SimulationMode.Normal);
    hw.Set("Started", "Started", enumerator: true);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("both enabled: kind", r.Kind, SwitchResultKind.Refused);
    Check("both enabled: engine not run", hw.RunCount, 0);
    Check("both enabled: recovery disables the other adapter",
        string.Join(" ; ", r.RecoveryCommands), "pnputil /disable-device \"USB\\VID_33FA&PID_0012\\SIM&EXTERNAL\"");

    (o, hw) = Rig(SimulationMode.Normal);
    using var cancelled = new CancellationTokenSource();
    var gate = new CancelAfterFirstRead(hw, cancelled);
    r = await new SwitchOrchestrator(gate, hw).SwitchAsync(AdapterRole.Internal, null, cancelled.Token);
    Check("cancelled before start: kind", r.Kind, SwitchResultKind.Cancelled);
    Check("cancelled before start: engine not run", hw.RunCount, 0);

    var broken = new SwitchOrchestrator(new ThrowingReader(), hw);
    r = await broken.SwitchAsync(AdapterRole.Internal, null);
    Check("unreadable state: kind", r.Kind, SwitchResultKind.StateUnknown);
});

// ---------------------------------------------------------------- restart-pending state (removal veto)
// What happened on 2026-11-11: Steam had the paired controller open, Windows vetoed the
// disable, pnputil reported 3010, and the adapter kept running but flagged for a restart.

await Test("restart pending", async () =>
{
    var devices = PnpUtilParser.Parse(Xml((Brb, "Started"), (Int, "Disabled"), (Ext, "Started")));
    var clean = PnpUtilParser.ToSnapshot(devices);
    var flagged = PnpUtilParser.ToSnapshot(devices, id => id == Ext);
    Check("unflagged: clean", clean.Condition, BluetoothCondition.Clean);
    Check("flagged running adapter: condition", flagged.Condition, BluetoothCondition.RestartPending);
    Check("flagged: not counted as cleanly active", flagged.IsCleanlyOn(AdapterRole.External), false);
    Check("flagged: no 'active' adapter", flagged.Active, null);
    Check("flagged: still reports which adapter is running", flagged.Running, AdapterRole.External);
    Check("flagged: names the flagged adapter", flagged.RestartPendingAdapter?.Role, AdapterRole.External);
    Check("flagged: description mentions it", flagged.Describe().Contains("restart pending"), true);

    var flaggedDisabled = PnpUtilParser.ToSnapshot(devices, id => id == Int);
    Check("flag on the disabled adapter also blocks", flaggedDisabled.Condition, BluetoothCondition.RestartPending);

    // A switch attempt that gets vetoed must not be reported as a clean rollback.
    var (o, hw) = Rig(SimulationMode.VetoedNeedsRestart);
    var r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("vetoed switch: kind", r.Kind, SwitchResultKind.RestartRequired);
    Check("vetoed switch: not success", r.IsSuccess, false);
    Check("vetoed switch: not reported as 'still on original'", r.Kind == SwitchResultKind.StillOnOriginal, false);
    Check("vetoed switch: says a restart is needed", r.Detail.Contains("needing a restart"), true);
    Check("vetoed switch: says Bluetooth still works for now", r.Detail.Contains("keeps working on Downstairs"), true);
    Check("vetoed switch: says what happens after the restart", r.Detail.Contains("will be disabled"), true);
    Check("vetoed switch: the engine did report a rollback", r.Run!.ExitCode, 2);

    // Trying again must not start the engine or ask for elevation.
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("second attempt: kind", r.Kind, SwitchResultKind.RestartRequired);
    Check("second attempt: engine not run again", hw.RunCount, 1);
    Check("second attempt: says nothing was changed", r.Detail.StartsWith("Nothing was changed."), true);

    // After a restart: the flag is gone, the flagged adapter is disabled, Bluetooth is off.
    hw.SetRestartPending(null);
    hw.Set("Disabled", "Disabled", enumerator: false);
    r = await o.SwitchAsync(AdapterRole.Internal, null);
    Check("after restart: both disabled is refused with a recovery command", r.RecoveryCommands.Count, 1);

    // The live reader must be able to ask Windows; an unknown device gives "unknown".
    Check("unknown device: restart flag is unknown, not false", DevNode.NeedsRestart(@"USB\VID_FFFF&PID_FFFF\NOPE"), null);
});

// ---------------------------------------------------------------- progress from adapter state

await Test("progress tracker", async () =>
{
    // Target = internal (Upstairs); original = external (Downstairs).
    var originalActive  = Snap((Brb, "Started"), (Int, "Disabled"), (Ext, "Started"));
    var originalStopping = Snap((Int, "Disabled"), (Ext, "Started"));
    var bothOff         = Snap((Int, "Disabled"), (Ext, "Disabled"));
    var targetStarting  = Snap((Int, "Started"), (Ext, "Disabled"));
    var targetProblem   = Snap((Int, "Problem"), (Ext, "Disabled"));
    var targetActive    = Snap((Brb, "Started"), (Int, "Started"), (Ext, "Disabled"));
    var bothEnabled     = Snap((Brb, "Started"), (Int, "Started"), (Ext, "Started"));
    var missing         = Snap((Brb, "Started"), (Ext, "Started"));

    string Run(params BluetoothSnapshot[] readings)
    {
        var tracker = new SwitchProgressTracker(AdapterRole.Internal);
        return string.Join(",", readings.Select(s => tracker.Next(s)?.ToString() ?? "-"));
    }

    Check("normal switch", Run(originalActive, originalActive, bothOff, bothOff, targetStarting, targetActive),
        "-,-,EnablingTarget,EnablingTarget,WaitingForStart,Verifying");
    Check("original seen while stopping", Run(originalActive, originalStopping, bothOff), "-,DisablingCurrent,EnablingTarget");
    Check("target fails, engine rolls back", Run(originalActive, bothOff, targetProblem, bothOff, originalStopping, originalActive),
        "-,EnablingTarget,WaitingForStart,RollingBack,RollingBack,RollingBack");
    Check("original never stops, engine gives up", Run(originalActive, originalActive, originalActive), "-,-,-");
    Check("original comes back without the target ever starting", Run(originalActive, bothOff, originalActive),
        "-,EnablingTarget,RollingBack");
    Check("both enabled says nothing", Run(bothEnabled), "-");
    Check("missing adapter says nothing", Run(missing), "-");
    Check("other direction", string.Join(",", new[] { targetActive, bothOff, originalActive }
        .Select(new SwitchProgressTracker(AdapterRole.External).Next).Select(p => p?.ToString() ?? "-")),
        "-,EnablingTarget,Verifying");

    // Through the orchestrator, with the simulation slowed just enough to be observed.
    async Task<List<SwitchPhase>> Observe(SimulationMode mode)
    {
        var hw = new SimulatedHardware { Mode = mode, Speed = 0.05 };
        var orchestrator = new SwitchOrchestrator(hw, hw)
        {
            VerifyWindow = TimeSpan.FromMilliseconds(60),
            VerifyInterval = TimeSpan.FromMilliseconds(10),
            ProgressInterval = TimeSpan.FromMilliseconds(5),
        };
        var seen = new List<SwitchPhase>();
        await orchestrator.SwitchAsync(AdapterRole.Internal, new Recorder(seen));
        return seen;
    }

    var normal = await Observe(SimulationMode.Normal);
    Check("simulated switch: shows the target being turned on", normal.Contains(SwitchPhase.EnablingTarget), true);
    Check("simulated switch: never shows a rollback", normal.Contains(SwitchPhase.RollingBack), false);
    Check("simulated switch: ends on verifying", normal[^1], SwitchPhase.Verifying);
    Check("simulated switch: phases only move forward",
        normal.Zip(normal.Skip(1)).All(p => p.First < p.Second), true);

    var rolledBack = await Observe(SimulationMode.FailAndRollBack);
    Check("simulated failure: shows the rollback", rolledBack.Contains(SwitchPhase.RollingBack), true);

    var declined = await Observe(SimulationMode.DeclineApproval);
    Check("declined approval: never shows 'Starting'", declined.Contains(SwitchPhase.Starting), false);
});

// ---------------------------------------------------------------- script verification before elevation
// Read-only: hashes a temp file and reads the permissions of existing system folders.

await Test("engine guard", async () =>
{
    var work = Directory.CreateTempSubdirectory("bts-guard-").FullName;
    var script = Path.Combine(work, "Switch-Adapter.ps1");
    File.WriteAllText(script, "'original'");
    var hash = EngineGuard.Sha256(script);

    Check("hash is 64 hex characters", hash.Length, 64);
    Check("matching hash: ok", EngineGuard.Check(script, new(true, hash, false)).Result, EngineCheck.Ok);
    Check("matching hash, lower case: ok", EngineGuard.Check(script, new(true, hash.ToLowerInvariant(), false)).Result, EngineCheck.Ok);
    Check("no expected hash: refused", EngineGuard.Check(script, new(true, null, false)).Result, EngineCheck.HashUnknown);
    Check("empty expected hash: refused", EngineGuard.Check(script, new(true, " ", false)).Result, EngineCheck.HashUnknown);
    Check("missing script: refused", EngineGuard.Check(Path.Combine(work, "nope.ps1"), new(true, hash, false)).Result, EngineCheck.Missing);

    File.WriteAllText(script, "'tampered'");
    Check("changed script: hash mismatch", EngineGuard.Check(script, new(true, hash, false)).Result, EngineCheck.HashMismatch);
    File.AppendAllText(script, " ");
    Check("one added byte: hash mismatch", EngineGuard.Check(script, new(true, hash, false)).Result, EngineCheck.HashMismatch);

    // Location: a temp folder is writable by the user; Windows folders are not.
    var current = EngineGuard.Sha256(script);
    Check("user-writable folder: refused", EngineGuard.Check(script, new(true, current, true)).Result, EngineCheck.Unprotected);
    Check("user-writable folder is allowed when the policy says so",
        EngineGuard.Check(script, new(true, current, false)).Result, EngineCheck.Ok);
    Check("temp folder is reported unprotected", EngineGuard.WhyUnprotected(new DirectoryInfo(work)) is not null, true);

    var system32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
    var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
    Check("System32 folder is protected", EngineGuard.WhyUnprotected(new DirectoryInfo(system32)), null);
    Check("a System32 file is protected", EngineGuard.WhyUnprotected(new FileInfo(Path.Combine(system32, "pnputil.exe"))), null);
    Check("Program Files folder is protected", EngineGuard.WhyUnprotected(new DirectoryInfo(programFiles)), null);
    Check("a protected, matching file passes the full policy",
        EngineGuard.Check(Path.Combine(system32, "pnputil.exe"),
            new(true, EngineGuard.Sha256(Path.Combine(system32, "pnputil.exe")), true)).Result, EngineCheck.Ok);

    // The runner must refuse before starting anything.
    var logs = Path.Combine(work, "logs");
    var engine = FakeEngine("ok", work);
    var refused = await new ElevatedScriptRunner(engine, logs) { Elevate = false, Policy = new(true, hash, false) }
        .RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("runner with wrong hash: not started", refused.Status, ScriptRunStatus.StartFailed);
    Check("runner with wrong hash: no log was written", Directory.GetFiles(logs).Length, 0);

    refused = await new ElevatedScriptRunner(engine, logs) { Elevate = false, Policy = new(true, EngineGuard.Sha256(engine), true) }
        .RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("runner in unprotected folder: not started", refused.Status, ScriptRunStatus.StartFailed);
    Check("runner in unprotected folder: no log was written", Directory.GetFiles(logs).Length, 0);

    var hw = new SimulatedHardware { Speed = 0 };
    var result = await new SwitchOrchestrator(hw, new ElevatedScriptRunner(engine, logs) { Elevate = false, Policy = new(true, hash, false) })
        .SwitchAsync(AdapterRole.Internal, null);
    Check("orchestrator with wrong hash: refused", result.Kind, SwitchResultKind.Refused);
    Check("orchestrator with wrong hash: says why", result.Detail.Contains("does not match this build"), true);

    try { Directory.Delete(work, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
});

// ---------------------------------------------------------------- launch path, with real processes
// Starts real powershell.exe processes through the same code the app uses, but without
// the UAC prompt and with the harmless stand-in engine. No device is touched.

await Test("launch path", async () =>
{
    var work = Directory.CreateTempSubdirectory("bts-launch-").FullName;
    var logs = Path.Combine(work, "logs");
    ElevatedScriptRunner Runner(string mode, TimeSpan? timeout = null) =>
        new(FakeEngine(mode, work), logs, timeout) { Elevate = false };

    var starts = new List<int>();
    var r = await Runner("ok").RunAsync(AdapterRole.Internal, starts.Add, CancellationToken.None);
    Check("ok: status", r.Status, ScriptRunStatus.Exited);
    Check("ok: the start was signalled once, with a process id", starts.Count == 1 && starts[0] > 0, true);
    Check("ok: process exit code", r.ProcessExitCode, 0);
    Check("ok: logged exit code", r.LoggedExitCode, 0);
    Check("ok: not an unexpected end", r.EndedUnexpectedly, false);
    Check("ok: arguments reached the script", r.LogLines[0].Contains("Requested target: Upstairs. Execute: True."), true);
    Check("ok: no byte-order mark left in the first line", r.LogLines[0].StartsWith("20"), true);
    Check("ok: all four steps seen", r.LogLines.Count(l => l.Contains("Step ")), 4);
    Check("ok: the script reported the same process id", r.LogLines.Any(l => l.EndsWith($"PID: {starts[0]}")), true);
    Check("ok: log file is kept on disk", File.Exists(r.LogPath), true);
    Check("ok: log file is inside the log folder", Path.GetDirectoryName(r.LogPath), logs);

    r = await Runner("ok").RunAsync(AdapterRole.External, null, CancellationToken.None);
    Check("ok: target for the external adapter", r.LogLines[0].Contains("Requested target: Downstairs."), true);

    r = await Runner("fail").RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("fail: process exit code", r.ProcessExitCode, 2);
    Check("fail: logged exit code", r.LoggedExitCode, 2);

    r = await Runner("die").RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("script exits without its final line: status", r.Status, ScriptRunStatus.Exited);
    Check("script exits without its final line: process exit code", r.ProcessExitCode, 77);
    Check("script exits without its final line: no logged exit code", r.LoggedExitCode, null);
    Check("script exits without its final line: flagged as unexpected", r.EndedUnexpectedly, true);
    Check("script exits without its final line: earlier lines are kept", r.LogLines.Count(l => l.Contains("Step ")), 2);

    // Kill the script from outside while it runs, as Task Manager would.
    var clock = System.Diagnostics.Stopwatch.StartNew();
    r = await Runner("slow").RunAsync(AdapterRole.Internal, async pid =>
    {
        await Task.Delay(1500);   // let it write a few lines first
        System.Diagnostics.Process.GetProcessById(pid).Kill();
    }, CancellationToken.None);
    Check("script killed from outside: status", r.Status, ScriptRunStatus.Exited);
    Check("script killed from outside: flagged as unexpected", r.EndedUnexpectedly, true);
    Check("script killed from outside: noticed promptly", clock.Elapsed < TimeSpan.FromSeconds(10), true);
    Check("script killed from outside: lines written before the kill are kept", r.LogLines.Any(l => l.Contains("Step 1/4")), true);

    // Regression test for 1.0.0: the app used to read the log while the script was
    // appending to it, which made Windows PowerShell's Add-Content fail and the script
    // lose its own log lines. Nothing may open the log during the run any more.
    r = await Runner("chatty").RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("busy log: every line the script wrote is there", r.LogLines.Count(l => l.Contains("chatty line")), 200);
    Check("busy log: final exit code line is there", r.LoggedExitCode, 0);

    // The runner gives up waiting but must leave the script running.
    r = await Runner("late", TimeSpan.FromSeconds(1.5)).RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("timeout: status", r.Status, ScriptRunStatus.TimedOut);
    Check("timeout: an explanation is given", r.Error?.Contains("left running"), true);
    Check("timeout: the log of a still-running script is not read", r.LogLines.Count, 0);
    await Task.Delay(TimeSpan.FromSeconds(6));
    Check("timeout: the script was not killed and finished by itself",
        File.ReadAllText(r.LogPath!).Contains("Exit code: 0."), true);

    r = await new ElevatedScriptRunner(Path.Combine(work, "missing.ps1"), logs) { Elevate = false }
        .RunAsync(AdapterRole.Internal, null, CancellationToken.None);
    Check("missing script: status", r.Status, ScriptRunStatus.StartFailed);

    var filesBefore = Directory.GetFiles(logs).Length;
    using var cancelled = new CancellationTokenSource();
    cancelled.Cancel();
    var threw = false;
    try { await Runner("ok").RunAsync(AdapterRole.Internal, null, cancelled.Token); }
    catch (OperationCanceledException) { threw = true; }
    Check("cancelled before start: throws", threw, true);
    Check("cancelled before start: nothing was started", Directory.GetFiles(logs).Length, filesBefore);

    // Whole flow with a real process: the script reports success, the (simulated)
    // adapters do not change, so the result must not be success.
    var hw = new SimulatedHardware { Speed = 0 };
    var orchestrator = new SwitchOrchestrator(hw, Runner("ok"))
    {
        VerifyWindow = TimeSpan.FromMilliseconds(60),
        VerifyInterval = TimeSpan.FromMilliseconds(10),
    };
    var phases = new List<SwitchPhase>();
    var result = await orchestrator.SwitchAsync(AdapterRole.Internal, new Recorder(phases));
    Check("real process + unchanged adapters: not success", result.Kind, SwitchResultKind.StillOnOriginal);
    Check("real process: opening phases", string.Join(",", phases.Take(3)), "Checking,WaitingForApproval,Starting");
    Check("real process: last phase", phases[^1], SwitchPhase.Verifying);
    Check("real process: the log was still read for the explanation", result.Run!.LoggedExitCode, 0);

    try { Directory.Delete(work, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
});

Console.WriteLine();
Console.WriteLine($"core tests: {passed} passed, {failed} failed");
return failed;

sealed class Recorder(List<SwitchPhase> phases) : IProgress<SwitchProgress>
{
    public void Report(SwitchProgress value) => phases.Add(value.Phase);
}

sealed class Recorder<T>(List<T> items, Action<T>? also = null) : IProgress<T>
{
    public void Report(T value)
    {
        items.Add(value);
        also?.Invoke(value);
    }
}

sealed class ThrowingReader : IDeviceStateReader
{
    public Task<BluetoothSnapshot> ReadAsync(CancellationToken cancellationToken = default) =>
        throw new InvalidOperationException("simulated read failure");
}

/// <summary>Cancels the token right after the pre-check read, before the engine starts.</summary>
sealed class CancelAfterFirstRead(IDeviceStateReader inner, CancellationTokenSource source) : IDeviceStateReader
{
    public async Task<BluetoothSnapshot> ReadAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await inner.ReadAsync(cancellationToken);
        source.Cancel();
        return snapshot;
    }
}
