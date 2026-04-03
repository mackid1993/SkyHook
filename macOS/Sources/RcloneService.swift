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

    @AppStorage("defaultMountBase") var defaultMountBase: String = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mnt").path
    }()
    @AppStorage("autoMountOnLaunch") var autoMountOnLaunch: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }

    // MARK: - rclone Settings

    @AppStorage("rclonePath") var rclonePath: String = ""

    // MARK: - Private

    private var serverProcesses: [String: Process] = [:]   // rclone serve nfs
    private var proxyProcesses: [String: Process] = [:]   // NFS filter proxy (compiled helper)
    private var mountPoints: [String: String] = [:]       // remote name -> mount path
    private var nextNFSPort = 19200
    private var nextProxyPort = 19300
    private var nextRCPort = 19400
    private var retryStates: [String: RetryState] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var healthCheckTask: Task<Void, Never>?

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
        // Detect rclone synchronously so UI isn't grayed out on launch
        let path = installDir.appendingPathComponent("rclone").path
        isRcloneInstalled = FileManager.default.fileExists(atPath: path)
        Task { await setup() }

        // Watch for volumes ejected from Finder
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { notification in
            guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleExternalUnmount(volumePath: volumePath)
            }
        }
    }

    func setup() async {
        // Trigger permission prompts on first launch by briefly starting rclone
        // (firewall prompt) and accessing /Volumes (removable volumes prompt)
        let rclonePath = effectiveRclonePath
        if !rclonePath.isEmpty {
            Task.detached {
                // Removable volumes permission
                _ = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")
                // Firewall/network permission — briefly start rclone to trigger the prompt
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: rclonePath)
                probe.arguments = ["serve", "webdav", ":memory:", "--addr", "127.0.0.1:19199"]
                probe.standardOutput = FileHandle.nullDevice
                probe.standardError = FileHandle.nullDevice
                try? probe.run()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                probe.terminate()
            }
        }
        await detectRclone()
        await cleanupOrphans()
        if isRcloneInstalled {
            if autoMountOnLaunch { await autoMountRemotes() }
        }
        await checkForUpdate()
        startHealthMonitor()
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
            var parsed = parseConfig(content)
            // Apply saved ordering
            let order = UserDefaults.standard.stringArray(forKey: "remoteOrder") ?? []
            if !order.isEmpty {
                parsed.sort { a, b in
                    let ia = order.firstIndex(of: a.name) ?? Int.max
                    let ib = order.firstIndex(of: b.name) ?? Int.max
                    return ia < ib
                }
            }
            remotes = parsed
        } catch {
            remotes = []
        }
    }

    func moveRemotes(from source: IndexSet, to destination: Int) {
        remotes.move(fromOffsets: source, toOffset: destination)
        saveRemoteOrder()
    }

    private func saveRemoteOrder() {
        UserDefaults.standard.set(remotes.map(\.name), forKey: "remoteOrder")
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
            UserDefaults.standard.removeObject(forKey: "autoMount_\(name)")
            UserDefaults.standard.removeObject(forKey: "remotePath_\(name)")
            RemoteSettings.delete(for: name)
            loadRemotes()
        }
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
        let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000]
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            await mountNFS(remote: remote)

            if mountStatuses[name] == .mounted { return }

            // Check if failure is definitive (don't retry)
            if case .error(let msg) = mountStatuses[name] {
                let definitiveErrors = ["no such remote", "invalid", "not found", "token has been revoked", "cancelled"]
                if definitiveErrors.contains(where: { msg.lowercased().contains($0) }) { return }
            }

            if attempt < maxAttempts {
                mountStatuses[name] = .mounting
                try? await Task.sleep(nanoseconds: retryDelays[attempt - 1])
            }
        }
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

        // Unmount first while rclone is still serving, so the NFS detach is clean
        TransferMonitor.shared.unregisterRC(remoteName: name)
        let mountPath = mountPoints[name] ?? "\(defaultMountBase)/\(name)"
        _ = await runProcess("/sbin/umount", args: [mountPath])

        // Now kill rclone and proxy processes
        if let proxy = proxyProcesses[name] {
            if proxy.isRunning { proxy.terminate() }
            proxyProcesses.removeValue(forKey: name)
        }
        if let process = serverProcesses[name] {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { process.interrupt() }
            serverProcesses.removeValue(forKey: name)
        }

        try? FileManager.default.removeItem(atPath: mountPath)
        mountPoints.removeValue(forKey: name)
        retryStates.removeValue(forKey: name)
        consecutiveFailures.removeValue(forKey: name)

        mountStatuses[name] = .unmounted
    }

    func toggleMount(_ remote: Remote) async {
        if mountStatuses[remote.name] == .mounted {
            await unmount(remote)
        } else {
            await mount(remote)
        }
    }

    // MARK: - NFS Mount

    /// Pick a volume name for this remote, appending a number if the name is taken.
    private func volumeName(for name: String) -> String {
        let fm = FileManager.default
        let base = name.replacingOccurrences(of: " ", with: "-")
        let path = "\(defaultMountBase)/\(base)"
        if fm.fileExists(atPath: path) {
            if let contents = try? fm.contentsOfDirectory(atPath: path), contents.isEmpty {
                try? fm.removeItem(atPath: path)
            }
        }
        if !fm.fileExists(atPath: path) { return base }
        var i = 1
        while fm.fileExists(atPath: "\(defaultMountBase)/\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    /// Get the per-remote settings, falling back to provider-aware defaults.
    func settings(for remote: Remote) -> RemoteSettings {
        RemoteSettings.load(for: remote.name, type: remote.type)
    }

    /// Path to the compiled NFS filter proxy helper.
    private var nfsProxyPath: String {
        let bundled = Bundle.main.resourcePath.map { "\($0)/skyhook-nfs-proxy" } ?? ""
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return installDir.appendingPathComponent("skyhook-nfs-proxy").path
    }

    private func mountNFS(remote: Remote) async {
        let name = remote.name
        let rclone = effectiveRclonePath
        let subpath = remote.remotePath.isEmpty ? "" : remote.remotePath
        let remotePath = "\(name):\(subpath)"
        // Per-remote mount point override, or default ~/mnt/RemoteName
        let customMount = UserDefaults.standard.string(forKey: "mountPoint_\(name)") ?? ""
        let mountPath: String
        if !customMount.isEmpty {
            mountPath = (customMount as NSString).expandingTildeInPath
        } else {
            let volName = volumeName(for: name)
            mountPath = "\(defaultMountBase)/\(volName)"
        }
        let nfsPort = nextNFSPort
        nextNFSPort += 1
        let proxyPort = nextProxyPort
        nextProxyPort += 1
        let rcPort = nextRCPort
        nextRCPort += 1

        let settings = RemoteSettings.load(for: name, type: remote.type)

        // Kill anything already on these ports
        _ = await runProcess("/bin/sh", args: ["-c", "lsof -ti :\(nfsPort) -ti :\(proxyPort) -ti :\(rcPort) | xargs kill -9 2>/dev/null; true"])
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Create mount point directory
        try? FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)

        // 1. Start rclone serve nfs
        let server = Process()
        server.executableURL = URL(fileURLWithPath: rclone)
        server.environment = ProcessInfo.processInfo.environment.merging(["SKYHOOK": "1"]) { _, new in new }
        server.arguments = ["serve", "nfs", remotePath,
                            "--addr", "127.0.0.1:\(nfsPort)",
                            "--rc", "--rc-addr", "127.0.0.1:\(rcPort)", "--rc-no-auth"]
                            + settings.buildFlags()
        server.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        server.standardError = errPipe

        do { try server.run() } catch {
            mountStatuses[name] = .error("Failed to start NFS server")
            return
        }

        serverProcesses[name] = server
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        guard server.isRunning else {
            let errData = errPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            mountStatuses[name] = .error(errStr.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "NFS server exited")
            serverProcesses.removeValue(forKey: name)
            return
        }

        // 2. Start NFS filter proxy (blocks ._* and .DS_Store at the RPC level)
        let proxyPath = nfsProxyPath
        guard FileManager.default.fileExists(atPath: proxyPath) else {
            mountStatuses[name] = .error("NFS proxy helper not found")
            server.terminate()
            serverProcesses.removeValue(forKey: name)
            return
        }

        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: proxyPath)
        proxy.arguments = ["\(proxyPort)", "\(nfsPort)"]
        proxy.environment = ["SKYHOOK": "1"]
        proxy.standardOutput = FileHandle.nullDevice
        proxy.standardError = FileHandle.nullDevice

        do { try proxy.run() } catch {
            mountStatuses[name] = .error("Failed to start NFS proxy")
            server.terminate()
            serverProcesses.removeValue(forKey: name)
            return
        }

        proxyProcesses[name] = proxy
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 3. Mount via mount_nfs (no sudo needed for user-writable dirs)
        let mountOk = await runProcess("/sbin/mount_nfs", args: [
            "-o", "port=\(proxyPort),mountport=\(proxyPort),vers=3,tcp,locallocks,soft,timeo=100,retrans=5,rsize=1048576,wsize=1048576",
            "127.0.0.1:/", mountPath
        ])

        if mountOk {
            mountPoints[name] = mountPath
            mountStatuses[name] = .mounted
            TransferMonitor.shared.registerRC(remoteName: name, port: rcPort)
        } else {
            mountStatuses[name] = .error("mount_nfs failed")
            proxy.terminate()
            proxyProcesses.removeValue(forKey: name)
            server.terminate()
            serverProcesses.removeValue(forKey: name)
            try? FileManager.default.removeItem(atPath: mountPath)
        }
    }

    // MARK: - Helpers

    /// Wait for a TCP port to accept connections.
    private func waitForPort(port: Int, timeout: Int) async -> Bool {
        for _ in 0..<(timeout * 2) {
            let ok = await Task.detached {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { return false }
                defer { close(fd) }
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                return withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
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
            let result = script?.executeAndReturnError(&errorInfo)
            if let error = errorInfo {
                let msg = error["NSAppleScriptErrorMessage"] as? String
                return (false, msg)
            }
            return (true, result?.stringValue)
        }.value
    }

    private func handleExternalUnmount(volumePath: String) {
        for (name, path) in mountPoints {
            if volumePath == path {
                if let process = serverProcesses[name], process.isRunning { process.terminate() }
                serverProcesses.removeValue(forKey: name)
                if let proxy = proxyProcesses[name], proxy.isRunning { proxy.terminate() }
                proxyProcesses.removeValue(forKey: name)
                TransferMonitor.shared.unregisterRC(remoteName: name)
                mountPoints.removeValue(forKey: name)
                retryStates.removeValue(forKey: name)
                consecutiveFailures.removeValue(forKey: name)
                mountStatuses[name] = .unmounted
                break
            }
        }
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
        mountPoints[remote.name] ?? "\(defaultMountBase)/\(remote.name)"
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

    // MARK: - Per-Remote Settings Helpers

    func saveSettings(_ settings: RemoteSettings, for remote: Remote) {
        settings.save(for: remote.name)
    }

    func resetSettings(for remote: Remote) {
        RemoteSettings.delete(for: remote.name)
    }

    // MARK: - Health Monitor (Watchdog)

    private func startHealthMonitor() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self = self else { break }
                await self.performHealthChecks()
            }
        }
    }

    private func performHealthChecks() async {
        for remote in remotes {
            let name = remote.name
            guard mountStatuses[name] == .mounted else { continue }

            // Check if the rclone process is still alive
            let processAlive = serverProcesses[name]?.isRunning ?? false

            if !processAlive {
                // Process died — attempt auto-remount
                await attemptAutoRemount(remote: remote)
                continue
            }

            // Check if mount point is still accessible
            if let path = mountPoints[name] {
                let accessible = FileManager.default.fileExists(atPath: path)
                if !accessible {
                    let failures = (consecutiveFailures[name] ?? 0) + 1
                    consecutiveFailures[name] = failures
                    if failures >= 3 {
                        serverProcesses[name]?.terminate()
                        serverProcesses.removeValue(forKey: name)
                        proxyProcesses[name]?.terminate()
                        proxyProcesses.removeValue(forKey: name)
                        await attemptAutoRemount(remote: remote)
                    }
                } else {
                    consecutiveFailures[name] = 0
                }
            }
        }
    }

    private func attemptAutoRemount(remote: Remote) async {
        let name = remote.name
        var state = retryStates[name] ?? RetryState()

        guard state.attempts < RetryState.maxAttempts else {
            mountStatuses[name] = .error("Server crashed — manual remount required")
            return
        }

        let backoff = RetryState.backoffIntervals[min(state.attempts, RetryState.backoffIntervals.count - 1)]
        let elapsed = Date().timeIntervalSince(state.lastAttempt)
        if elapsed < backoff {
            return // Not enough time since last attempt
        }

        state.attempts += 1
        state.lastAttempt = Date()
        retryStates[name] = state

        // Clean up the dead mount
        let mountPath = mountPoints[name] ?? "\(defaultMountBase)/\(name)"
        _ = await runProcess("/sbin/umount", args: [mountPath])
        try? FileManager.default.removeItem(atPath: mountPath)
        proxyProcesses[name]?.terminate()
        proxyProcesses.removeValue(forKey: name)
        mountPoints.removeValue(forKey: name)

        // Attempt remount
        mountStatuses[name] = .mounting
        await mountNFS(remote: remote)

        // If mount succeeded, reset retry state
        if mountStatuses[name] == .mounted {
            retryStates.removeValue(forKey: name)
            consecutiveFailures.removeValue(forKey: name)
        }
    }

    // MARK: - Orphan Cleanup

    private func cleanupOrphans() async {
        // Kill stale SkyHook-tagged rclone and proxy processes from prior crashed sessions
        _ = await runProcess("/bin/sh", args: ["-c", "for pid in $(pgrep -f 'rclone serve'); do if ps eww -p $pid 2>/dev/null | grep -q SKYHOOK=1; then kill $pid; fi; done"])
        _ = await runProcess("/bin/sh", args: ["-c", "for pid in $(pgrep -f 'skyhook-nfs-proxy'); do if ps eww -p $pid 2>/dev/null | grep -q SKYHOOK=1; then kill $pid; fi; done"])
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Unmount dead NFS mounts from SkyHook (localhost NFS in mount base)
        let mountOutput = await getProcessOutput("/sbin/mount", args: [])
        for line in mountOutput.components(separatedBy: "\n") {
            if line.contains("localhost") && line.contains("nfs") {
                if let onRange = line.range(of: " on "),
                   let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex) {
                    let mountPath = String(line[onRange.upperBound..<parenRange.lowerBound])
                    if mountPath.hasPrefix(defaultMountBase) {
                        _ = await runProcess("/sbin/umount", args: [mountPath])
                        try? FileManager.default.removeItem(atPath: mountPath)
                    }
                }
            }
        }
    }

    private func getProcessOutput(_ path: String, args: [String]) async -> String {
        await Task.detached {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } catch { return "" }
        }.value
    }

    // MARK: - Cleanup

    func cleanup() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        await unmountAll()
        for (_, process) in serverProcesses {
            if process.isRunning { process.terminate() }
        }
        serverProcesses.removeAll()
        for (_, proxy) in proxyProcesses {
            if proxy.isRunning { proxy.terminate() }
        }
        proxyProcesses.removeAll()
    }
}
