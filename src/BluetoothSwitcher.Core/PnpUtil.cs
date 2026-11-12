using System.Diagnostics;
using System.Xml.Linq;

namespace BluetoothSwitcher.Core;

/// <summary>Parses "pnputil /enum-devices ... /format xml" output.</summary>
public static class PnpUtilParser
{
    public static IReadOnlyList<PnpDevice> Parse(string xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
            throw new FormatException("pnputil returned no output.");

        XDocument doc;
        try
        {
            doc = XDocument.Parse(xml);
        }
        catch (System.Xml.XmlException ex)
        {
            throw new FormatException("pnputil output is not valid XML: " + ex.Message, ex);
        }

        if (doc.Root is null || doc.Root.Name.LocalName != "PnpUtil")
            throw new FormatException("pnputil output has an unexpected root element.");

        var devices = new List<PnpDevice>();
        foreach (var node in doc.Root.Elements("Device"))
        {
            var id = (string?)node.Attribute("InstanceId");
            if (string.IsNullOrWhiteSpace(id))
                continue;
            devices.Add(new PnpDevice(
                id,
                ((string?)node.Element("DeviceDescription") ?? string.Empty).Trim(),
                ((string?)node.Element("Status") ?? string.Empty).Trim()));
        }
        return devices;
    }

    /// <summary>Builds a snapshot of the two adapters from a device list.</summary>
    /// <param name="needsRestart">
    /// Says whether a device (by instance ID) is flagged as needing a system restart.
    /// pnputil's output does not include this, so it is looked up separately.
    /// </param>
    public static BluetoothSnapshot ToSnapshot(IReadOnlyList<PnpDevice> devices, Func<string, bool>? needsRestart = null)
    {
        List<AdapterState> Find(AdapterRole role)
        {
            var prefix = AdapterCatalog.HardwareId(role) + @"\";
            return devices
                .Where(d => d.InstanceId.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                .Select(d => new AdapterState(role, d.InstanceId, d.Description, d.Status,
                    needsRestart?.Invoke(d.InstanceId) ?? false))
                .ToList();
        }

        var enumeratorStarted = devices.Any(d =>
            d.InstanceId.StartsWith(AdapterCatalog.EnumeratorPrefix, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(d.Status, "Started", StringComparison.OrdinalIgnoreCase));

        return new BluetoothSnapshot(Find(AdapterRole.Internal), Find(AdapterRole.External), enumeratorStarted);
    }
}

/// <summary>Reads the current adapter state. Implementations must never change device state.</summary>
public interface IDeviceStateReader
{
    Task<BluetoothSnapshot> ReadAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Reads adapter state with one read-only pnputil call. Needs no administrator rights.
/// </summary>
public sealed class PnpUtilStateReader : IDeviceStateReader
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(15);

    public static string PnpUtilPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "pnputil.exe");

    public async Task<BluetoothSnapshot> ReadAsync(CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = PnpUtilPath,
            // Read-only enumeration. This is the only pnputil command this app ever runs itself.
            Arguments = "/enum-devices /connected /class Bluetooth /format xml",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Could not start pnputil.");

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = await stdout.ConfigureAwait(false);
            await stderr.ConfigureAwait(false);

            if (process.ExitCode != 0)
                throw new InvalidOperationException($"pnputil exited with code {process.ExitCode}.");

            // An unknown answer counts as "not flagged": the flag only ever adds a refusal.
            return PnpUtilParser.ToSnapshot(PnpUtilParser.Parse(output), id => DevNode.NeedsRestart(id) ?? false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // A read-only enumeration is safe to kill.
            try { process.Kill(); } catch (InvalidOperationException) { }
            throw new TimeoutException("pnputil did not answer in time.");
        }
    }
}
