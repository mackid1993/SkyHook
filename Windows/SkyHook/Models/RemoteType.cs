using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows.Media;

namespace SkyHook.Models;

/// <summary>
/// Static helper for remote backend type metadata: icons, display names, OAuth info, and rclone backend discovery.
/// </summary>
public static class RemoteType
{
    // ── OAuth types ──────────────────────────────────────────────

    public static readonly HashSet<string> OAuthTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "drive", "dropbox", "onedrive", "box", "pcloud", "yandex",
        "jottacloud", "sharefile", "zoho", "hidrive", "gphotos",
        "putio", "premiumizeme", "pikpak", "mailru", "sugarsync",
        "protondrive", "iclouddrive"
    };

    // ── Icon mapping (Segoe Fluent Icons characters) ─────────────

    private static readonly Dictionary<string, string> IconMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["s3"]              = "\uE753",   // Cloud
        ["drive"]           = "\uEDA2",   // CloudSearch / Drive
        ["dropbox"]         = "\uE7C4",   // Drop
        ["onedrive"]        = "\uE753",   // Cloud
        ["sftp"]            = "\uE72E",   // Lock
        ["webdav"]          = "\uE774",   // Globe
        ["b2"]              = "\uE753",   // Cloud
        ["ftp"]             = "\uE968",   // Network
        ["local"]           = "\uE8B7",   // Folder
        ["azureblob"]       = "\uE753",   // Cloud
        ["azurefiles"]      = "\uE753",   // Cloud
        ["gcs"]             = "\uE753",   // Cloud
        ["mega"]            = "\uE904",   // M circle
        ["box"]             = "\uE7B8",   // Package / box
        ["smb"]             = "\uE8CE",   // Network drive
        ["pcloud"]          = "\uE753",   // Cloud
        ["swift"]           = "\uE753",   // Cloud
        ["hdfs"]            = "\uEDA2",   // External drive
        ["crypt"]           = "\uE72E",   // Lock
        ["http"]            = "\uE774",   // Globe
        ["sia"]             = "\uE7B8",   // Hexagon grid
        ["storj"]           = "\uE7B8",   // Hexagon grid
        ["seafile"]         = "\uE7C4",   // Drop
        ["jottacloud"]      = "\uE753",   // Cloud
        ["yandex"]          = "\uE753",   // Cloud
        ["mailru"]          = "\uE715",   // Mail
        ["koofr"]           = "\uE753",   // Cloud
        ["sharefile"]       = "\uE8A5",   // Document
        ["putio"]           = "\uE768",   // Play
        ["premiumizeme"]    = "\uE735",   // Star
        ["pikpak"]          = "\uE753",   // Cloud
        ["gphotos"]         = "\uE722",   // Photo
        ["hidrive"]         = "\uEDA2",   // External drive
        ["zoho"]            = "\uE753",   // Cloud
        ["sugarsync"]       = "\uE895",   // Sync
        ["fichier"]         = "\uE8A5",   // Document
        ["opendrive"]       = "\uEDA2",   // External drive
        ["iclouddrive"]     = "\uE753",   // Cloud
        ["internetarchive"] = "\uE8F1",   // Library
        ["protondrive"]     = "\uE72E",   // Lock/shield
        ["cache"]           = "\uEDA2",   // Internal drive
        ["compress"]        = "\uE7B8",   // Archive
        ["chunker"]         = "\uE8A9",   // Grid
        ["combine"]         = "\uE8F1",   // Stack
        ["union"]           = "\uE8F1",   // Stack
        ["alias"]           = "\uE71B",   // Link
        ["memory"]          = "\uE964",   // Memory chip
        ["netstorage"]      = "\uE968",   // Network
        ["archive"]         = "\uE7B8",   // Archive
    };

    // ── Public helpers ───────────────────────────────────────────

    /// <summary>
    /// Returns a Segoe Fluent Icons character for the given provider type.
    /// Falls back to a generic cloud icon.
    /// </summary>
    public static string Icon(string type)
    {
        return IconMap.TryGetValue(type, out var icon) ? icon : "\uE753";
    }

    /// <summary>
    /// Returns a human-readable display name for the provider type.
    /// Uses runtime-discovered backends when available, otherwise falls back to capitalized type name.
    /// </summary>
    public static string DisplayName(string type)
    {
        if (RuntimeBackends.TryGetValue(type, out var name))
            return name;

        return string.IsNullOrEmpty(type)
            ? string.Empty
            : char.ToUpper(type[0]) + type[1..];
    }

    // ── Runtime backend discovery ────────────────────────────────

    /// <summary>
    /// Populated at runtime by <see cref="LoadBackends"/>.
    /// Maps backend type string to its human-readable description.
    /// </summary>
    public static Dictionary<string, string> RuntimeBackends { get; private set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Queries rclone for all supported backends and populates <see cref="RuntimeBackends"/>.
    /// </summary>
    public static void LoadBackends(string rclonePath)
    {
        if (string.IsNullOrEmpty(rclonePath))
            return;

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = rclonePath,
                Arguments = "help backends",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc == null) return;

            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit();

            var backends = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            foreach (var line in output.Split('\n'))
            {
                var trimmed = line.Trim();
                if (string.IsNullOrEmpty(trimmed)) continue;

                // Lines look like: "  s3           Amazon S3 Compliant..."
                var parts = trimmed.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length != 2) continue;

                var key = parts[0];
                var desc = parts[1].Trim();

                // Skip header/meta lines
                if (key is "All" or "To" || key.Contains(':'))
                    continue;

                backends[key] = desc;
            }

            RuntimeBackends = backends;
        }
        catch
        {
            // Silently fall back to hardcoded list
        }
    }

    /// <summary>
    /// Returns all known backend types sorted by display name.
    /// Uses runtime-discovered backends if available, otherwise the fallback list.
    /// </summary>
    public static List<(string Type, string Name)> AllBackendTypes
    {
        get
        {
            if (RuntimeBackends.Count == 0)
                return FallbackBackends;

            return RuntimeBackends
                .Select(kvp => (Type: kvp.Key, Name: kvp.Value))
                .OrderBy(b => b.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }

    /// <summary>
    /// Hardcoded fallback list of 40+ known rclone providers.
    /// </summary>
    public static readonly List<(string Type, string Name)> FallbackBackends = new()
    {
        ("s3",              "Amazon S3"),
        ("azureblob",       "Azure Blob Storage"),
        ("azurefiles",      "Azure Files"),
        ("b2",              "Backblaze B2"),
        ("box",             "Box"),
        ("cache",           "Cache"),
        ("crypt",           "Crypt (Encrypt/Decrypt)"),
        ("drive",           "Google Drive"),
        ("dropbox",         "Dropbox"),
        ("fichier",         "1Fichier"),
        ("ftp",             "FTP"),
        ("gcs",             "Google Cloud Storage"),
        ("gphotos",         "Google Photos"),
        ("hdfs",            "Hadoop HDFS"),
        ("hidrive",         "HiDrive"),
        ("http",            "HTTP"),
        ("iclouddrive",     "iCloud Drive"),
        ("internetarchive", "Internet Archive"),
        ("jottacloud",      "Jottacloud"),
        ("koofr",           "Koofr"),
        ("local",           "Local Disk"),
        ("mailru",          "Mail.ru Cloud"),
        ("mega",            "MEGA"),
        ("memory",          "In Memory"),
        ("netstorage",      "Akamai NetStorage"),
        ("onedrive",        "Microsoft OneDrive"),
        ("opendrive",       "OpenDrive"),
        ("pcloud",          "pCloud"),
        ("pikpak",          "PikPak"),
        ("premiumizeme",    "Premiumize.me"),
        ("protondrive",     "Proton Drive"),
        ("putio",           "Put.io"),
        ("seafile",         "Seafile"),
        ("sftp",            "SFTP"),
        ("sharefile",       "Citrix ShareFile"),
        ("sia",             "Sia"),
        ("smb",             "SMB / CIFS"),
        ("storj",           "Storj"),
        ("sugarsync",       "SugarSync"),
        ("swift",           "OpenStack Swift"),
        ("webdav",          "WebDAV"),
        ("yandex",          "Yandex Disk"),
        ("zoho",            "Zoho WorkDrive"),
    };

    // ── Gradient colors for icon backgrounds ─────────────────────

    /// <summary>
    /// Returns two gradient colors for the given provider type, suitable for WPF icon backgrounds.
    /// </summary>
    public static (Color Start, Color End) GradientColors(string type)
    {
        return type.ToLowerInvariant() switch
        {
            "s3"              => (Color.FromRgb(0xFF, 0x99, 0x00), Color.FromRgb(0xE6, 0x7E, 0x00)), // AWS orange
            "drive"           => (Color.FromRgb(0x43, 0x85, 0xF4), Color.FromRgb(0x0F, 0x9D, 0x58)), // Google blue-green
            "gphotos"         => (Color.FromRgb(0x43, 0x85, 0xF4), Color.FromRgb(0xFB, 0xBC, 0x05)), // Google blue-yellow
            "dropbox"         => (Color.FromRgb(0x00, 0x61, 0xFF), Color.FromRgb(0x00, 0x4C, 0xD9)), // Dropbox blue
            "onedrive"        => (Color.FromRgb(0x00, 0x78, 0xD4), Color.FromRgb(0x00, 0x5A, 0x9E)), // Microsoft blue
            "box"             => (Color.FromRgb(0x00, 0x61, 0xD5), Color.FromRgb(0x00, 0x4C, 0xAB)), // Box blue
            "sftp"            => (Color.FromRgb(0x4A, 0x90, 0xD9), Color.FromRgb(0x35, 0x6C, 0xB0)), // Steel blue
            "ftp"             => (Color.FromRgb(0x4A, 0x90, 0xD9), Color.FromRgb(0x35, 0x6C, 0xB0)), // Steel blue
            "webdav"          => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Gray
            "b2"              => (Color.FromRgb(0xE3, 0x35, 0x2B), Color.FromRgb(0xC0, 0x2B, 0x23)), // Backblaze red
            "gcs"             => (Color.FromRgb(0x43, 0x85, 0xF4), Color.FromRgb(0x34, 0xA8, 0x53)), // Google blue-green
            "azureblob"       => (Color.FromRgb(0x00, 0x89, 0xD6), Color.FromRgb(0x00, 0x6C, 0xBE)), // Azure blue
            "azurefiles"      => (Color.FromRgb(0x00, 0x89, 0xD6), Color.FromRgb(0x00, 0x6C, 0xBE)), // Azure blue
            "mega"            => (Color.FromRgb(0xD9, 0x27, 0x2E), Color.FromRgb(0xB5, 0x1F, 0x26)), // MEGA red
            "pcloud"          => (Color.FromRgb(0x20, 0xBE, 0xC6), Color.FromRgb(0x18, 0x9B, 0xA3)), // pCloud teal
            "swift"           => (Color.FromRgb(0xE3, 0x35, 0x2B), Color.FromRgb(0xC0, 0x2B, 0x23)), // OpenStack red
            "smb"             => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Gray
            "local"           => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Gray
            "crypt"           => (Color.FromRgb(0x6B, 0x4F, 0xBB), Color.FromRgb(0x55, 0x3C, 0x9A)), // Purple
            "protondrive"     => (Color.FromRgb(0x6B, 0x4F, 0xBB), Color.FromRgb(0x55, 0x3C, 0x9A)), // Proton purple
            "storj"           => (Color.FromRgb(0x27, 0x83, 0xE2), Color.FromRgb(0x1E, 0x6B, 0xC2)), // Storj blue
            "sia"             => (Color.FromRgb(0x1E, 0xD5, 0xAE), Color.FromRgb(0x18, 0xB5, 0x93)), // Sia green
            "seafile"         => (Color.FromRgb(0xF5, 0x82, 0x20), Color.FromRgb(0xD4, 0x6F, 0x1A)), // Seafile orange
            "yandex"          => (Color.FromRgb(0xFF, 0xCC, 0x00), Color.FromRgb(0xE6, 0xB8, 0x00)), // Yandex yellow
            "mailru"          => (Color.FromRgb(0x00, 0x5F, 0xF9), Color.FromRgb(0x00, 0x4C, 0xD6)), // Mail.ru blue
            "jottacloud"      => (Color.FromRgb(0x23, 0xC2, 0x5B), Color.FromRgb(0x1C, 0xA1, 0x4B)), // Jotta green
            "zoho"            => (Color.FromRgb(0xE4, 0x2B, 0x2F), Color.FromRgb(0xC4, 0x24, 0x28)), // Zoho red
            "hidrive"         => (Color.FromRgb(0x00, 0x4E, 0x98), Color.FromRgb(0x00, 0x3D, 0x7A)), // HiDrive blue
            "sharefile"       => (Color.FromRgb(0x00, 0xA1, 0xDE), Color.FromRgb(0x00, 0x84, 0xBB)), // Citrix blue
            "koofr"           => (Color.FromRgb(0x27, 0xAE, 0x60), Color.FromRgb(0x1E, 0x8B, 0x4D)), // Koofr green
            "sugarsync"       => (Color.FromRgb(0x45, 0xB0, 0x58), Color.FromRgb(0x38, 0x90, 0x47)), // SugarSync green
            "putio"           => (Color.FromRgb(0xE8, 0x4C, 0x3D), Color.FromRgb(0xC7, 0x3E, 0x32)), // Put.io red
            "premiumizeme"    => (Color.FromRgb(0xF5, 0xA6, 0x23), Color.FromRgb(0xD4, 0x8E, 0x1C)), // Gold
            "pikpak"          => (Color.FromRgb(0x30, 0x6E, 0xE6), Color.FromRgb(0x27, 0x5A, 0xC2)), // PikPak blue
            "fichier"         => (Color.FromRgb(0x17, 0x17, 0x17), Color.FromRgb(0x33, 0x33, 0x33)), // 1Fichier dark
            "opendrive"       => (Color.FromRgb(0xCE, 0x35, 0x1F), Color.FromRgb(0xAD, 0x2C, 0x19)), // OpenDrive red
            "iclouddrive"     => (Color.FromRgb(0x33, 0x9D, 0xF0), Color.FromRgb(0x28, 0x7F, 0xCB)), // iCloud blue
            "internetarchive" => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Gray
            "http"            => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Gray
            "hdfs"            => (Color.FromRgb(0xFF, 0xDE, 0x57), Color.FromRgb(0xE6, 0xC8, 0x4D)), // Hadoop yellow
            "netstorage"      => (Color.FromRgb(0x00, 0x96, 0xD6), Color.FromRgb(0x00, 0x7A, 0xB5)), // Akamai blue
            _                 => (Color.FromRgb(0x6C, 0x75, 0x7D), Color.FromRgb(0x49, 0x50, 0x57)), // Default gray
        };
    }
}
