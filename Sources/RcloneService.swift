import SwiftUI
import ServiceManagement

@MainActor
class RcloneService: ObservableObject {
    static let shared = RcloneService()

    // MARK: - Published State

    @Published var remotes: [Remote] = []
    @Published var mountStatuses: [String: MountStatus] = [:]
    @Published var rcloneVersion: String?
    @Published var isRcloneInstalled = false
    @Published var isDownloadingRclone = false
    @Published var latestVersion: String?
    @Published var statusMessage: String?

    // MARK: - Settings

    @AppStorage("defaultMountBase") var defaultMountBase: String = "/Volumes"
    @AppStorage("autoMountOnLaunch") var autoMountOnLaunch: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }

    // MARK: - rclone Advanced Settings

    @AppStorage("vfsCacheMode") var vfsCacheMode: String = "full"
    @AppStorage("vfsCacheMaxAge") var vfsCacheMaxAge: String = "1h"
    @AppStorage("vfsCacheMaxSize") var vfsCacheMaxSize: String = "10G"
    @AppStorage("vfsReadChunkSize") var vfsReadChunkSize: String = "128M"
    @AppStorage("vfsCachePollInterval") var vfsCachePollInterval: String = "5m"
    @AppStorage("bufferSize") var bufferSize: String = "16M"
    @AppStorage("transfers") var transfers: String = "4"
    @AppStorage("dirCacheTime") var dirCacheTime: String = "5m"
    @AppStorage("attrTimeout") var attrTimeout: String = "1s"
    @AppStorage("vfsReadAhead") var vfsReadAhead: String = "128M"
    @AppStorage("nfsReadSize") var nfsReadSize: String = ""
    @AppStorage("extraFlags") var extraFlags: String = ""
    @AppStorage("rclonePath") var rclonePath: String = ""

    // MARK: - Private

    private var serverProcesses: [String: Process] = [:]
    private var mountHostnames: [String: String] = [:]  // remote name -> volume hostname
    private var nextPort = 19200
    private var nextRCPort = 19400

    private var installDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    // MARK: - Computed

    var effectiveRclonePath: String {
        let path = installDir.appendingPathComponent("rclone").path
        return FileManager.default.fileExists(atPath: path) ? path : ""
    }

    var rcloneConfigPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/rclone.conf")
    }

    var mountedCount: Int {
        mountStatuses.values.filter { $0 == .mounted }.count
    }

    var updateAvailable: Bool {
        guard let current = rcloneVersion, let latest = latestVersion else { return false }
        return current.trimmingCharacters(in: .whitespaces) != latest.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Setup

    init() {
        loadRemotes()
        loadAutoMountPreferences()
        Task { await setup() }
    }

    func setup() async {
        await detectRclone()
        if isRcloneInstalled {
            if autoMountOnLaunch { await autoMountRemotes() }
        }
        await checkForUpdate()
    }

    // MARK: - rclone Detection

    func detectRclone() async {
        let path = effectiveRclonePath
        guard !path.isEmpty else {
            isRcloneInstalled = false
            rcloneVersion = nil
            return
        }
        isRcloneInstalled = true
        rcloneVersion = await fetchVersion()
        RemoteType.loadBackends(rclonePath: path)
    }

    private func fetchVersion() async -> String? {
        let path = effectiveRclonePath
        guard !path.isEmpty else { return nil }
        return await Task.detached {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["version"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return output.components(separatedBy: "\n").first?
                    .replacingOccurrences(of: "rclone ", with: "")
            } catch { return nil }
        }.value
    }

    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/rclone/rclone/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                latestVersion = tag
            }
        } catch {}
    }

    // MARK: - Install / Update / Uninstall rclone

    func downloadAndInstallRclone() async {
        isDownloadingRclone = true
        statusMessage = "Downloading rclone..."

        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let arch = machine.contains("arm64") ? "arm64" : "amd64"
        let dest = installDir.appendingPathComponent("rclone").path

        let script = """
        set -e
        TMPDIR=$(mktemp -d)
        ZIP="$TMPDIR/rclone.zip"
        mkdir -p "\(installDir.path)"
        LATEST=$(curl -fsSL "https://api.github.com/repos/rclone/rclone/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/{print $4; exit}')
        if [ -n "$LATEST" ]; then
            curl -fsSL -o "$ZIP" "https://github.com/rclone/rclone/releases/download/${LATEST}/rclone-${LATEST}-osx-\(arch).zip" 2>/dev/null
        else
            curl -fsSL -o "$ZIP" "https://downloads.rclone.org/rclone-current-osx-\(arch).zip" 2>/dev/null
        fi
        unzip -o -q "$ZIP" -d "$TMPDIR" 2>/dev/null
        RCLONE_DIR=$(ls -d "$TMPDIR"/rclone-* | head -1)
        cp "$RCLONE_DIR/rclone" "\(dest)"
        chmod 755 "\(dest)"
        rm -rf "$TMPDIR"
        """

        let ok = await runProcess("/bin/sh", args: ["-c", script])

        if ok && FileManager.default.fileExists(atPath: dest) {
            isRcloneInstalled = true
            let version = await Task.detached { () -> String? in
                let proc = Process()
                let pipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: dest)
                proc.arguments = ["version"]
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    return output.components(separatedBy: "\n").first?
                        .replacingOccurrences(of: "rclone ", with: "")
                } catch { return nil }
            }.value
            rcloneVersion = version
            RemoteType.loadBackends(rclonePath: dest)
            loadRemotes()
            statusMessage = "rclone \(version ?? "") installed"
        } else {
            statusMessage = "Install failed — check your internet connection"
        }

        isDownloadingRclone = false
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            statusMessage = nil
        }
    }

    func updateRclone() async { await downloadAndInstallRclone() }

    func uninstallRclone() {
        let path = effectiveRclonePath
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
        statusMessage = "rclone uninstalled"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await detectRclone()
            statusMessage = nil
        }
    }

    // MARK: - Remote Management (all via rclone binary)

    func loadRemotes() {
        guard FileManager.default.fileExists(atPath: rcloneConfigPath.path) else {
            remotes = []
            return
        }
        do {
            let content = try String(contentsOf: rcloneConfigPath, encoding: .utf8)
            remotes = parseConfig(content)
        } catch {
            remotes = []
        }
    }

    /// Rewrite a single remote's section in rclone.conf with the given config.
    /// Preserves all other remotes and comments.
    func writeRemoteConfig(name: String, config: [String: String]) -> Bool {
        let path = rcloneConfigPath
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return false }

        let lines = content.components(separatedBy: "\n")
        var newLines: [String] = []
        var inTarget = false
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if inTarget {
                    // We were in the target section — already replaced, skip old content done
                    inTarget = false
                }
                let sectionName = String(trimmed.dropFirst().dropLast())
                if sectionName == name {
                    inTarget = true
                    replaced = true
                    // Write new section
                    newLines.append("[\(name)]")
                    for (key, value) in config.sorted(by: { $0.key < $1.key }) {
                        newLines.append("\(key) = \(value)")
                    }
                    continue
                }
            }
            if inTarget {
                // Skip old lines in the target section
                if trimmed.isEmpty || trimmed.contains("=") || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                    continue
                }
            }
            newLines.append(line)
        }

        // If the section wasn't found, append it
        if !replaced {
            if let last = newLines.last, !last.isEmpty { newLines.append("") }
            newLines.append("[\(name)]")
            for (key, value) in config.sorted(by: { $0.key < $1.key }) {
                newLines.append("\(key) = \(value)")
            }
        }

        let result = newLines.joined(separator: "\n")
        do {
            try result.write(to: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func parseConfig(_ content: String) -> [Remote] {
        var result: [Remote] = []
        var currentName: String?
        var currentConfig: [String: String] = [:]

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let name = currentName {
                    result.append(Remote(
                        name: name,
                        type: currentConfig["type"] ?? "unknown",
                        config: currentConfig,
                        mountPoint: "\(defaultMountBase)/\(name)",
                        remotePath: UserDefaults.standard.string(forKey: "remotePath_\(name)") ?? "",
                        autoMount: UserDefaults.standard.bool(forKey: "autoMount_\(name)")
                    ))
                }
                currentName = String(trimmed.dropFirst().dropLast())
                currentConfig = [:]
            } else if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
                let val = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                currentConfig[key] = val
            }
        }

        if let name = currentName {
            result.append(Remote(
                name: name,
                type: currentConfig["type"] ?? "unknown",
                config: currentConfig,
                mountPoint: "\(defaultMountBase)/\(name)",
                remotePath: UserDefaults.standard.string(forKey: "remotePath_\(name)") ?? "",
                autoMount: UserDefaults.standard.bool(forKey: "autoMount_\(name)")
            ))
        }

        return result
    }

    /// Create a remote via rclone config create.
    /// Uses `expect` to create a pseudo-terminal so rclone thinks it's interactive.
    /// Auto-answers all prompts with defaults ("y" for y/n, enter for everything else).
    /// For OAuth, rclone opens the browser automatically. No Terminal window.
    func createRemote(name: String, type: String, params: [String: String]) async -> Bool {
        let rclone = effectiveRclonePath
        guard !rclone.isEmpty else { return false }

        let isOAuth = RemoteType.oauthTypes.contains(type)

        if isOAuth {
            _ = await runProcess("/bin/sh", args: ["-c", "lsof -ti :53682 | xargs kill 2>/dev/null; true"])
            statusMessage = "Waiting for browser authorization..."
        } else {
            statusMessage = "Creating remote..."
        }

        // Build args
        var args = ["config", "create", name, type]
        for (key, value) in params where !value.isEmpty {
            args.append("\(key)=\(value)")
        }

        // Run rclone with a pseudo-terminal (pty) so it enters interactive mode.
        // Pre-write empty lines to accept all defaults. Browser opens for OAuth.
        // No Terminal window, no external dependencies.
        let ok = await runWithPty(rclone, args, input: String(repeating: "\n", count: 50))

        if ok {
            loadRemotes()
            statusMessage = isOAuth ? "\(name) authorized" : "\(name) created"
        } else {
            // Clean up failed OAuth remote
            if isOAuth {
                _ = await runProcess(rclone, args: ["config", "delete", name])
            }
            statusMessage = isOAuth ? "Authorization failed or cancelled" : "Failed to create remote"
        }

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            statusMessage = nil
        }
        return ok
    }

    /// Delete a remote via rclone config delete.
    func deleteRemote(_ remote: Remote) {
        let name = remote.name
        let rclone = effectiveRclonePath

        // Remove from UI immediately to prevent stale references
        remotes.removeAll { $0.name == name }
        mountStatuses.removeValue(forKey: name)

        Task {
            if mountStatuses[name] == .mounted {
                await unmount(remote)
            }
            if !rclone.isEmpty {
                _ = await runProcess(rclone, args: ["config", "delete", name])
            }
            await removeHostEntry(for: name)
            UserDefaults.standard.removeObject(forKey: "autoMount_\(name)")
            UserDefaults.standard.removeObject(forKey: "remotePath_\(name)")
            loadRemotes()
        }
    }

    /// Remove SkyHook host entries for a remote from /etc/hosts.
    /// Silent — doesn't prompt if it fails. Entries are harmless if left behind.
    private func removeHostEntry(for name: String) async {
        let hostname = name.replacingOccurrences(of: " ", with: "-")
        // Use sed to remove the line. Escape hostname for regex safety.
        let escaped = hostname.replacingOccurrences(of: ".", with: "\\\\.")
        let (ok, _) = await runAppleScript("""
            do shell script "sed -i '' '/\(escaped).*# SkyHook/d' /etc/hosts && dscacheutil -flushcache" with administrator privileges
        """)
        _ = ok  // silently ignore failures
    }

    /// Open full interactive rclone config in Terminal.
    /// If name/type provided, goes directly to creating that remote.
    func openAdvancedConfig(name: String? = nil, type: String? = nil) {
        let rclone = effectiveRclonePath
        guard !rclone.isEmpty else { return }

        let cmd: String
        if let n = name, let t = type {
            // Go directly to creating this specific remote interactively
            cmd = "'\(rclone)' config create '\(n)' '\(t)'"
        } else {
            cmd = "'\(rclone)' config"
        }

        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("skyhook-config-\(UUID().uuidString).command").path
        let content = "#!/bin/bash\n\(cmd)\necho ''\necho 'Done. You can close this window.'\nread -p 'Press Enter to close...'\n"
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
        chmod(scriptPath, 0o755)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [scriptPath]
        try? proc.run()
    }

    // MARK: - Auto-mount Preferences

    func loadAutoMountPreferences() {
        for i in remotes.indices {
            remotes[i].autoMount = UserDefaults.standard.bool(forKey: "autoMount_\(remotes[i].name)")
        }
    }

    func toggleAutoMount(for remote: Remote) {
        if let idx = remotes.firstIndex(where: { $0.id == remote.id }) {
            remotes[idx].autoMount.toggle()
            UserDefaults.standard.set(remotes[idx].autoMount, forKey: "autoMount_\(remote.name)")
        }
    }

    func setRemotePath(for remote: Remote, path: String) {
        if let idx = remotes.firstIndex(where: { $0.id == remote.id }) {
            remotes[idx].remotePath = path
            UserDefaults.standard.set(path, forKey: "remotePath_\(remote.name)")
        }
    }

    // MARK: - Mounting

    func mount(_ remote: Remote) async {
        let name = remote.name
        guard mountStatuses[name] != .mounted && mountStatuses[name] != .mounting else { return }

        mountStatuses[name] = .mounting
        let port = nextPort
        nextPort += 1
        await mountWebDAV(remote: remote, port: port)
    }

    func unmount(_ remote: Remote) async {
        let name = remote.name
        let currentStatus = mountStatuses[name] ?? .unmounted
        let canUnmount: Bool
        switch currentStatus {
        case .mounted, .error: canUnmount = true
        default: canUnmount = false
        }
        guard canUnmount else { return }

        mountStatuses[name] = .unmounting

        // Kill the rclone server process FIRST to unblock any stuck I/O
        if let process = serverProcesses[name] {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { process.interrupt() }
            serverProcesses.removeValue(forKey: name)
        }

        TransferMonitor.shared.unregisterRC(remoteName: name)
        let volName = mountHostnames[name] ?? name
        _ = await runProcess("/usr/sbin/diskutil", args: ["unmount", "force", "\(defaultMountBase)/\(volName)"])
        mountHostnames.removeValue(forKey: name)

        mountStatuses[name] = .unmounted
    }

    func toggleMount(_ remote: Remote) async {
        if mountStatuses[remote.name] == .mounted {
            await unmount(remote)
        } else {
            await mount(remote)
        }
    }

    // MARK: - WebDAV Mount

    /// Pick a volume hostname for this remote, appending a number if the name is taken.
    private func volumeHostname(for name: String) -> String {
        let fm = FileManager.default
        let base = name.replacingOccurrences(of: " ", with: "-")
        if !fm.fileExists(atPath: "\(defaultMountBase)/\(base)") { return base }
        var i = 1
        while fm.fileExists(atPath: "\(defaultMountBase)/\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    /// Ensure /etc/hosts has entries for all SkyHook mounts.
    /// Batches all needed entries into a single admin prompt.
    private func ensureHostEntries(_ entries: [(hostname: String, loopback: String)]) async {
        let hostsFile = "/etc/hosts"
        let existing = (try? String(contentsOfFile: hostsFile, encoding: .utf8)) ?? ""

        let needed = entries.filter { !existing.contains("\($0.loopback)\t\($0.hostname)") }
        guard !needed.isEmpty else { return }

        let lines = needed.map { "\($0.loopback)\t\($0.hostname) # SkyHook" }.joined(separator: "\\n")
        let (ok, _) = await runAppleScript("""
            do shell script "printf '\\n\(lines)\\n' >> \(hostsFile)" with administrator privileges
        """)
        if ok {
            _ = await runProcess("/usr/bin/dscacheutil", args: ["-flushcache"])
        }
    }

    private func mountWebDAV(remote: Remote, port: Int) async {
        let name = remote.name
        let rclone = effectiveRclonePath
        let subpath = remote.remotePath.isEmpty ? "" : remote.remotePath
        let remotePath = "\(name):\(subpath)"
        let hostname = volumeHostname(for: name)
        let rcPort = nextRCPort
        nextRCPort += 1

        // Ensure hostname resolves to 127.0.0.1 — different hostnames prevent
        // macOS from treating multiple WebDAV mounts as the same server
        await ensureHostEntries([(hostname: hostname, loopback: "127.0.0.1")])

        // Kill anything already on these ports
        _ = await runProcess("/bin/sh", args: ["-c", "lsof -ti :\(port) -ti :\(rcPort) | xargs kill -9 2>/dev/null; true"])
        try? await Task.sleep(nanoseconds: 500_000_000)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: rclone)
        server.arguments = ["serve", "webdav", remotePath, "--addr", "127.0.0.1:\(port)",
                            "--rc", "--rc-addr", "127.0.0.1:\(rcPort)", "--rc-no-auth"] + buildRcloneFlags()
        server.standardOutput = FileHandle.nullDevice
        let webdavErrPipe = Pipe()
        server.standardError = webdavErrPipe

        do { try server.run() } catch {
            mountStatuses[name] = .error("Failed to start WebDAV server")
            return
        }

        serverProcesses[name] = server
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        guard server.isRunning else {
            let errData = webdavErrPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            mountStatuses[name] = .error("WebDAV: \(errStr.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "server exited")")
            serverProcesses.removeValue(forKey: name)
            return
        }

        // Verify WebDAV server is actually responding before asking Finder to mount
        let ready = await waitForWebDAV(port: port, timeout: 10)
        if !ready {
            let errData = webdavErrPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            let lastLine = errStr.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "Server not responding"
            // Clean up common rclone error prefixes for readability
            let cleanErr = lastLine
                .replacingOccurrences(of: ".*CRITICAL: ", with: "", options: .regularExpression)
                .replacingOccurrences(of: ".*ERROR: ", with: "", options: .regularExpression)
            mountStatuses[name] = .error(cleanErr)
            server.terminate()
            serverProcesses.removeValue(forKey: name)
            return
        }

        // Mount via Finder — volume name will be the hostname
        let (success, errorMsg) = await runAppleScript("""
            tell application "Finder"
                mount volume "http://\(hostname):\(port)"
            end tell
        """)

        if success {
            mountHostnames[name] = hostname
            mountStatuses[name] = .mounted
            TransferMonitor.shared.registerRC(remoteName: name, port: rcPort)
        } else {
            mountStatuses[name] = .error(errorMsg ?? "Finder mount failed")
            server.terminate()
            serverProcesses.removeValue(forKey: name)
        }
    }

    // MARK: - Sudo / Mount Helpers


    // MARK: - Helpers

    /// Poll the WebDAV server until it responds or timeout (seconds) expires.
    private func waitForWebDAV(port: Int, timeout: Int) async -> Bool {
        for _ in 0..<(timeout * 2) {
            let ok = await Task.detached {
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
                req.timeoutInterval = 2
                return (try? await URLSession.shared.data(for: req)).map { _ in true } ?? false
            }.value
            if ok { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Run a process with a pseudo-terminal so it thinks it's interactive.
    /// Pre-writes `input` as answers to prompts (empty lines = accept defaults).
    /// Used for rclone config create which needs a tty for OAuth browser flow.
    private func runWithPty(_ executable: String, _ arguments: [String], input: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let master = posix_openpt(O_RDWR)
                guard master >= 0 else { continuation.resume(returning: false); return }
                guard grantpt(master) == 0, unlockpt(master) == 0 else {
                    close(master); continuation.resume(returning: false); return
                }
                guard let sname = ptsname(master) else {
                    close(master); continuation.resume(returning: false); return
                }
                let slave = open(String(cString: sname), O_RDWR)
                guard slave >= 0 else {
                    close(master); continuation.resume(returning: false); return
                }

                // Pre-write answers to the pty master
                _ = input.data(using: .utf8)?.withUnsafeBytes { write(master, $0.baseAddress!, $0.count) }

                // Drain master output in background to prevent pty buffer from filling
                DispatchQueue.global().async {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while read(master, &buf, buf.count) > 0 {}
                }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                proc.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                proc.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                proc.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

                var resumed = false
                proc.terminationHandler = { process in
                    close(slave)
                    close(master)
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: process.terminationStatus == 0)
                    }
                }

                do { try proc.run() } catch {
                    close(slave); close(master)
                    continuation.resume(returning: false)
                    return
                }

                // Timeout: kill rclone if it takes too long (stuck in retry loops etc)
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                    if proc.isRunning {
                        proc.terminate()
                        if !resumed {
                            resumed = true
                            // Still return true — OAuth token may have been saved even if rclone hung after
                            continuation.resume(returning: true)
                        }
                    }
                }
            }
        }
    }

    /// Run a process in the background. Returns true if exit code 0.
    @discardableResult
    func runProcess(_ path: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
                proc.environment = env
                proc.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus == 0)
                }
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func runAppleScript(_ source: String) async -> (Bool, String?) {
        await Task.detached {
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
            if let error = errorInfo {
                let msg = error["NSAppleScriptErrorMessage"] as? String
                return (false, msg)
            }
            return (true, nil)
        }.value
    }

    func unmountAll() async {
        for remote in remotes {
            if mountStatuses[remote.name] == .mounted {
                await unmount(remote)
            }
        }
    }

    func autoMountRemotes() async {
        for remote in remotes where remote.autoMount {
            await mount(remote)
        }
    }

    func mountStatus(for remote: Remote) -> MountStatus {
        mountStatuses[remote.name] ?? .unmounted
    }

    func actualMountPath(for remote: Remote) -> String {
        let volName = mountHostnames[remote.name] ?? remote.name
        return "\(defaultMountBase)/\(volName)"
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
    }

    // MARK: - rclone Flags Builder

    func buildRcloneFlags() -> [String] {
        var flags: [String] = []
        if !vfsCacheMode.isEmpty { flags += ["--vfs-cache-mode", vfsCacheMode] }
        if !vfsCacheMaxAge.isEmpty { flags += ["--vfs-cache-max-age", vfsCacheMaxAge] }
        if !vfsCacheMaxSize.isEmpty { flags += ["--vfs-cache-max-size", vfsCacheMaxSize] }
        if !vfsReadChunkSize.isEmpty { flags += ["--vfs-read-chunk-size", vfsReadChunkSize] }
        if !vfsCachePollInterval.isEmpty { flags += ["--vfs-cache-poll-interval", vfsCachePollInterval] }
        if !bufferSize.isEmpty { flags += ["--buffer-size", bufferSize] }
        if !transfers.isEmpty { flags += ["--transfers", transfers] }
        if !dirCacheTime.isEmpty { flags += ["--dir-cache-time", dirCacheTime] }
        if !vfsReadAhead.isEmpty { flags += ["--vfs-read-ahead", vfsReadAhead] }
        if !extraFlags.isEmpty {
            flags += extraFlags.components(separatedBy: " ").filter { !$0.isEmpty }
        }
        return flags
    }

    // MARK: - Cleanup

    func cleanup() async {
        await unmountAll()
        for (_, process) in serverProcesses {
            if process.isRunning { process.terminate() }
        }
        serverProcesses.removeAll()
    }
}
