using System;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

namespace SkyHook.Services;

/// <summary>
/// Detects whether WinFSP is installed and provides version information.
/// WinFSP is required for rclone mount on Windows (provides the FUSE layer).
/// </summary>
public class WinFspService
{
    private const string RegistryKeyPath = @"SOFTWARE\WOW6432Node\WinFsp";
    private const string DllPath = @"C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll";
    private const string DownloadUrl = "https://github.com/winfsp/winfsp/releases/latest";

    /// <summary>
    /// Whether WinFSP is detected on this system.
    /// </summary>
    public bool IsInstalled { get; private set; }

    /// <summary>
    /// The installed WinFSP version string, or null if not detected.
    /// </summary>
    public string? Version { get; private set; }

    /// <summary>
    /// Check both the Registry key and the DLL file to determine WinFSP installation status.
    /// </summary>
    public void Detect()
    {
        IsInstalled = false;
        Version = null;

        // Check Registry
        bool registryFound = false;
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(RegistryKeyPath, false);
            if (key != null)
            {
                registryFound = true;

                // Try to read version from InstallDir parent key or sub-keys
                var installDir = key.GetValue("InstallDir") as string;
                if (!string.IsNullOrEmpty(installDir))
                {
                    // Version is often embedded in the install dir path or a sibling value
                    Version = ExtractVersionFromRegistry(key);
                }
            }
        }
        catch
        {
            // Registry access may fail without admin; that's fine
        }

        // Check DLL file exists
        bool dllFound = File.Exists(DllPath);

        IsInstalled = registryFound && dllFound;

        // If we found the DLL but couldn't get version from registry, try the DLL version info
        if (IsInstalled && string.IsNullOrEmpty(Version))
        {
            try
            {
                var versionInfo = FileVersionInfo.GetVersionInfo(DllPath);
                if (!string.IsNullOrEmpty(versionInfo.ProductVersion))
                {
                    Version = versionInfo.ProductVersion;
                }
                else if (!string.IsNullOrEmpty(versionInfo.FileVersion))
                {
                    Version = versionInfo.FileVersion;
                }
            }
            catch
            {
                // Version detection is best-effort
            }
        }
    }

    /// <summary>
    /// Open the WinFSP GitHub releases page in the user's default browser.
    /// </summary>
    public void OpenDownloadPage()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = DownloadUrl,
                UseShellExecute = true
            });
        }
        catch
        {
            // Browser launch failed — non-critical
        }
    }

    // ── Private Helpers ──────────────────────────────────────────

    private static string? ExtractVersionFromRegistry(RegistryKey key)
    {
        // Try common value names for version
        foreach (var valueName in new[] { "Version", "ProductVersion", "DisplayVersion" })
        {
            var val = key.GetValue(valueName) as string;
            if (!string.IsNullOrEmpty(val))
                return val;
        }

        // Check sub-keys (WinFsp sometimes stores version as a sub-key name)
        var subKeyNames = key.GetSubKeyNames();
        foreach (var name in subKeyNames)
        {
            // Sub-key names are typically version numbers like "2.0"
            if (name.Length > 0 && char.IsDigit(name[0]))
                return name;
        }

        return null;
    }
}
