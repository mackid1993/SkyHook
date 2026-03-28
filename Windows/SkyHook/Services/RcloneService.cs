using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using SkyHook.Helpers;
using SkyHook.Models;

namespace SkyHook.Services;

/// <summary>
/// Main service for managing rclone remotes, mounts, and lifecycle.
/// Ported from macOS RcloneService.swift. Singleton with INotifyPropertyChanged via ObservableObject.
/// On Windows, rclone mount uses WinFSP and blocks (foreground process), so we keep
/// the Process object alive. Unmount kills the process. Drive letters replace mount paths.
/// </summary>
public partial class RcloneService : ObservableObject
{
    private static readonly Lazy<RcloneService> _lazy = new(() => new RcloneService());
    public static RcloneService Instance => _lazy.Value;

    // ── Observable Properties ────────────────────────────────────

    [ObservableProperty]
    private ObservableCollection<Remote> _remotes = new();

    [ObservableProperty]
    private string? _rcloneVersion;

    [ObservableProperty]
    private bool _isRcloneInstalled;

    [ObservableProperty]
    private bool _isDownloadingRclone;

    [ObservableProperty]
    private string? _latestVersion;

    [ObservableProperty]
    private string? _statusMessage;

    // MountStatuses needs manual notification since Dictionary is not observable
    private readonly Dictionary<string, MountStatus> _mountStatuses = new();
    private readonly Dictionary<string, string> _mountErrors = new(); // remote name -> error message

    public IReadOnlyDictionary<string, MountStatus> MountStatuses => _mountStatuses;

    // ── Private State ────────────────────────────────────────────

    private readonly Dictionary<string, Process> _mountProcesses = new();
    private readonly Dictionary<string, string> _mountDriveLetters = new(); // remote name -> "Z:"
    private readonly Dictionary<string, int> _rcPorts = new(); // remote name -> RC port
    private readonly Dictionary<string, int> _consecutiveFailures = new();
    private int _nextRCPort = 19400;
    private CancellationTokenSource? _healthCts;
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(10) };
    private readonly object _lock = new();

    // ── Paths ────────────────────────────────────────────────────

    private static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SkyHook");

    private static string RcloneExePath =>
        Path.Combine(InstallDir, "rclone.exe");

    private static string RcloneConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "rclone", "rclone.conf");

    public string EffectiveRclonePath
    {
        get
        {
            // Prefer custom path from settings
            var custom = AppSettings.Instance.RclonePath;
            if (!string.IsNullOrEmpty(custom) && File.Exists(custom))
                return custom;

            // Fall back to managed install
            return File.Exists(RcloneExePath) ? RcloneExePath : string.Empty;
        }
    }

    // ── Computed ─────────────────────────────────────────────────

    public int MountedCount
    {
        get
        {
            lock (_lock)
            {
                return _mountStatuses.Values.Count(s => s == MountStatus.Mounted);
            }
        }
    }

    public bool UpdateAvailable
    {
        get
        {
            if (string.IsNullOrEmpty(RcloneVersion) || string.IsNullOrEmpty(LatestVersion))
                return false;
            return RcloneVersion.Trim() != LatestVersion.Trim();
        }
    }

    // ── Constructor / Setup ──────────────────────────────────────

    private RcloneService()
    {
        // Synchronous detection so UI is not grayed out on launch
        IsRcloneInstalled = File.Exists(RcloneExePath) ||
                            (!string.IsNullOrEmpty(AppSettings.Instance.RclonePath) &&
                             File.Exists(AppSettings.Instance.RclonePath));
        LoadRemotes();
    }

    /// <summary>
    /// Async setup to be called after construction (e.g., from App.OnStartup).
    /// </summary>
    public async Task SetupAsync()
    {
        await DetectRclone();
        await CleanupOrphans();

        if (IsRcloneInstalled && AppSettings.Instance.AutoMountOnLaunch)
        {
            await AutoMountRemotes();
        }

        await CheckForUpdate();
        StartHealthMonitor();
    }

    // ── rclone Detection ─────────────────────────────────────────

    public async Task DetectRclone()
    {
        var path = EffectiveRclonePath;
        if (string.IsNullOrEmpty(path))
        {
            IsRcloneInstalled = false;
            RcloneVersion = null;
            return;
        }

        IsRcloneInstalled = true;
        RcloneVersion = await FetchVersion();
    }

    private async Task<string?> FetchVersion()
    {
        var path = EffectiveRclonePath;
        if (string.IsNullOrEmpty(path)) return null;

        var output = await ProcessHelper.RunAndCapture(path, new List<string> { "version" });
        if (string.IsNullOrEmpty(output)) return null;

        var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return firstLine?.Replace("rclone ", "").Trim();
    }

    public async Task CheckForUpdate()
    {
        try
        {
            var json = await _httpClient.GetStringAsync("https://api.github.com/repos/rclone/rclone/releases/latest");
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("tag_name", out var tag))
            {
                LatestVersion = tag.GetString();
            }
        }
        catch
        {
            // Network failure is non-critical
        }
    }

    // ── Install / Update / Uninstall rclone ──────────────────────

    public async Task DownloadAndInstallRclone()
    {
        IsDownloadingRclone = true;
        StatusMessage = "Downloading rclone...";

        try
        {
            // Determine architecture
            var arch = RuntimeInformation.OSArchitecture switch
            {
                Architecture.Arm64 => "arm64",
                _ => "amd64"
            };

            Directory.CreateDirectory(InstallDir);

            // Fetch latest version tag
            string? latestTag = null;
            try
            {
                var releaseJson = await _httpClient.GetStringAsync(
                    "https://api.github.com/repos/rclone/rclone/releases/latest");
                using var doc = JsonDocument.Parse(releaseJson);
                if (doc.RootElement.TryGetProperty("tag_name", out var tag))
                    latestTag = tag.GetString();
            }
            catch { /* fall through to current download */ }

            // Build download URL
            string downloadUrl;
            if (!string.IsNullOrEmpty(latestTag))
            {
                downloadUrl = $"https://github.com/rclone/rclone/releases/download/{latestTag}/rclone-{latestTag}-windows-{arch}.zip";
            }
            else
            {
                downloadUrl = $"https://downloads.rclone.org/rclone-current-windows-{arch}.zip";
            }

            // Download zip
            var tempDir = Path.Combine(Path.GetTempPath(), $"skyhook-rclone-{Guid.NewGuid()}");
            Directory.CreateDirectory(tempDir);
            var zipPath = Path.Combine(tempDir, "rclone.zip");

            StatusMessage = "Downloading rclone...";
            using (var response = await _httpClient.GetAsync(downloadUrl))
            {
                response.EnsureSuccessStatusCode();
                var bytes = await response.Content.ReadAsByteArrayAsync();
                await File.WriteAllBytesAsync(zipPath, bytes);
            }

            // Extract
            StatusMessage = "Installing rclone...";
            ZipFile.ExtractToDirectory(zipPath, tempDir, overwriteFiles: true);

            // Find rclone.exe in extracted contents (nested in a folder like rclone-v1.xx.x-windows-amd64/)
            var extractedExe = Directory.GetFiles(tempDir, "rclone.exe", SearchOption.AllDirectories).FirstOrDefault();
            if (extractedExe == null)
            {
                StatusMessage = "Install failed - rclone.exe not found in archive";
                return;
            }

            // Copy to install dir
            var dest = RcloneExePath;
            File.Copy(extractedExe, dest, overwrite: true);

            // Cleanup temp
            try { Directory.Delete(tempDir, true); } catch { }

            if (File.Exists(dest))
            {
                IsRcloneInstalled = true;
                RcloneVersion = await FetchVersion();
                LoadRemotes();
                StatusMessage = $"rclone {RcloneVersion ?? ""} installed";
            }
            else
            {
                StatusMessage = "Install failed - check your internet connection";
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Install failed: {ex.Message}";
        }
        finally
        {
            IsDownloadingRclone = false;
            _ = ClearStatusAfterDelay(5000);
        }
    }

    public async Task UpdateRclone() => await DownloadAndInstallRclone();

    public async Task UninstallRclone()
    {
        var path = EffectiveRclonePath;
        if (string.IsNullOrEmpty(path)) return;

        try { File.Delete(path); } catch { }

        StatusMessage = "rclone uninstalled";
        await Task.Delay(2000);
        await DetectRclone();
        StatusMessage = null;
    }

    // ── Remote Management ────────────────────────────────────────

    public void LoadRemotes()
    {
        if (!File.Exists(RcloneConfigPath))
        {
            Remotes = new ObservableCollection<Remote>();
            return;
        }

        try
        {
            var content = File.ReadAllText(RcloneConfigPath);
            var parsed = ParseConfig(content);

            // Apply saved ordering
            var order = AppSettings.Instance.RemoteOrder;
            if (order.Count > 0)
            {
                parsed.Sort((a, b) =>
                {
                    var ia = order.IndexOf(a.Name);
                    var ib = order.IndexOf(b.Name);
                    if (ia < 0) ia = int.MaxValue;
                    if (ib < 0) ib = int.MaxValue;
                    return ia.CompareTo(ib);
                });
            }

            Remotes = new ObservableCollection<Remote>(parsed);
        }
        catch
        {
            Remotes = new ObservableCollection<Remote>();
        }
    }

    public void MoveRemotes(int oldIndex, int newIndex)
    {
        if (oldIndex < 0 || oldIndex >= Remotes.Count || newIndex < 0 || newIndex >= Remotes.Count)
            return;

        Remotes.Move(oldIndex, newIndex);
        SaveRemoteOrder();
    }

    private void SaveRemoteOrder()
    {
        AppSettings.Instance.RemoteOrder = Remotes.Select(r => r.Name).ToList();
        AppSettings.Instance.Save();
    }

    /// <summary>
    /// Parse rclone.conf INI format into a list of Remote objects.
    /// </summary>
    private List<Remote> ParseConfig(string content)
    {
        var result = new List<Remote>();
        string? currentName = null;
        var currentConfig = new Dictionary<string, string>();
        var settings = AppSettings.Instance;

        foreach (var rawLine in content.Split('\n'))
        {
            var trimmed = rawLine.Trim();
            if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith('#') || trimmed.StartsWith(';'))
                continue;

            if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            {
                // Flush previous section
                if (currentName != null)
                {
                    result.Add(BuildRemote(currentName, currentConfig, settings));
                }

                currentName = trimmed[1..^1];
                currentConfig = new Dictionary<string, string>();
            }
            else
            {
                var eqIdx = trimmed.IndexOf('=');
                if (eqIdx > 0)
                {
                    var key = trimmed[..eqIdx].Trim();
                    var val = trimmed[(eqIdx + 1)..].Trim();
                    currentConfig[key] = val;
                }
            }
        }

        // Flush last section
        if (currentName != null)
        {
            result.Add(BuildRemote(currentName, currentConfig, settings));
        }

        return result;
    }

    private static Remote BuildRemote(string name, Dictionary<string, string> config, AppSettings settings)
    {
        settings.PerRemoteDriveLetters.TryGetValue(name, out var driveLetter);
        settings.PerRemoteAutoMount.TryGetValue(name, out var autoMount);
        settings.PerRemoteRemotePaths.TryGetValue(name, out var remotePath);

        return new Remote
        {
            Name = name,
            Type = config.GetValueOrDefault("type", "unknown"),
            Config = new Dictionary<string, string>(config),
            DriveLetter = driveLetter ?? string.Empty,
            RemotePath = remotePath ?? string.Empty,
            AutoMount = autoMount
        };
    }

    /// <summary>
    /// Rewrite a single remote's section in rclone.conf. Preserves all other remotes and comments.
    /// </summary>
    public bool WriteRemoteConfig(string name, Dictionary<string, string> config)
    {
        if (!File.Exists(RcloneConfigPath)) return false;

        try
        {
            var content = File.ReadAllText(RcloneConfigPath);
            var lines = content.Split('\n');
            var newLines = new List<string>();
            bool inTarget = false;
            bool replaced = false;

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
                {
                    if (inTarget)
                    {
                        inTarget = false;
                    }

                    var sectionName = trimmed[1..^1];
                    if (sectionName == name)
                    {
                        inTarget = true;
                        replaced = true;
                        newLines.Add($"[{name}]");
                        foreach (var kvp in config.OrderBy(k => k.Key))
                        {
                            newLines.Add($"{kvp.Key} = {kvp.Value}");
                        }
                        continue;
                    }
                }

                if (inTarget)
                {
                    // Skip old lines in the target section
                    if (string.IsNullOrEmpty(trimmed) || trimmed.Contains('=') ||
                        trimmed.StartsWith('#') || trimmed.StartsWith(';'))
                    {
                        continue;
                    }
                }

                newLines.Add(line);
            }

            // If section wasn't found, append it
            if (!replaced)
            {
                if (newLines.Count > 0 && !string.IsNullOrEmpty(newLines[^1]))
                    newLines.Add(string.Empty);

                newLines.Add($"[{name}]");
                foreach (var kvp in config.OrderBy(k => k.Key))
                {
                    newLines.Add($"{kvp.Key} = {kvp.Value}");
                }
            }

            var result = string.Join("\n", newLines);
            File.WriteAllText(RcloneConfigPath, result);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Create a remote via rclone config create.
    /// For OAuth types, rclone opens the browser automatically.
    /// </summary>
    public async Task<bool> CreateRemote(string name, string type, Dictionary<string, string> parameters)
    {
        var rclone = EffectiveRclonePath;
        if (string.IsNullOrEmpty(rclone)) return false;

        StatusMessage = "Creating remote...";

        var args = new List<string> { "config", "create", name, type };
        foreach (var kvp in parameters.Where(p => !string.IsNullOrEmpty(p.Value)))
        {
            args.Add($"{kvp.Key}={kvp.Value}");
        }

        var ok = await ProcessHelper.RunAsync(rclone, args);

        if (ok)
        {
            LoadRemotes();
            StatusMessage = $"{name} created";
        }
        else
        {
            StatusMessage = "Failed to create remote";
        }

        _ = ClearStatusAfterDelay(4000);
        return ok;
    }

    /// <summary>
    /// Delete a remote via rclone config delete and clean up all associated settings.
    /// </summary>
    public async Task DeleteRemote(Remote remote)
    {
        var name = remote.Name;

        // Remove from UI immediately
        var toRemove = Remotes.FirstOrDefault(r => r.Name == name);
        if (toRemove != null) Remotes.Remove(toRemove);

        lock (_lock) { _mountStatuses.Remove(name); _mountErrors.Remove(name); }
        OnPropertyChanged(nameof(MountStatuses));

        if (MountStatus(remote) == Models.MountStatus.Mounted)
        {
            await Unmount(remote);
        }

        var rclone = EffectiveRclonePath;
        if (!string.IsNullOrEmpty(rclone))
        {
            await ProcessHelper.RunAsync(rclone, new List<string> { "config", "delete", name });
        }

        // Clean settings
        var settings = AppSettings.Instance;
        settings.PerRemoteAutoMount.Remove(name);
        settings.PerRemoteDriveLetters.Remove(name);
        settings.PerRemoteRemotePaths.Remove(name);
        settings.Save();

        RemoteSettings.Delete(name);
        LoadRemotes();
    }

    /// <summary>
    /// Open full interactive rclone config in a new console window via a .cmd script.
    /// </summary>
    public void OpenAdvancedConfig(string? name = null, string? type = null)
    {
        var rclone = EffectiveRclonePath;
        if (string.IsNullOrEmpty(rclone)) return;

        string cmd;
        if (!string.IsNullOrEmpty(name) && !string.IsNullOrEmpty(type))
        {
            cmd = $"\"{rclone}\" config create \"{name}\" \"{type}\"";
        }
        else
        {
            cmd = $"\"{rclone}\" config";
        }

        var scriptPath = Path.Combine(Path.GetTempPath(), $"skyhook-config-{Guid.NewGuid()}.cmd");
        var content = $"@echo off\r\n{cmd}\r\necho.\r\necho Done. You can close this window.\r\npause\r\n";
        File.WriteAllText(scriptPath, content);

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = scriptPath,
                UseShellExecute = true,
                CreateNoWindow = false
            });
        }
        catch { }
    }

    // ── Mounting ─────────────────────────────────────────────────

    /// <summary>
    /// Mount a remote with retry logic (up to 3 attempts).
    /// </summary>
    public async Task Mount(Remote remote)
    {
        var name = remote.Name;
        lock (_lock)
        {
            if (_mountStatuses.GetValueOrDefault(name) is Models.MountStatus.Mounted or Models.MountStatus.Mounting)
                return;
            _mountStatuses[name] = Models.MountStatus.Mounting;
        }
        OnPropertyChanged(nameof(MountStatuses));

        var retryDelays = new[] { 2000, 5000, 10000 };
        const int maxAttempts = 3;

        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            await MountDirect(remote);

            if (MountStatus(remote) == Models.MountStatus.Mounted) return;

            // Check for definitive errors
            lock (_lock)
            {
                if (_mountStatuses.GetValueOrDefault(name) == Models.MountStatus.Error)
                {
                    var msg = _mountErrors.GetValueOrDefault(name, "");
                    var definitiveErrors = new[] { "no such remote", "invalid", "not found", "token has been revoked", "cancelled" };
                    if (definitiveErrors.Any(e => msg.Contains(e, StringComparison.OrdinalIgnoreCase)))
                        return;
                }
            }

            if (attempt < maxAttempts)
            {
                lock (_lock) { _mountStatuses[name] = Models.MountStatus.Mounting; }
                OnPropertyChanged(nameof(MountStatuses));
                await Task.Delay(retryDelays[attempt - 1]);
            }
        }
    }

    /// <summary>
    /// Start rclone mount process for a remote, mapping to a Windows drive letter.
    /// The rclone mount command on Windows blocks (foreground), so the Process is kept alive.
    /// </summary>
    private async Task MountDirect(Remote remote)
    {
        var name = remote.Name;
        var rclone = EffectiveRclonePath;
        if (string.IsNullOrEmpty(rclone))
        {
            SetMountError(name, "rclone not found");
            return;
        }

        var subpath = remote.RemotePath;
        var remotePath = $"{name}:{subpath}";

        // Determine drive letter
        var settings = AppSettings.Instance;
        string driveLetter;
        if (settings.PerRemoteDriveLetters.TryGetValue(name, out var saved) && !string.IsNullOrEmpty(saved))
        {
            driveLetter = saved;
        }
        else
        {
            driveLetter = FindAvailableDriveLetter();
            if (string.IsNullOrEmpty(driveLetter))
            {
                SetMountError(name, "No available drive letter");
                return;
            }
        }

        var rcPort = _nextRCPort++;
        var mountSettings = RemoteSettings.Load(name, remote.Type);

        // Build rclone mount arguments
        var args = new List<string>
        {
            "mount",
            remotePath,
            driveLetter,
            "--vfs-cache-mode", "writes",
            "--rc",
            "--rc-addr", $"127.0.0.1:{rcPort}",
            "--rc-no-auth"
        };
        args.AddRange(mountSettings.BuildFlags());

        // Start the rclone mount process (blocking/foreground — stays alive)
        var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = rclone,
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var arg in args)
            process.StartInfo.ArgumentList.Add(arg);

        // Tag the process so orphan cleanup can find it
        process.StartInfo.Environment["SKYHOOK"] = "1";

        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            SetMountError(name, $"Failed to start rclone: {ex.Message}");
            return;
        }

        // Drain stderr in background for error reporting
        var stderrTask = process.StandardError.ReadToEndAsync();

        // Store the process and drive letter
        lock (_lock)
        {
            _mountProcesses[name] = process;
            _mountDriveLetters[name] = driveLetter;
            _rcPorts[name] = rcPort;
        }

        // Wait for the drive to appear (poll DriveInfo)
        var driveAppeared = await WaitForDriveAsync(driveLetter, timeoutSeconds: 30);

        if (driveAppeared && !process.HasExited)
        {
            lock (_lock)
            {
                _mountStatuses[name] = Models.MountStatus.Mounted;
                _mountErrors.Remove(name);
            }
            OnPropertyChanged(nameof(MountStatuses));

            TransferMonitor.Instance.RegisterRC(name, rcPort);

            // Drain stdout in background to prevent buffer deadlock
            _ = process.StandardOutput.ReadToEndAsync();
        }
        else
        {
            // Mount failed
            string errorMsg = "Mount failed";
            if (process.HasExited)
            {
                var stderr = await stderrTask;
                var lastLine = stderr.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                errorMsg = lastLine ?? "rclone mount exited unexpectedly";
            }

            lock (_lock)
            {
                _mountProcesses.Remove(name);
                _mountDriveLetters.Remove(name);
                _rcPorts.Remove(name);
            }

            if (!process.HasExited)
            {
                try { process.Kill(); } catch { }
            }

            SetMountError(name, errorMsg);
        }
    }

    /// <summary>
    /// Unmount a remote by killing the rclone process and waiting for the drive to disappear.
    /// </summary>
    public async Task Unmount(Remote remote)
    {
        var name = remote.Name;
        MountStatus currentStatus;
        lock (_lock)
        {
            currentStatus = _mountStatuses.GetValueOrDefault(name, Models.MountStatus.Unmounted);
        }

        if (currentStatus != Models.MountStatus.Mounted && currentStatus != Models.MountStatus.Error)
            return;

        lock (_lock) { _mountStatuses[name] = Models.MountStatus.Unmounting; }
        OnPropertyChanged(nameof(MountStatuses));

        // Kill rclone process
        Process? process;
        string? driveLetter;
        lock (_lock)
        {
            _mountProcesses.TryGetValue(name, out process);
            _mountDriveLetters.TryGetValue(name, out driveLetter);
        }

        if (process != null)
        {
            try
            {
                if (!process.HasExited) process.Kill();
                await process.WaitForExitAsync();
            }
            catch { }
            process.Dispose();
        }

        // Unregister transfer monitor
        TransferMonitor.Instance.UnregisterRC(name);

        // Wait for drive letter to disappear
        if (!string.IsNullOrEmpty(driveLetter))
        {
            await WaitForDriveRemovalAsync(driveLetter, timeoutSeconds: 10);
        }

        lock (_lock)
        {
            _mountProcesses.Remove(name);
            _mountDriveLetters.Remove(name);
            _rcPorts.Remove(name);
            _consecutiveFailures.Remove(name);
            _mountStatuses[name] = Models.MountStatus.Unmounted;
            _mountErrors.Remove(name);
        }
        OnPropertyChanged(nameof(MountStatuses));
    }

    public async Task ToggleMount(Remote remote)
    {
        if (MountStatus(remote) == Models.MountStatus.Mounted)
            await Unmount(remote);
        else
            await Mount(remote);
    }

    public async Task UnmountAll()
    {
        foreach (var remote in Remotes.ToList())
        {
            if (MountStatus(remote) == Models.MountStatus.Mounted)
                await Unmount(remote);
        }
    }

    public async Task AutoMountRemotes()
    {
        foreach (var remote in Remotes.Where(r => r.AutoMount))
        {
            await Mount(remote);
        }
    }

    public MountStatus MountStatus(Remote remote)
    {
        lock (_lock)
        {
            return _mountStatuses.GetValueOrDefault(remote.Name, Models.MountStatus.Unmounted);
        }
    }

    public string? MountError(Remote remote)
    {
        lock (_lock)
        {
            return _mountErrors.GetValueOrDefault(remote.Name);
        }
    }

    /// <summary>
    /// Returns the drive letter this remote is currently mounted at (e.g. "Z:"), or the
    /// configured drive letter, or falls back to FindAvailableDriveLetter().
    /// </summary>
    public string ActualMountPath(Remote remote)
    {
        lock (_lock)
        {
            if (_mountDriveLetters.TryGetValue(remote.Name, out var letter))
                return letter;
        }

        var settings = AppSettings.Instance;
        if (settings.PerRemoteDriveLetters.TryGetValue(remote.Name, out var saved) && !string.IsNullOrEmpty(saved))
            return saved;

        return FindAvailableDriveLetter();
    }

    // ── Drive Letter Management ──────────────────────────────────

    /// <summary>
    /// Scan Z: down to D:, skip drives that are in use. Returns "Z:" style string, or empty if none available.
    /// </summary>
    public string FindAvailableDriveLetter()
    {
        var usedDrives = new HashSet<char>(
            DriveInfo.GetDrives().Select(d => d.Name[0]));

        // Also skip drives already assigned to other SkyHook mounts
        lock (_lock)
        {
            foreach (var dl in _mountDriveLetters.Values)
            {
                if (dl.Length > 0) usedDrives.Add(dl[0]);
            }
        }

        for (char c = 'Z'; c >= 'D'; c--)
        {
            if (!usedDrives.Contains(c))
                return $"{c}:";
        }

        return string.Empty;
    }

    // ── Auto-mount Preferences ───────────────────────────────────

    public void ToggleAutoMount(Remote remote)
    {
        var idx = Remotes.ToList().FindIndex(r => r.Name == remote.Name);
        if (idx < 0) return;

        Remotes[idx].AutoMount = !Remotes[idx].AutoMount;
        AppSettings.Instance.PerRemoteAutoMount[remote.Name] = Remotes[idx].AutoMount;
        AppSettings.Instance.Save();
    }

    public void SetRemotePath(Remote remote, string path)
    {
        var idx = Remotes.ToList().FindIndex(r => r.Name == remote.Name);
        if (idx < 0) return;

        Remotes[idx].RemotePath = path;
        AppSettings.Instance.PerRemoteRemotePaths[remote.Name] = path;
        AppSettings.Instance.Save();
    }

    public void SetDriveLetter(Remote remote, string driveLetter)
    {
        var idx = Remotes.ToList().FindIndex(r => r.Name == remote.Name);
        if (idx < 0) return;

        Remotes[idx].DriveLetter = driveLetter;
        AppSettings.Instance.PerRemoteDriveLetters[remote.Name] = driveLetter;
        AppSettings.Instance.Save();
    }

    // ── Per-Remote Settings ──────────────────────────────────────

    public RemoteSettings GetSettings(Remote remote) =>
        RemoteSettings.Load(remote.Name, remote.Type);

    public void SaveSettings(RemoteSettings settings, Remote remote) =>
        settings.Save(remote.Name);

    public void ResetSettings(Remote remote) =>
        RemoteSettings.Delete(remote.Name);

    // ── Health Monitor ───────────────────────────────────────────

    private void StartHealthMonitor()
    {
        _healthCts = new CancellationTokenSource();
        var token = _healthCts.Token;

        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try { await Task.Delay(10_000, token); }
                catch (TaskCanceledException) { break; }

                await PerformHealthChecks();
            }
        }, token);
    }

    private async Task PerformHealthChecks()
    {
        foreach (var remote in Remotes.ToList())
        {
            var name = remote.Name;
            MountStatus status;
            Process? process;

            lock (_lock)
            {
                status = _mountStatuses.GetValueOrDefault(name, Models.MountStatus.Unmounted);
                if (status != Models.MountStatus.Mounted) continue;
                _mountProcesses.TryGetValue(name, out process);
            }

            // Check if the rclone process is still alive
            bool processAlive = process != null && !process.HasExited;

            if (!processAlive)
            {
                await AttemptAutoRemount(remote);
                continue;
            }

            // Check if drive letter is still accessible
            string? driveLetter;
            lock (_lock) { _mountDriveLetters.TryGetValue(name, out driveLetter); }

            if (!string.IsNullOrEmpty(driveLetter))
            {
                var accessible = DriveInfo.GetDrives().Any(d =>
                    d.Name.StartsWith(driveLetter, StringComparison.OrdinalIgnoreCase));

                if (!accessible)
                {
                    lock (_lock)
                    {
                        var failures = _consecutiveFailures.GetValueOrDefault(name) + 1;
                        _consecutiveFailures[name] = failures;

                        if (failures >= 3)
                        {
                            if (_mountProcesses.TryGetValue(name, out var p))
                            {
                                try { if (!p.HasExited) p.Kill(); } catch { }
                                _mountProcesses.Remove(name);
                            }
                        }
                        else
                        {
                            continue;
                        }
                    }

                    await AttemptAutoRemount(remote);
                }
                else
                {
                    lock (_lock) { _consecutiveFailures[name] = 0; }
                }
            }
        }
    }

    private async Task AttemptAutoRemount(Remote remote)
    {
        var name = remote.Name;

        // Simple retry: up to 3 attempts
        int attempts;
        lock (_lock)
        {
            attempts = _consecutiveFailures.GetValueOrDefault(name);
            if (attempts >= 3)
            {
                _mountStatuses[name] = Models.MountStatus.Error;
                _mountErrors[name] = "Process crashed - manual remount required";
                OnPropertyChanged(nameof(MountStatuses));
                return;
            }
            _consecutiveFailures[name] = attempts + 1;
        }

        // Clean up dead mount
        lock (_lock)
        {
            _mountProcesses.Remove(name);
            _mountDriveLetters.Remove(name);
            _rcPorts.Remove(name);
        }

        TransferMonitor.Instance.UnregisterRC(name);

        lock (_lock) { _mountStatuses[name] = Models.MountStatus.Mounting; }
        OnPropertyChanged(nameof(MountStatuses));

        await MountDirect(remote);

        if (MountStatus(remote) == Models.MountStatus.Mounted)
        {
            lock (_lock)
            {
                _consecutiveFailures.Remove(name);
            }
        }
    }

    // ── Orphan Cleanup ───────────────────────────────────────────

    private async Task CleanupOrphans()
    {
        try
        {
            var rcloneProcesses = Process.GetProcessesByName("rclone");
            foreach (var proc in rcloneProcesses)
            {
                try
                {
                    // Check if this is a SkyHook-tagged process by inspecting command line
                    var cmdLine = await GetProcessCommandLine(proc.Id);
                    if (cmdLine.Contains("SKYHOOK") || cmdLine.Contains("--rc-addr 127.0.0.1:194"))
                    {
                        proc.Kill();
                        await proc.WaitForExitAsync();
                    }
                }
                catch { }
                finally
                {
                    proc.Dispose();
                }
            }
        }
        catch { }

        await Task.Delay(500);
    }

    private static async Task<string> GetProcessCommandLine(int pid)
    {
        try
        {
            // Use WMIC to get command line (works without admin for own-user processes)
            var output = await ProcessHelper.RunAndCapture("wmic", new List<string>
            {
                "process", "where", $"processid={pid}", "get", "commandline", "/format:list"
            });
            return output;
        }
        catch
        {
            return string.Empty;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────

    private void SetMountError(string name, string message)
    {
        lock (_lock)
        {
            _mountStatuses[name] = Models.MountStatus.Error;
            _mountErrors[name] = message;
        }
        OnPropertyChanged(nameof(MountStatuses));
    }

    /// <summary>
    /// Poll DriveInfo until the specified drive letter appears, or timeout.
    /// </summary>
    private static async Task<bool> WaitForDriveAsync(string driveLetter, int timeoutSeconds)
    {
        var prefix = driveLetter[..1]; // "Z" from "Z:"
        for (int i = 0; i < timeoutSeconds * 2; i++)
        {
            var drives = DriveInfo.GetDrives();
            if (drives.Any(d => d.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
                return true;
            await Task.Delay(500);
        }
        return false;
    }

    /// <summary>
    /// Poll DriveInfo until the specified drive letter disappears, or timeout.
    /// </summary>
    private static async Task WaitForDriveRemovalAsync(string driveLetter, int timeoutSeconds)
    {
        var prefix = driveLetter[..1];
        for (int i = 0; i < timeoutSeconds * 2; i++)
        {
            var drives = DriveInfo.GetDrives();
            if (!drives.Any(d => d.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
                return;
            await Task.Delay(500);
        }
    }

    private async Task ClearStatusAfterDelay(int delayMs)
    {
        await Task.Delay(delayMs);
        StatusMessage = null;
    }

    // ── Cleanup ──────────────────────────────────────────────────

    /// <summary>
    /// Graceful shutdown: stop health monitor, unmount all, kill all processes.
    /// </summary>
    public async Task Cleanup()
    {
        _healthCts?.Cancel();
        _healthCts = null;

        await UnmountAll();

        lock (_lock)
        {
            foreach (var kvp in _mountProcesses)
            {
                try { if (!kvp.Value.HasExited) kvp.Value.Kill(); } catch { }
                kvp.Value.Dispose();
            }
            _mountProcesses.Clear();
        }
    }
}
