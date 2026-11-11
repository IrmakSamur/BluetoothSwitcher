using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;

namespace BluetoothSwitcher.Core;

/// <summary>What must be true of the switch script before it may be started elevated.</summary>
/// <param name="VerifyHash">Compare the script with <paramref name="ExpectedSha256"/>.</param>
/// <param name="ExpectedSha256">Hash embedded in the app at build time (hex).</param>
/// <param name="RequireProtectedLocation">
/// The script and its folder must be writable by administrators only. Development
/// builds turn this off explicitly; installed copies never do.
/// </param>
public sealed record EnginePolicy(bool VerifyHash, string? ExpectedSha256, bool RequireProtectedLocation)
{
    /// <summary>No checks. Only for tests that use the harmless stand-in script.</summary>
    public static EnginePolicy None { get; } = new(false, null, false);
}

public enum EngineCheck
{
    Ok,
    Missing,
    HashUnknown,
    HashMismatch,
    Unprotected,
}

public sealed record EngineVerdict(EngineCheck Result, string Message)
{
    public bool IsOk => Result == EngineCheck.Ok;
}

/// <summary>
/// Decides whether the switch script is safe to run as administrator. The UAC prompt
/// only says "Windows PowerShell", so the user cannot see which script they approve;
/// this check is what ties the approval to the script that was built and installed.
/// </summary>
public static class EngineGuard
{
    private const string TrustedInstallerSid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
    private const string CreatorOwnerSid = "S-1-3-0";

    // Any of these lets someone replace or alter a file or folder.
    private const FileSystemRights WriteRights =
        FileSystemRights.WriteData | FileSystemRights.AppendData |
        FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes |
        FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;

    // GENERIC_WRITE and GENERIC_ALL, which appear unmapped in inherit-only entries.
    private const int GenericWriteOrAll = 0x40000000 | 0x10000000;

    public static EngineVerdict Check(string scriptPath, EnginePolicy policy)
    {
        if (!File.Exists(scriptPath))
            return new(EngineCheck.Missing, $"Switch script not found: {scriptPath}");

        if (policy.RequireProtectedLocation)
        {
            // Location first: a hash check means little if the files can be swapped
            // right after it.
            var folder = new FileInfo(scriptPath).Directory!;
            var reason = WhyUnprotected(new FileInfo(scriptPath))
                         ?? WhyUnprotected(folder)
                         ?? (folder.Parent is { } parent ? WhyUnprotected(parent) : null);
            if (reason is not null)
                return new(EngineCheck.Unprotected,
                    "Switching is disabled because the app is not installed in a protected folder. " + reason);
        }

        if (policy.VerifyHash)
        {
            if (string.IsNullOrWhiteSpace(policy.ExpectedSha256))
                return new(EngineCheck.HashUnknown, "This build does not know the switch script's hash, so it will not run it.");

            string actual;
            try
            {
                actual = Sha256(scriptPath);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return new(EngineCheck.Missing, "The switch script could not be read: " + ex.Message);
            }

            if (!string.Equals(actual, policy.ExpectedSha256.Trim(), StringComparison.OrdinalIgnoreCase))
                return new(EngineCheck.HashMismatch,
                    "The switch script does not match this build of the app, so it was not started. Reinstall the app.");
        }

        return new(EngineCheck.Ok, "The switch script is verified.");
    }

    public static string Sha256(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    /// <summary>
    /// Returns null when only SYSTEM, Administrators or TrustedInstaller own and can
    /// modify the item; otherwise a sentence saying why not.
    /// </summary>
    public static string? WhyUnprotected(FileSystemInfo item)
    {
        try
        {
            FileSystemSecurity security = item switch
            {
                DirectoryInfo directory => directory.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access),
                FileInfo file => file.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access),
                _ => throw new ArgumentException("Unsupported item.", nameof(item)),
            };

            if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !IsTrusted(owner))
                return $"{item.FullName} is owned by an account that is not an administrator.";

            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow)
                    continue;
                var who = (SecurityIdentifier)rule.IdentityReference;
                // CREATOR OWNER entries apply to whoever creates a child item; creating
                // one already requires write access, which is what is being checked.
                if (IsTrusted(who) || who.Value == CreatorOwnerSid)
                    continue;

                var canWrite = (rule.FileSystemRights & WriteRights) != 0 ||
                               ((int)rule.FileSystemRights & GenericWriteOrAll) != 0;
                if (canWrite)
                    return $"{item.FullName} can be modified by {Describe(who)}.";
            }
            return null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SystemException)
        {
            // If the permissions cannot be read, do not assume they are fine.
            return $"The permissions of {item.FullName} could not be read ({ex.Message}).";
        }
    }

    private static bool IsTrusted(SecurityIdentifier sid) =>
        sid.IsWellKnown(WellKnownSidType.LocalSystemSid) ||
        sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) ||
        sid.Value == TrustedInstallerSid;

    private static string Describe(SecurityIdentifier sid)
    {
        try { return sid.Translate(typeof(NTAccount)).Value; }
        catch (Exception ex) when (ex is IdentityNotMappedException or SystemException) { return sid.Value; }
    }
}
