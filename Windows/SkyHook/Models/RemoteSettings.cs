using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SkyHook.Models;

public class RemoteSettings
{
    [JsonPropertyName("vfsCacheMode")]
    public string VfsCacheMode { get; set; } = string.Empty;

    [JsonPropertyName("vfsCacheMaxAge")]
    public string VfsCacheMaxAge { get; set; } = string.Empty;

    [JsonPropertyName("vfsCacheMaxSize")]
    public string VfsCacheMaxSize { get; set; } = string.Empty;

    [JsonPropertyName("vfsReadChunkSize")]
    public string VfsReadChunkSize { get; set; } = string.Empty;

    [JsonPropertyName("vfsCachePollInterval")]
    public string VfsCachePollInterval { get; set; } = string.Empty;

    [JsonPropertyName("bufferSize")]
    public string BufferSize { get; set; } = string.Empty;

    [JsonPropertyName("transfers")]
    public string Transfers { get; set; } = string.Empty;

    [JsonPropertyName("dirCacheTime")]
    public string DirCacheTime { get; set; } = string.Empty;

    [JsonPropertyName("vfsReadAhead")]
    public string VfsReadAhead { get; set; } = string.Empty;

    [JsonPropertyName("extraFlags")]
    public string ExtraFlags { get; set; } = string.Empty;

    /// <summary>
    /// Provider-aware defaults matching macOS presets.
    /// </summary>
    public static RemoteSettings Defaults(string type)
    {
        return type switch
        {
            "sftp" or "ftp" => new RemoteSettings
            {
                VfsCacheMode = "minimal",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "4M",
                VfsCachePollInterval = "1m",
                BufferSize = "256k",
                Transfers = "4",
                DirCacheTime = "2m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            },
            "s3" or "b2" or "gcs" or "azureblob" or "swift" => new RemoteSettings
            {
                VfsCacheMode = "writes",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "4M",
                VfsCachePollInterval = "1m",
                BufferSize = "512k",
                Transfers = "16",
                DirCacheTime = "2m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            },
            "drive" or "gphotos" => new RemoteSettings
            {
                VfsCacheMode = "writes",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "32M",
                VfsCachePollInterval = "1m",
                BufferSize = "256k",
                Transfers = "8",
                DirCacheTime = "5m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            },
            "dropbox" => new RemoteSettings
            {
                VfsCacheMode = "writes",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "64M",
                VfsCachePollInterval = "1m",
                BufferSize = "256k",
                Transfers = "8",
                DirCacheTime = "3m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            },
            "onedrive" or "sharefile" => new RemoteSettings
            {
                VfsCacheMode = "writes",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "32M",
                VfsCachePollInterval = "1m",
                BufferSize = "256k",
                Transfers = "8",
                DirCacheTime = "3m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            },
            _ => new RemoteSettings
            {
                VfsCacheMode = "writes",
                VfsCacheMaxAge = "1h",
                VfsCacheMaxSize = "10G",
                VfsReadChunkSize = "32M",
                VfsCachePollInterval = "1m",
                BufferSize = "256k",
                Transfers = "8",
                DirCacheTime = "2m",
                VfsReadAhead = "32M",
                ExtraFlags = ""
            }
        };
    }

    /// <summary>
    /// Builds the rclone CLI flag list from current settings.
    /// </summary>
    public List<string> BuildFlags()
    {
        var flags = new List<string>();

        if (!string.IsNullOrEmpty(VfsCacheMode)) { flags.Add("--vfs-cache-mode"); flags.Add(VfsCacheMode); }
        if (!string.IsNullOrEmpty(VfsCacheMaxAge)) { flags.Add("--vfs-cache-max-age"); flags.Add(VfsCacheMaxAge); }
        if (!string.IsNullOrEmpty(VfsCacheMaxSize)) { flags.Add("--vfs-cache-max-size"); flags.Add(VfsCacheMaxSize); }
        if (!string.IsNullOrEmpty(VfsReadChunkSize)) { flags.Add("--vfs-read-chunk-size"); flags.Add(VfsReadChunkSize); }
        if (!string.IsNullOrEmpty(VfsCachePollInterval)) { flags.Add("--vfs-cache-poll-interval"); flags.Add(VfsCachePollInterval); }
        if (!string.IsNullOrEmpty(BufferSize)) { flags.Add("--buffer-size"); flags.Add(BufferSize); }
        if (!string.IsNullOrEmpty(Transfers)) { flags.Add("--transfers"); flags.Add(Transfers); }
        if (!string.IsNullOrEmpty(DirCacheTime)) { flags.Add("--dir-cache-time"); flags.Add(DirCacheTime); }
        if (!string.IsNullOrEmpty(VfsReadAhead)) { flags.Add("--vfs-read-ahead"); flags.Add(VfsReadAhead); }

        flags.Add("--vfs-fast-fingerprint");

        if (!string.IsNullOrEmpty(ExtraFlags))
        {
            flags.AddRange(ExtraFlags.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        }

        return flags;
    }

    // ── Persistence ──────────────────────────────────────────────

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static string SettingsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SkyHook", "settings");

    private static string PathFor(string remoteName) =>
        Path.Combine(SettingsDir, $"{remoteName}.json");

    /// <summary>
    /// Load persisted settings for a remote, falling back to provider-aware defaults.
    /// </summary>
    public static RemoteSettings Load(string remoteName, string type)
    {
        var path = PathFor(remoteName);
        if (!File.Exists(path))
            return Defaults(type);

        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<RemoteSettings>(json, JsonOptions) ?? Defaults(type);
        }
        catch
        {
            return Defaults(type);
        }
    }

    /// <summary>
    /// Persist settings to %APPDATA%\SkyHook\settings\{remoteName}.json.
    /// </summary>
    public void Save(string remoteName)
    {
        var dir = SettingsDir;
        Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(this, JsonOptions);
        File.WriteAllText(PathFor(remoteName), json);
    }

    /// <summary>
    /// Delete persisted settings for a remote.
    /// </summary>
    public static void Delete(string remoteName)
    {
        var path = PathFor(remoteName);
        if (File.Exists(path))
            File.Delete(path);
    }
}
