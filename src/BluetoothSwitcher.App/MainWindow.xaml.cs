using System.Runtime.InteropServices;
using BluetoothSwitcher.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;

namespace BluetoothSwitcher.App;

public sealed partial class MainWindow : Window
{
    private const double WidthDip = 440;

    private readonly AppOptions _options;
    private readonly IDeviceStateReader _reader;
    private readonly SwitchOrchestrator _orchestrator;

    private bool _busy;
    private bool _refreshing;
    private bool _autoStarted;
    private bool _resultPinned;   // a switch result is showing; a refresh must not replace it
    private string _recoveryCommands = string.Empty;

    public MainWindow(AppOptions options)
    {
        _options = options;
        InitializeComponent();

        if (options.Demo)
        {
            // Simulated adapters: no real device is read or changed.
            var simulated = new SimulatedHardware { Mode = options.DemoMode };
            _reader = simulated;
            _orchestrator = new SwitchOrchestrator(simulated, simulated);
            DemoBadge.Visibility = Visibility.Visible;
        }
        else
        {
            _reader = new PnpUtilStateReader();
            var policy = Engine.Policy(allowUnprotected: options.Dev);
            _orchestrator = new SwitchOrchestrator(_reader,
                new ElevatedScriptRunner(Engine.ScriptPath, ElevatedScriptRunner.DefaultLogDirectory) { Policy = policy });

            // The same check runs again right before every switch; this one only
            // tells the user up front.
            var verdict = EngineGuard.Check(Engine.ScriptPath, policy);
            if (!verdict.IsOk)
            {
                HintIcon.Glyph = "";
                HintText.Text = verdict.Result == EngineCheck.Unprotected
                    ? "Switching is disabled: not installed in a protected folder"
                    : "Switching is disabled: the switch script could not be verified";
                ToolTipService.SetToolTip(HintPanel, verdict.Message);
            }
            if (options.Dev)
            {
                DemoBadgeText.Text = "Dev";
                DemoBadge.Visibility = Visibility.Visible;
            }
        }

        ConfigureWindow();
        Root.SizeChanged += (_, _) => FitHeightToContent();
        Root.Loaded += async (_, _) =>
        {
            FitHeightToContent();
            await RefreshAsync();
            if (_options.DemoAutoTarget is { } target && !_autoStarted)
            {
                _autoStarted = true;
                await SwitchToAsync(target);
            }
        };
        Activated += async (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated)
                await RefreshAsync();
        };
    }

    // ------------------------------------------------------------ window chrome

    private void ConfigureWindow()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        // Taskbar and Alt+Tab icon. A missing file must not stop the app from starting.
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(icon))
            AppWindow.SetIcon(icon);

        var titleBar = AppWindow.TitleBar;
        titleBar.ButtonBackgroundColor = Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        titleBar.ButtonForegroundColor = Colors.White;
        titleBar.ButtonInactiveForegroundColor = Colors.Gray;
        titleBar.ButtonHoverForegroundColor = Colors.White;
        titleBar.ButtonHoverBackgroundColor = Windows.UI.Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF);
        titleBar.ButtonPressedForegroundColor = Colors.White;
        titleBar.ButtonPressedBackgroundColor = Windows.UI.Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF);

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }

        // A switch must never be abandoned half way, so the window cannot close during one.
        AppWindow.Closing += (_, args) =>
        {
            if (_busy)
            {
                args.Cancel = true;
                ProgressText.Text = "Please wait: a switch is in progress and cannot be interrupted.";
            }
        };

        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var size = new SizeInt32((int)Math.Round(WidthDip * scale), (int)Math.Round(300 * scale));
        AppWindow.ResizeClient(size);

        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(
            area.X + (area.Width - AppWindow.Size.Width) / 2,
            area.Y + (area.Height - AppWindow.Size.Height) / 3));
    }

    /// <summary>Keeps the window exactly as tall as its content.</summary>
    private void FitHeightToContent()
    {
        if (Root.XamlRoot is null || Root.ActualHeight <= 0)
            return;
        // Compare the area XAML actually has with what the content needs, and move the
        // outer window edge by the difference. This is independent of how much of the
        // window the system counts as title bar.
        var scale = Root.XamlRoot.RasterizationScale;
        var surplus = (int)Math.Floor((Root.XamlRoot.Size.Height - Root.ActualHeight) * scale);
        if (surplus != 0)
            AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, AppWindow.Size.Height - surplus));
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    // ------------------------------------------------------------ state display (read-only)

    private async Task RefreshAsync()
    {
        if (_busy || _refreshing)
            return;
        _refreshing = true;
        try
        {
            var snapshot = await _reader.ReadAsync();
            ShowSnapshot(snapshot);
            if (!_resultPinned)
                ShowStateProblem(snapshot);
        }
        catch (Exception ex)
        {
            ShowUnreadable(ex.Message);
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void ShowSnapshot(BluetoothSnapshot snapshot)
    {
        // In a restart-pending state an adapter is still running; show which one, but
        // never present the state as healthy.
        var active = snapshot.Condition == BluetoothCondition.RestartPending ? snapshot.Running : snapshot.Active;
        (CurrentText.Text, StateIcon.Glyph, var healthy) = snapshot.Condition switch
        {
            BluetoothCondition.RestartPending => ("Restart required", "", false),
            BluetoothCondition.Clean => ($"Current: {AdapterCatalog.Location(active!.Value)}", "", true),
            BluetoothCondition.BothDisabled => ("Bluetooth is off", "", false),
            BluetoothCondition.AdapterMissing => ("Adapter not found", "", false),
            _ => ("State unclear", "", false),
        };
        StateIcon.Foreground = ThemeBrush(healthy ? "SystemFillColorSuccessBrush" : "SystemFillColorCautionBrush");
        StateIcon.Visibility = Visibility.Visible;

        ShowCard(UpstairsCard, UpstairsSub, snapshot.Internal, active == AdapterRole.Internal);
        ShowCard(DownstairsCard, DownstairsSub, snapshot.External, active == AdapterRole.External);
    }

    private void ShowCard(Button card, TextBlock subtitle, AdapterState? adapter, bool isActive)
    {
        if (isActive)
        {
            var flagged = adapter is { NeedsRestart: true };
            var brush = ThemeBrush(flagged ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
            subtitle.Text = flagged ? "Active until restart" : "Active";
            subtitle.Foreground = brush;
            card.BorderBrush = brush;
            card.BorderThickness = new Thickness(2);
        }
        else
        {
            subtitle.Text = adapter is null ? "Not connected"
                : adapter.IsDisabled || adapter.IsStarted ? ShortName(adapter.Name)
                : $"{ShortName(adapter.Name)} ({adapter.Status})";
            subtitle.Foreground = ThemeBrush("TextFillColorSecondaryBrush");
            card.ClearValue(Control.BorderBrushProperty);
            card.BorderThickness = new Thickness(1);
        }
        card.IsEnabled = !_busy;
    }

    /// <summary>"MediaTek Bluetooth Adapter" becomes "MediaTek".</summary>
    private static string ShortName(string description)
    {
        var first = description.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return string.IsNullOrEmpty(first) ? "Adapter" : first;
    }

    private void ShowStateProblem(BluetoothSnapshot snapshot)
    {
        if (snapshot.Condition == BluetoothCondition.Clean)
        {
            ResultBar.IsOpen = false;
            HintPanel.Visibility = Visibility.Visible;
            return;
        }

        if (snapshot.Condition == BluetoothCondition.RestartPending)
        {
            ShowBar(InfoBarSeverity.Warning, "Restart required",
                SwitchOrchestrator.DescribeRestartPending(snapshot), [], closable: false);
            return;
        }

        var title = snapshot.Condition switch
        {
            BluetoothCondition.BothDisabled => "Both adapters are disabled",
            BluetoothCondition.BothEnabled => "Both adapters are enabled",
            BluetoothCondition.AdapterMissing => "An adapter is missing",
            _ => "An adapter is enabled but not running",
        };
        ShowBar(InfoBarSeverity.Warning, title, snapshot.Describe() + ".", [], closable: false);
    }

    private void ShowUnreadable(string message)
    {
        CurrentText.Text = "State unknown";
        StateIcon.Glyph = "";
        StateIcon.Foreground = ThemeBrush("SystemFillColorCautionBrush");
        StateIcon.Visibility = Visibility.Visible;
        if (!_resultPinned)
            ShowBar(InfoBarSeverity.Error, "Could not read the adapters", message, [], closable: false);
    }

    // ------------------------------------------------------------ switching

    private async void OnUpstairsClick(object sender, RoutedEventArgs e) => await SwitchToAsync(AdapterRole.Internal);

    private async void OnDownstairsClick(object sender, RoutedEventArgs e) => await SwitchToAsync(AdapterRole.External);

    private async Task SwitchToAsync(AdapterRole target)
    {
        if (_busy)
            return;
        SetBusy(true);
        try
        {
            // Progress arrives on a background thread; marshal it to the UI thread.
            var progress = new DispatcherProgress(DispatcherQueue, ShowProgress);
            var result = await Task.Run(() => _orchestrator.SwitchAsync(target, progress));

            if (result.Snapshot is not null)
                ShowSnapshot(result.Snapshot);
            ShowResult(result);
        }
        catch (Exception ex)
        {
            // Never leave the user guessing: say what is known and re-read the hardware.
            _resultPinned = true;
            ShowBar(InfoBarSeverity.Error, "Unexpected error", ex.Message, [], closable: true);
        }
        finally
        {
            SetBusy(false);
            await RefreshAsync();
        }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        UpstairsCard.IsEnabled = !busy;
        DownstairsCard.IsEnabled = !busy;
        ProgressPanel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        if (busy)
        {
            _resultPinned = false;
            ResultBar.IsOpen = false;
            HintPanel.Visibility = Visibility.Collapsed;
            Progress.ShowError = false;
            Progress.IsIndeterminate = false;
            Progress.Value = 0;
            ProgressText.Text = "Checking adapters";
        }
    }

    private void ShowProgress(SwitchProgress update)
    {
        ProgressText.Text = update.Message;
        switch (update.Phase)
        {
            case SwitchPhase.WaitingForApproval:
                Progress.IsIndeterminate = true;
                break;
            case SwitchPhase.RollingBack:
                Progress.IsIndeterminate = true;
                Progress.ShowError = true;
                break;
            default:
                Progress.IsIndeterminate = false;
                AnimateProgressTo(update.Phase switch
                {
                    SwitchPhase.Checking => 5,
                    SwitchPhase.Starting => 15,
                    SwitchPhase.DisablingCurrent => 30,
                    SwitchPhase.WaitingForStop => 50,
                    SwitchPhase.EnablingTarget => 68,
                    SwitchPhase.WaitingForStart => 85,
                    SwitchPhase.Verifying => 96,
                    _ => Progress.Value,
                });
                break;
        }
    }

    private void AnimateProgressTo(double value)
    {
        var animation = new DoubleAnimation
        {
            To = value,
            Duration = new Duration(TimeSpan.FromMilliseconds(450)),
            EnableDependentAnimation = true,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, Progress);
        Storyboard.SetTargetProperty(animation, "Value");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }

    private void ShowResult(SwitchResult result)
    {
        var severity = result.Kind switch
        {
            SwitchResultKind.Switched or SwitchResultKind.AlreadyActive => InfoBarSeverity.Success,
            SwitchResultKind.Cancelled => InfoBarSeverity.Informational,
            SwitchResultKind.StillOnOriginal or SwitchResultKind.Refused or SwitchResultKind.RestartRequired => InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Error,
        };
        _resultPinned = true;
        ShowBar(severity, result.Title, result.Detail, result.RecoveryCommands, closable: true);
    }

    private void ShowBar(InfoBarSeverity severity, string title, string message, IReadOnlyList<string> commands, bool closable)
    {
        HintPanel.Visibility = Visibility.Collapsed;
        ResultBar.Severity = severity;
        ResultBar.Title = title;
        ResultBar.Message = message;
        ResultBar.IsClosable = closable;
        _recoveryCommands = string.Join(Environment.NewLine, commands);
        RecoveryText.Text = _recoveryCommands;
        RecoveryPanel.Visibility = commands.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ResultBar.IsOpen = true;
    }

    private async void OnResultClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        _resultPinned = false;
        HintPanel.Visibility = Visibility.Visible;
        await RefreshAsync();
    }

    private void OnCopyRecovery(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(_recoveryCommands);
        Clipboard.SetContent(package);
    }

    private static Brush ThemeBrush(string key) => (Brush)Application.Current.Resources[key];

    private sealed class DispatcherProgress(
        Microsoft.UI.Dispatching.DispatcherQueue queue, Action<SwitchProgress> handler) : IProgress<SwitchProgress>
    {
        public void Report(SwitchProgress value) => queue.TryEnqueue(() => handler(value));
    }
}
