using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace BluetoothSwitcher.Core;

public enum ScriptRunStatus
{
    /// <summary>The script process started and exited.</summary>
    Exited,

    /// <summary>The user declined the UAC prompt. Nothing was started.</summary>
    Declined,

    /// <summary>The script could not be started. Nothing was changed.</summary>
    StartFailed,

    /// <summary>The script was still running when the time limit passed. It was left running.</summary>
    TimedOut,
}

/// <summary>
/// What is known about one run of the switch script. None of this proves a switch
/// happened; the caller must verify real adapter state.
/// </summary>
public sealed record ScriptRunResult(
    ScriptRunStatus Status,
    int? ProcessExitCode,
    int? LoggedExitCode,
    string? LogPath,
    IReadOnlyList<string> LogLines,
    string? Error)
{
    /// <summary>The exit code the script logged, falling back to the process exit code.</summary>
    public int? ExitCode => LoggedExitCode ?? ProcessExitCode;

    /// <summary>
    /// True when the process ended without writing its final "Exit code" line, for
    /// example because it was killed or crashed.
    /// </summary>
    public bool EndedUnexpectedly => Status == ScriptRunStatus.Exited && LoggedExitCode is null;
}

/// <summary>Runs the switching engine for one target. May change device state.</summary>
public interface ISwitchRunner
{
    /// <param name="cancellationToken">
    /// Honoured only until the script has been started. A running script is never stopped.
    /// </param>
    Task<ScriptRunResult> RunAsync(AdapterRole target, IProgress<string>? logLine, CancellationToken cancellationToken);
}

/// <summary>
/// Starts poc/Switch-Adapter.ps1 elevated (one UAC prompt) and follows its log file.
/// The calling process itself stays unelevated.
/// </summary>
public sealed partial class ElevatedScriptRunner : ISwitchRunner
{
    private const int ErrorCancelled = 1223; // ERROR_CANCELLED: the UAC prompt was declined.
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(150);

    private readonly string _scriptPath;
    private readonly string _logDirectory;
    private readonly TimeSpan _timeout;

    /// <param name="timeout">
    /// Longer than the script's own worst case: detection, 15 s stop, 2 s settle, 30 s start,
    /// then a full rollback (15 s + 5 s + 30 s).
    /// </param>
    public ElevatedScriptRunner(string scriptPath, string logDirectory, TimeSpan? timeout = null)
    {
        _scriptPath = scriptPath;
        _logDirectory = logDirectory;
        _timeout = timeout ?? TimeSpan.FromMinutes(3);
    }

    /// <summary>
    /// False starts the script without the UAC prompt. Only the tests use this, with a
    /// harmless stand-in script, to exercise the launch and log-following code.
    /// </summary>
    public bool Elevate { get; init; } = true;

    /// <summary>Checks the script must pass immediately before every launch.</summary>
    public EnginePolicy Policy { get; init; } = EnginePolicy.None;

    public static string PowerShellPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");

    public static string DefaultLogDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BluetoothSwitcher", "logs");

    /// <summary>The exact command line passed to powershell.exe. Exposed for tests.</summary>
    public static string BuildArguments(string scriptPath, AdapterRole target, string logPath)
    {
        if (scriptPath.Contains('"') || logPath.Contains('"'))
            throw new ArgumentException("Paths must not contain quotes.");
        return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " +
               $"-File \"{scriptPath}\" -Target {AdapterCatalog.Location(target)} -Execute -LogPath \"{logPath}\"";
    }

    public async Task<ScriptRunResult> RunAsync(AdapterRole target, IProgress<string>? logLine, CancellationToken cancellationToken)
    {
        if (!File.Exists(_scriptPath))
            return Failed($"Switch script not found: {_scriptPath}");

        string logPath;
        try
        {
            Directory.CreateDirectory(_logDirectory);
            logPath = Path.Combine(_logDirectory, $"app-switch-{DateTime.Now:yyyyMMdd-HHmmss-fff}.log");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Failed("Cannot create the log folder: " + ex.Message);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = PowerShellPath,
            Arguments = BuildArguments(_scriptPath, target, logPath),
            UseShellExecute = true,   // required for the "runas" verb
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        if (Elevate)
            startInfo.Verb = "runas";   // Windows shows the UAC prompt

        // Last point at which cancelling is safe: nothing has been started yet.
        cancellationToken.ThrowIfCancellationRequested();

        // Verify the script as late as possible, right before asking for elevation.
        var verdict = EngineGuard.Check(_scriptPath, Policy);
        if (!verdict.IsOk)
            return Failed(verdict.Message);

        Process? process;
        try
        {
            // Blocks until the UAC prompt is answered, so keep it off the UI thread.
            process = await Task.Run(() => Process.Start(startInfo), CancellationToken.None).ConfigureAwait(false);
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == ErrorCancelled)
        {
            return new ScriptRunResult(ScriptRunStatus.Declined, null, null, null, [], null);
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            return Failed("Could not start the switch script: " + ex.Message);
        }

        if (process is null)
            return Failed("Could not start the switch script.");

        // From here on the script may be changing device state. It is never killed and
        // the cancellation token is deliberately ignored.
        using (process)
        {
            var tail = new LogTail(logPath);
            var lines = new List<string>();
            var clock = Stopwatch.StartNew();

            void Pump()
            {
                foreach (var line in tail.ReadNewLines())
                {
                    lines.Add(line);
                    logLine?.Report(line);
                }
            }

            while (!process.HasExited)
            {
                if (clock.Elapsed > _timeout)
                {
                    Pump();
                    return new ScriptRunResult(ScriptRunStatus.TimedOut, null, ParseLoggedExitCode(lines), logPath, lines,
                        $"The switch script was still running after {_timeout.TotalSeconds:0} seconds. It was left running.");
                }
                Pump();
                await Task.Delay(PollInterval, CancellationToken.None).ConfigureAwait(false);
            }

            // Give the last log lines a moment to reach the disk, then read them.
            await Task.Delay(PollInterval, CancellationToken.None).ConfigureAwait(false);
            Pump();

            int? processExitCode = null;
            try { processExitCode = process.ExitCode; }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { }

            return new ScriptRunResult(ScriptRunStatus.Exited, processExitCode, ParseLoggedExitCode(lines), logPath, lines, null);
        }
    }

    /// <summary>Reads the script's final "Exit code: N." line, if it wrote one.</summary>
    public static int? ParseLoggedExitCode(IEnumerable<string> lines)
    {
        int? code = null;
        foreach (var line in lines)
        {
            var match = ExitCodeLine().Match(line);
            if (match.Success)
                code = int.Parse(match.Groups[1].Value);
        }
        return code;
    }

    private static ScriptRunResult Failed(string error) =>
        new(ScriptRunStatus.StartFailed, null, null, null, [], error);

    [GeneratedRegex(@"\]\s+Exit code:\s*(-?\d+)\.\s*$")]
    private static partial Regex ExitCodeLine();
}

/// <summary>Reads lines appended to a log file that another process is still writing.</summary>
public sealed class LogTail(string path)
{
    private long _position;
    private string _partial = string.Empty;

    public IReadOnlyList<string> ReadNewLines()
    {
        var result = new List<string>();
        try
        {
            if (!File.Exists(path))
                return result;

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length <= _position)
                return result;

            stream.Seek(_position, SeekOrigin.Begin);
            var buffer = new byte[stream.Length - _position];
            var read = stream.Read(buffer, 0, buffer.Length);
            _position += read;

            var text = _partial + Encoding.UTF8.GetString(buffer, 0, read);
            var pieces = text.Split('\n');
            _partial = pieces[^1];   // an unfinished line stays for the next read
            for (var i = 0; i < pieces.Length - 1; i++)
            {
                var line = pieces[i].TrimEnd('\r').TrimStart('﻿');
                if (line.Length > 0)
                    result.Add(line);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The writer may hold the file briefly; try again on the next poll.
        }
        return result;
    }
}
