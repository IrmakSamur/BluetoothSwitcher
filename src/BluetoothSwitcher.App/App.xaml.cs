using BluetoothSwitcher.Core;
using Microsoft.UI.Xaml;

namespace BluetoothSwitcher.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow(AppOptions.Parse(Environment.GetCommandLineArgs().Skip(1)));
        _window.Activate();
    }
}

/// <summary>
/// Command-line options.
///   (none)                 real adapters; switching starts the elevated script.
///   --demo[=mode]          simulated adapters, no real device is read or changed.
///                          mode: normal (default), fail, die, decline, lie.
///   --demo-auto=Upstairs   in demo mode only: start one switch automatically.
/// </summary>
public sealed record AppOptions(bool Demo, SimulationMode DemoMode, AdapterRole? DemoAutoTarget)
{
    public static AppOptions Parse(IEnumerable<string> args)
    {
        var demo = false;
        var mode = SimulationMode.Normal;
        AdapterRole? auto = null;

        foreach (var arg in args)
        {
            if (arg.Equals("--demo", StringComparison.OrdinalIgnoreCase))
            {
                demo = true;
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
        return new AppOptions(demo, mode, demo ? auto : null);
    }
}
