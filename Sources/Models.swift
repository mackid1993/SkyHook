import SwiftUI

// MARK: - Remote

struct Remote: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var type: String
    var config: [String: String] = [:]
    var mountPoint: String = ""
    var remotePath: String = ""
    var autoMount: Bool = false

    var displayType: String {
        RemoteType.displayName(for: type)
    }

    var typeIcon: String {
        RemoteType.icon(for: type)
    }
}

// MARK: - Mount Status

enum MountStatus: Equatable {
    case unmounted
    case mounting
    case mounted
    case unmounting
    case error(String)

    var label: String {
        switch self {
        case .unmounted: return "Ready"
        case .mounting: return "Mounting..."
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting..."
        case .error(let msg): return msg
        }
    }

    var color: Color {
        switch self {
        case .mounted: return .green
        case .mounting, .unmounting: return .orange
        case .error: return .red
        case .unmounted: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .mounted: return "circle.fill"
        case .mounting, .unmounting: return "circle.dotted"
        case .error: return "exclamationmark.circle.fill"
        case .unmounted: return "circle"
        }
    }
}

// MARK: - Remote Type Info

enum RemoteType {
    struct Template: Identifiable {
        var id: String { type }
        let type: String
        let name: String
        let icon: String
        let fields: [Field]
        let needsOAuth: Bool

        init(type: String, name: String, icon: String, fields: [Field], needsOAuth: Bool = false) {
            self.type = type
            self.name = name
            self.icon = icon
            self.fields = fields
            self.needsOAuth = needsOAuth
        }
    }

    struct Field: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        var placeholder: String = ""
        var isSecure: Bool = false
        var isRequired: Bool = false
    }

    static func displayName(for type: String) -> String {
        if let cached = _runtimeBackends[type] {
            return cached
        }
        return type.capitalized
    }

    static func icon(for type: String) -> String {
        iconMap[type] ?? "cloud"
    }

    // Icon mapping for known types
    private static let iconMap: [String: String] = [
        "s3": "cloud.fill", "drive": "externaldrive.fill.badge.icloud",
        "dropbox": "drop.fill", "onedrive": "icloud.fill",
        "sftp": "lock.shield.fill", "webdav": "globe",
        "b2": "cloud.fill", "ftp": "network", "local": "folder.fill",
        "azureblob": "cloud.fill", "azurefiles": "cloud.fill",
        "gcs": "cloud.fill", "mega": "m.circle.fill",
        "box": "shippingbox.fill", "smb": "externaldrive.fill.badge.wifi",
        "pcloud": "cloud.fill", "swift": "cloud.fill",
        "hdfs": "externaldrive.fill", "crypt": "lock.fill",
        "http": "globe", "sia": "circle.hexagongrid.fill",
        "storj": "circle.hexagongrid.fill", "seafile": "drop.fill",
        "jottacloud": "cloud.fill", "yandex": "cloud.fill",
        "mailru": "envelope.fill", "koofr": "cloud.fill",
        "sharefile": "doc.fill", "putio": "play.circle.fill",
        "premiumizeme": "star.fill", "pikpak": "cloud.fill",
        "gphotos": "photo.fill", "hidrive": "externaldrive.fill",
        "zoho": "cloud.fill", "sugarsync": "arrow.triangle.2.circlepath",
        "fichier": "doc.fill", "opendrive": "externaldrive.fill",
        "iclouddrive": "icloud.fill", "internetarchive": "building.columns.fill",
        "protondrive": "lock.shield.fill", "cache": "internaldrive.fill",
        "compress": "archivebox.fill", "chunker": "square.split.2x2.fill",
        "combine": "rectangle.stack.fill", "union": "rectangle.stack.fill",
        "alias": "link", "memory": "memorychip.fill",
        "netstorage": "network", "archive": "archivebox.fill",
    ]

    /// Backends that need OAuth browser flow
    static let oauthTypes: Set<String> = [
        "drive", "dropbox", "onedrive", "box", "pcloud", "yandex",
        "jottacloud", "sharefile", "zoho", "hidrive", "gphotos",
        "putio", "premiumizeme", "pikpak", "mailru", "sugarsync",
        "protondrive", "iclouddrive",
    ]

    /// Populated at runtime by querying `rclone help backends`
    nonisolated(unsafe) static var _runtimeBackends: [String: String] = [:]

    /// Query rclone for ALL supported backends
    static func loadBackends(rclonePath: String) {
        guard !rclonePath.isEmpty else { return }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: rclonePath)
        proc.arguments = ["help", "backends"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            var backends: [String: String] = [:]
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Lines look like: "  s3           Amazon S3 Compliant..."
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    let desc = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    // Skip header/meta lines
                    if !key.isEmpty && key != "All" && key != "To" && !key.contains(":") {
                        backends[key] = desc
                    }
                }
            }

            _runtimeBackends = backends
        } catch {}
    }

    /// Returns all known backend types sorted by name
    static var allBackendTypes: [(type: String, name: String)] {
        if _runtimeBackends.isEmpty {
            // Fallback if rclone hasn't been queried yet
            return fallbackBackends
        }
        return _runtimeBackends
            .map { (type: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let fallbackBackends: [(type: String, name: String)] = [
        ("s3", "Amazon S3"), ("azureblob", "Azure Blob Storage"),
        ("azurefiles", "Azure Files"), ("b2", "Backblaze B2"),
        ("box", "Box"), ("cache", "Cache"), ("crypt", "Crypt (Encrypt/Decrypt)"),
        ("drive", "Google Drive"), ("dropbox", "Dropbox"),
        ("fichier", "1Fichier"), ("ftp", "FTP"),
        ("gcs", "Google Cloud Storage"), ("gphotos", "Google Photos"),
        ("hdfs", "Hadoop HDFS"), ("hidrive", "HiDrive"),
        ("http", "HTTP"), ("iclouddrive", "iCloud Drive"),
        ("internetarchive", "Internet Archive"),
        ("jottacloud", "Jottacloud"), ("koofr", "Koofr"),
        ("local", "Local Disk"), ("mailru", "Mail.ru Cloud"),
        ("mega", "MEGA"), ("memory", "In Memory"),
        ("netstorage", "Akamai NetStorage"),
        ("onedrive", "Microsoft OneDrive"), ("opendrive", "OpenDrive"),
        ("pcloud", "pCloud"), ("pikpak", "PikPak"),
        ("premiumizeme", "Premiumize.me"),
        ("protondrive", "Proton Drive"), ("putio", "Put.io"),
        ("seafile", "Seafile"), ("sftp", "SFTP"),
        ("sharefile", "Citrix ShareFile"), ("sia", "Sia"),
        ("smb", "SMB / CIFS"), ("storj", "Storj"),
        ("sugarsync", "SugarSync"), ("swift", "OpenStack Swift"),
        ("webdav", "WebDAV"), ("yandex", "Yandex Disk"),
        ("zoho", "Zoho WorkDrive"),
    ]
}
