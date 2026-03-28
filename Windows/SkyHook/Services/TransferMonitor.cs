using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;

namespace SkyHook.Services;

/// <summary>
/// Polls rclone's RC API for live transfer stats.
/// Ported from macOS TransferMonitor.swift.
/// Singleton with ObservableObject. Uses DispatcherTimer for periodic polling.
/// </summary>
public partial class TransferMonitor : ObservableObject
{
    private static readonly Lazy<TransferMonitor> _lazy = new(() => new TransferMonitor());
    public static TransferMonitor Instance => _lazy.Value;

    // ── Observable Properties ────────────────────────────────────

    [ObservableProperty]
    private ObservableCollection<TransferInfo> _transfers = new();

    [ObservableProperty]
    private GlobalStats _combinedStats = new();

    // ── Private State ────────────────────────────────────────────

    private readonly Dictionary<string, int> _rcPorts = new(); // remote name -> RC port
    private DispatcherTimer? _pollTimer;
    private bool _isPolling;
    private int _emptyPollCount; // consecutive polls with no active transfers
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(2) };

    private TransferMonitor() { }

    // ── Public API ───────────────────────────────────────────────

    public void RegisterRC(string remoteName, int port)
    {
        _rcPorts[remoteName] = port;
        StartPolling();
    }

    public void UnregisterRC(string remoteName)
    {
        _rcPorts.Remove(remoteName);

        // Immediately remove transfers for this remote so UI doesn't show stale data
        var remaining = Transfers.Where(t => t.RemoteName != remoteName).ToList();
        Transfers = new ObservableCollection<TransferInfo>(remaining);

        if (_rcPorts.Count == 0)
        {
            StopPolling();
            Transfers = new ObservableCollection<TransferInfo>();
            CombinedStats = new GlobalStats();
        }
    }

    public void UnregisterAll()
    {
        _rcPorts.Clear();
        StopPolling();
        Transfers = new ObservableCollection<TransferInfo>();
        CombinedStats = new GlobalStats();
    }

    // ── Polling ──────────────────────────────────────────────────

    private void StartPolling()
    {
        if (_pollTimer != null) return;

        _pollTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(3)
        };
        _pollTimer.Tick += async (_, _) => await Poll();
        _pollTimer.Start();
    }

    private void StopPolling()
    {
        _pollTimer?.Stop();
        _pollTimer = null;
    }

    private async Task Poll()
    {
        if (_isPolling) return;
        _isPolling = true;

        try
        {
            var allTransfers = new List<TransferInfo>();
            var combined = new GlobalStats();

            foreach (var (remoteName, port) in _rcPorts.ToList())
            {
                var stats = await FetchStats(port);
                if (stats == null) continue;

                combined.BytesTransferred += stats.BytesTransferred;
                combined.TotalBytes += stats.TotalBytes;
                combined.TotalTransfers += stats.TotalTransfers;
                combined.CompletedTransfers += stats.CompletedTransfers;
                combined.Speed += stats.Speed;
                // rclone accumulates harmless errors (e.g. Explorer probing thumbs.db) - ignore
                combined.Errors += 0;
                combined.ActiveTransfers += stats.ActiveTransfers;

                foreach (var t in stats.Transferring)
                {
                    allTransfers.Add(new TransferInfo
                    {
                        RemoteName = remoteName,
                        Name = t.Name,
                        Size = t.Size,
                        Bytes = t.Bytes,
                        Speed = t.Speed,
                        Percentage = t.Percentage
                    });
                }
            }

            // Avoid flickering: only clear the transfer list after 3 consecutive
            // empty polls (~9s), since rclone momentarily reports no active transfers
            // between chunks.
            if (allTransfers.Count == 0 && Transfers.Count > 0)
            {
                _emptyPollCount++;
                if (_emptyPollCount < 3) return;
            }
            else
            {
                _emptyPollCount = 0;
            }

            Transfers = new ObservableCollection<TransferInfo>(allTransfers);
            CombinedStats = combined;
        }
        finally
        {
            _isPolling = false;
        }
    }

    // ── RC Stats Fetch ───────────────────────────────────────────

    private async Task<RCStats?> FetchStats(int port)
    {
        try
        {
            var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/core/stats");
            var response = await _httpClient.SendAsync(request);
            var json = await response.Content.ReadAsStringAsync();

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            var stats = new RCStats
            {
                BytesTransferred = root.TryGetProperty("bytes", out var bytes) ? bytes.GetInt64() : 0,
                TotalBytes = root.TryGetProperty("totalBytes", out var totalBytes) ? totalBytes.GetInt64() : 0,
                TotalTransfers = root.TryGetProperty("totalTransfers", out var totalTransfers) ? totalTransfers.GetInt32() : 0,
                CompletedTransfers = root.TryGetProperty("transfers", out var transfers) ? transfers.GetInt32() : 0,
                Speed = root.TryGetProperty("speed", out var speed) ? speed.GetDouble() : 0,
                Errors = 0
            };

            if (root.TryGetProperty("transferring", out var transferring) &&
                transferring.ValueKind == JsonValueKind.Array)
            {
                stats.ActiveTransfers = transferring.GetArrayLength();
                foreach (var t in transferring.EnumerateArray())
                {
                    stats.Transferring.Add(new RCTransfer
                    {
                        Name = t.TryGetProperty("name", out var n) ? n.GetString() ?? "unknown" : "unknown",
                        Size = t.TryGetProperty("size", out var s) ? s.GetInt64() : 0,
                        Bytes = t.TryGetProperty("bytes", out var b) ? b.GetInt64() : 0,
                        Speed = t.TryGetProperty("speed", out var sp) ? sp.GetDouble() :
                                t.TryGetProperty("speedAvg", out var sa) ? sa.GetDouble() : 0,
                        Percentage = t.TryGetProperty("percentage", out var p) ? p.GetInt32() : 0
                    });
                }
            }

            return stats;
        }
        catch
        {
            return null;
        }
    }

    // ── Internal Models ──────────────────────────────────────────

    private class RCStats
    {
        public long BytesTransferred { get; set; }
        public long TotalBytes { get; set; }
        public int TotalTransfers { get; set; }
        public int CompletedTransfers { get; set; }
        public double Speed { get; set; }
        public int Errors { get; set; }
        public int ActiveTransfers { get; set; }
        public List<RCTransfer> Transferring { get; set; } = new();
    }

    private class RCTransfer
    {
        public string Name { get; set; } = string.Empty;
        public long Size { get; set; }
        public long Bytes { get; set; }
        public double Speed { get; set; }
        public int Percentage { get; set; }
    }
}

// ── Public Data Classes ──────────────────────────────────────

/// <summary>
/// Represents a single active file transfer.
/// </summary>
public class TransferInfo
{
    public string RemoteName { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public long Size { get; set; }
    public long Bytes { get; set; }
    public double Speed { get; set; }
    public int Percentage { get; set; }

    public string Id => $"{Name}{RemoteName}";

    public double Progress => Size > 0 ? (double)Bytes / Size : 0;

    public string SpeedFormatted => FormatBytes((long)Speed) + "/s";

    public string SizeFormatted => FormatBytes(Size);

    public string BytesFormatted => FormatBytes(Bytes);

    private static string FormatBytes(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        int unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }
        if (unitIndex == 0) return $"{bytes} B";
        return $"{value:F1} {units[unitIndex]}";
    }
}

/// <summary>
/// Aggregated stats across all mounted remotes.
/// </summary>
public partial class GlobalStats : ObservableObject
{
    [ObservableProperty]
    private long _bytesTransferred;

    [ObservableProperty]
    private long _totalBytes;

    [ObservableProperty]
    private int _totalTransfers;

    [ObservableProperty]
    private int _completedTransfers;

    [ObservableProperty]
    private double _speed;

    [ObservableProperty]
    private int _errors;

    [ObservableProperty]
    private int _activeTransfers;

    public double Progress => TotalBytes > 0 ? (double)BytesTransferred / TotalBytes : 0;

    public string SpeedFormatted => FormatBytes((long)Speed) + "/s";

    public string ProgressFormatted => $"{FormatBytes(BytesTransferred)} / {FormatBytes(TotalBytes)}";

    private static string FormatBytes(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        int unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }
        if (unitIndex == 0) return $"{bytes} B";
        return $"{value:F1} {units[unitIndex]}";
    }
}
