import Foundation

/// Represents a file/folder returned by `rclone lsjson`.
struct RcloneFile {
    let name: String
    let size: Int64
    let mimeType: String?
    let modTime: Date?
    let isDir: Bool
}

/// Bridges rclone CLI commands for use by the File Provider extension.
/// All operations are synchronous (run on background queues by callers).
enum RcloneHelper {

    // MARK: - Find rclone

    static func findRclone() -> String {
        // Check user defaults first (set by main app)
        if let saved = UserDefaults(suiteName: "com.skyhook.app")?.string(forKey: "rclonePath"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }

        let path = "\(NSHomeDirectory())/.local/bin/rclone"
        return FileManager.default.fileExists(atPath: path) ? path : ""
    }

    // MARK: - List Files

    static func lsjson(rclonePath: String, remote: String, path: String, recursive: Bool = false) -> [RcloneFile] {
        let remotePath = path.isEmpty ? "\(remote):" : "\(remote):\(path)"
        var args = ["lsjson", remotePath, "--no-modtime=false"]
        if !recursive {
            args.append("--no-recurse")
        }

        guard let output = run(rclonePath: rclonePath, arguments: args) else {
            return []
        }

        return parseLsjson(output)
    }

    private static func parseLsjson(_ json: String) -> [RcloneFile] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return array.compactMap { dict in
            guard let name = dict["Name"] as? String else { return nil }
            let size = (dict["Size"] as? NSNumber)?.int64Value ?? 0
            let mimeType = dict["MimeType"] as? String
            let isDir = (dict["IsDir"] as? Bool) ?? false

            var modTime: Date?
            if let modTimeStr = dict["ModTime"] as? String {
                modTime = dateFormatter.date(from: modTimeStr)
                    ?? fallbackFormatter.date(from: modTimeStr)
            }

            return RcloneFile(
                name: name,
                size: size,
                mimeType: mimeType,
                modTime: modTime,
                isDir: isDir
            )
        }
    }

    // MARK: - Download (remote -> local)

    static func copyToLocal(rclonePath: String, remote: String, remotePath: String, localURL: URL) -> Bool {
        // Ensure parent directory exists
        try? FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let src = "\(remote):\(remotePath)"
        let dst = localURL.path
        let result = run(rclonePath: rclonePath, arguments: ["copyto", src, dst])
        return result != nil
    }

    // MARK: - Upload (local -> remote)

    static func copyToRemote(rclonePath: String, remote: String, localURL: URL, remotePath: String) -> Bool {
        let src = localURL.path
        let dst = "\(remote):\(remotePath)"
        let result = run(rclonePath: rclonePath, arguments: ["copyto", src, dst])
        return result != nil
    }

    // MARK: - Delete

    static func delete(rclonePath: String, remote: String, path: String) -> Bool {
        let target = "\(remote):\(path)"
        // Try deletefile first, fall back to purge for directories
        let result = run(rclonePath: rclonePath, arguments: ["deletefile", target])
        if result != nil { return true }
        let result2 = run(rclonePath: rclonePath, arguments: ["purge", target])
        return result2 != nil
    }

    // MARK: - Mkdir

    static func mkdir(rclonePath: String, remote: String, path: String) -> Bool {
        let target = "\(remote):\(path)"
        let result = run(rclonePath: rclonePath, arguments: ["mkdir", target])
        return result != nil
    }

    // MARK: - Move / Rename

    static func moveTo(rclonePath: String, remote: String, fromPath: String, toPath: String) -> Bool {
        let src = "\(remote):\(fromPath)"
        let dst = "\(remote):\(toPath)"
        let result = run(rclonePath: rclonePath, arguments: ["moveto", src, dst])
        return result != nil
    }

    // MARK: - Run Command

    @discardableResult
    private static func run(rclonePath: String, arguments: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }
}
