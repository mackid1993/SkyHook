using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace SkyHook.Helpers;

/// <summary>
/// JSON-backed application settings persisted at %APPDATA%\SkyHook\settings.json.
/// LaunchAtLogin is additionally backed by the Windows Registry Run key.
/// </summary>
public class AppSettings
{
    private static readonly object _lock = new();
    private static AppSettings? _instance;

    /// <summary>
    /// Singleton instance. Loads from disk on first access.
    /// </summary>
    public static AppSettings Instance
    {
        get
        {
            if (_instance == null)
            {
                lock (_lock)
                {
                    _instance ??= Load();
                }
            }
            return _instance;
        }
    }

    // ── Serialized Properties ────────────────────────────────────

    [JsonPropertyName("autoMountOnLaunch")]
    public bool AutoMountOnLaunch { get; set; }

    [JsonPropertyName("rclonePath")]
    public string RclonePath { get; set; } = string.Empty;

    [JsonPropertyName("remoteOrder")]
    public List<string> RemoteOrder { get; set; } = new();

    [JsonPropertyName("perRemoteDriveLetters")]
    public Dictionary<string, string> PerRemoteDriveLetters { get; set; } = new();

    [JsonPropertyName("perRemoteAutoMount")]
    public Dictionary<string, bool> PerRemoteAutoMount { get; set; } = new();

    [JsonPropertyName("perRemoteRemotePaths")]
    public Dictionary<string, string> PerRemoteRemotePaths { get; set; } = new();

    // ── LaunchAtLogin (Registry-backed) ──────────────────────────

    private const string RunKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "SkyHook";

    private bool _launchAtLogin;

    [JsonPropertyName("launchAtLogin")]
    public bool LaunchAtLogin
    {
        get => _launchAtLogin;
        set
        {
            _launchAtLogin = value;
            ApplyLaunchAtLogin(value);
        }
    }

    // ── Paths ────────────────────────────────────────────────────

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static string SettingsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SkyHook");

    private static string SettingsPath =>
        Path.Combine(SettingsDir, "settings.json");

    // ── Load / Save ──────────────────────────────────────────────

    /// <summary>
    /// Load settings from disk. Returns default settings if file does not exist or is invalid.
    /// Also reads the current LaunchAtLogin state from the Registry.
    /// </summary>
    public static AppSettings Load()
    {
        AppSettings settings;

        try
        {
            if (File.Exists(SettingsPath))
            {
                var json = File.ReadAllText(SettingsPath);
                settings = JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
            }
            else
            {
                settings = new AppSettings();
            }
        }
        catch
        {
            settings = new AppSettings();
        }

        // Sync LaunchAtLogin from Registry (source of truth)
        settings._launchAtLogin = ReadLaunchAtLoginFromRegistry();

        lock (_lock)
        {
            _instance = settings;
        }

        return settings;
    }

    /// <summary>
    /// Persist current settings to %APPDATA%\SkyHook\settings.json.
    /// </summary>
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDir);
            var json = JsonSerializer.Serialize(this, JsonOptions);
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // Silently fail — settings are non-critical
        }
    }

    // ── Registry Helpers ─────────────────────────────────────────

    private static bool ReadLaunchAtLoginFromRegistry()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false);
            return key?.GetValue(AppName) != null;
        }
        catch
        {
            return false;
        }
    }

    private static void ApplyLaunchAtLogin(bool enable)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
            if (key == null) return;

            if (enable)
            {
                var exePath = Environment.ProcessPath ?? string.Empty;
                if (!string.IsNullOrEmpty(exePath))
                {
                    key.SetValue(AppName, $"\"{exePath}\"");
                }
            }
            else
            {
                key.DeleteValue(AppName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Silently fail — non-critical
        }
    }
}
