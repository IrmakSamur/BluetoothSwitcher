using System.Reflection;
using BluetoothSwitcher.Core;
using Microsoft.UI.Xaml;

namespace BluetoothSwitcher.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        var options = AppOptions.Parse(Environment.GetCommandLineArgs().Skip(1));
        if (options.VerifyInstall)
        {
            // No window: report through the exit code whether this copy may switch.
            // 0 = verified, otherwise 10 + EngineCheck (11 missing, 12 hash unknown,
            // 13 hash mismatch, 14 unprotected folder).
            var verdict = EngineGuard.Check(Engine.ScriptPath, Engine.Policy(allowUnprotected: false));
            Environment.Exit(verdict.IsOk ? 0 : 10 + (int)verdict.Result);
        }

        Options = options;
        InitializeComponent();
    }

    public AppOptions Options { get; }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow(Options);
        _window.Activate();
    }
}

/// <summary>Where the switch script is and what it must satisfy before it is run elevated.</summary>
public static class Engine
{
    public static string ScriptPath => Path.Combine(AppContext.BaseDirectory, "Switch-Adapter.ps1");

    /// <summary>SHA-256 of poc/Switch-Adapter.ps1, embedded by the build (see the .csproj).</summary>
    public static string? ExpectedSha256 => typeof(Engine).Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "SwitchScriptSha256")?.Value;

    public static EnginePolicy Policy(bool allowUnprotected) =>
        new(VerifyHash: true, ExpectedSha256, RequireProtectedLocation: !allowUnprotected);
}

/// <summary>
/// Command-line options.
///   (none)                 real adapters; switching starts the elevated script, but only
///                          from a protected install folder.
///   --dev                  allow switching from an unprotected folder (development builds).
///                          The script's hash is still verified.
///   --verify-install       no window; exit code says whether this copy may switch.
///   --demo[=mode]          simulated adapters, no real device is read or changed.
///                          mode: normal (default), fail, die, decline, lie.
///   --demo-auto=Upstairs   in demo mode only: start one switch automatically.
/// </summary>
public sealed record AppOptions(bool Demo, SimulationMode DemoMode, AdapterRole? DemoAutoTarget, bool Dev, bool VerifyInstall)
{
    public static AppOptions Parse(IEnumerable<string> args)
    {
        var demo = false;
        var dev = false;
        var verify = false;
        var mode = SimulationMode.Normal;
        AdapterRole? auto = null;

        foreach (var arg in args)
        {
            if (arg.Equals("--demo", StringComparison.OrdinalIgnoreCase))
            {
                demo = true;
            }
            else if (arg.Equals("--dev", StringComparison.OrdinalIgnoreCase))
            {
                dev = true;
            }
            else if (arg.Equals("--verify-install", StringComparison.OrdinalIgnoreCase))
            {
                verify = true;
            }
            else if (arg.StartsWith("--demo=", StringComparison.OrdinalIgnoreCase))
            {
                demo = true;
                mode = arg["--demo=".Length..].ToLowerInvariant() switch
                {
                    "fail" => SimulationMode.FailAndRollBack,
                    "die" => SimulationMode.DieMidSwitch,
                    "decline" => SimulationMode.DeclineApproval,
                    "lie" => SimulationMode.LieAboutSuccess,
                    "veto" => SimulationMode.VetoedNeedsRestart,
                    _ => SimulationMode.Normal,
                };
            }
            else if (arg.StartsWith("--demo-auto=", StringComparison.OrdinalIgnoreCase))
            {
                auto = arg["--demo-auto=".Length..].Equals("Upstairs", StringComparison.OrdinalIgnoreCase)
                    ? AdapterRole.Internal
                    : AdapterRole.External;
            }
        }

        // An automatic switch is only ever allowed against simulated hardware.
        return new AppOptions(demo, mode, demo ? auto : null, dev, verify);
    }
}
