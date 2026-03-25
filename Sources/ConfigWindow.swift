import SwiftUI

struct ConfigWindow: View {
    @EnvironmentObject var rclone: RcloneService
    @State private var selectedTab = "remotes"
    static var pendingTab: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                remotesTab
                    .tabItem { Label("Remotes", systemImage: "cloud.fill") }
                    .tag("remotes")

                settingsTab
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag("settings")
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            if let tab = Self.pendingTab {
                selectedTab = tab
                Self.pendingTab = nil
            }
        }
    }

    // advancedTab removed — settings are now per-remote in RemoteDetailView

    // MARK: - Remotes Tab

    @State private var selectedRemoteId: UUID?
    @State private var showAddSheet = false

    private var selectedRemote: Remote? {
        rclone.remotes.first { $0.id == selectedRemoteId }
    }

    private var remotesTab: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 0) {
                List(rclone.remotes, selection: $selectedRemoteId) { remote in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(gradientFor(remote.type))
                                .frame(width: 28, height: 28)
                            Image(systemName: remote.typeIcon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(remote.displayType)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if rclone.mountStatus(for: remote) == .mounted {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .shadow(color: .green.opacity(0.5), radius: 3)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(remote.id)
                }

                Divider()

                HStack(spacing: 4) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add remote")

                    Button {
                        if let remote = selectedRemote {
                            rclone.deleteRemote(remote)
                            selectedRemoteId = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedRemote == nil)
                    .help("Remove remote")

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(rclone.rcloneConfigPath)
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .help("Edit rclone.conf")
                    .disabled(!rclone.isRcloneInstalled)

                    Button {
                        rclone.loadRemotes()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload rclone.conf (~/.config/rclone/rclone.conf)")
                }
                .padding(8)
                .buttonStyle(.borderless)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            // Detail
            if let remote = selectedRemote {
                RemoteDetailView(remote: remote)
                    .environmentObject(rclone)
                    .id(remote.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "cloud")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue.opacity(0.4), .indigo.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("Select a remote to view its configuration")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddRemoteView()
                .environmentObject(rclone)
        }
    }

    // MARK: - Advanced / Performance Tab

    // advancedTab removed — settings are now per-remote in RemoteDetailView

    // MARK: - Settings Tab

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsHowItWorksSection
                settingsRcloneSection
                settingsMountSection
                settingsStartupSection
                settingsAboutSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsHowItWorksSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("How SkyHook Works", systemImage: "info.circle.fill")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SkyHook mounts your cloud storage as native Finder volumes using rclone's WebDAV server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("**Hosts File**: The first time you mount a remote, SkyHook adds an entry to /etc/hosts (e.g. `127.0.0.1 Dropbox`) so the volume appears with a clean name in Finder. This requires a one-time admin password or Touch ID prompt per remote. The entry persists so you won't be prompted again for that remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("**Cleanup**: Hosts entries are tagged with `# SkyHook` and automatically removed when you delete a remote. If the app crashes, orphaned entries are cleaned up on next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("**No passwords stored**: SkyHook never stores your admin password. It uses the native macOS authorization dialog only when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }


    private var settingsRcloneSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("rclone", systemImage: "terminal.fill")
                    .font(.headline)

                HStack {
                    Text("Path:")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("Path to rclone binary", text: $rclone.rclonePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForRclone()
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("Version:")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    if rclone.isRcloneInstalled {
                        Text(rclone.rcloneVersion ?? "Unknown")
                            .monospacedDigit()

                        if rclone.updateAvailable {
                            Text("(\(rclone.latestVersion ?? "") available)")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    } else {
                        Text("Not installed")
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Download & Install rclone") {
                        Task { await rclone.downloadAndInstallRclone() }
                    }
                    .controlSize(.small)
                    .disabled(rclone.isDownloadingRclone)

                    Spacer()

                    Button("Uninstall rclone") {
                        rclone.uninstallRclone()
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .disabled(!rclone.isRcloneInstalled)

                    Button {
                        Task { await rclone.detectRclone() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Re-detect rclone")
                }
            }
            .padding(8)
        }
    }

    private var settingsMountSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Mounting", systemImage: "externaldrive.fill")
                    .font(.headline)

                Text("Mounts cloud storage as a WebDAV volume via Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var settingsStartupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Startup", systemImage: "power")
                    .font(.headline)

                Toggle("Launch SkyHook at login", isOn: $rclone.launchAtLogin)
                Toggle("Auto-mount remotes at login", isOn: $rclone.autoMountOnLaunch)

                Text("Remotes with the auto-mount flag will mount automatically when SkyHook starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var settingsAboutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("About", systemImage: "info.circle")
                    .font(.headline)

                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .indigo],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SkyHook")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Cloud storage, mounted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private func browseForRclone() {
        let panel = NSOpenPanel()
        panel.title = "Select rclone binary"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")

        if panel.runModal() == .OK, let url = panel.url {
            rclone.rclonePath = url.path
            Task { await rclone.detectRclone() }
        }
    }

    private func gradientFor(_ type: String) -> LinearGradient {
        let colors: [Color] = {
            switch type {
            case "s3": return [.orange, .red]
            case "drive": return [.blue, .green]
            case "dropbox": return [.blue, .cyan]
            case "onedrive": return [.blue, .indigo]
            case "sftp": return [.green, .teal]
            case "b2": return [.red, .orange]
            case "webdav": return [.purple, .indigo]
            case "ftp": return [.teal, .blue]
            default: return [.gray, .secondary]
            }
        }()
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Remote Detail View

struct RemoteDetailView: View {
    let remote: Remote
    @EnvironmentObject var rclone: RcloneService
    @State private var isEditing = false
    @State private var configText: String = ""
    @State private var isSaving = false
    @State private var showEditSheet = false
    @StateObject private var editSession = SetupSession()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: gradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)
                        Image(systemName: remote.typeIcon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: gradientColors.first?.opacity(0.3) ?? .clear, radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(remote.name)
                            .font(.title2.weight(.semibold))
                        Text(remote.displayType)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusBadge
                }

                Divider()

                // Config display / edit
                GroupBox {
                    if isEditing {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $configText)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.03))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                                )
                            Text("One key = value per line. Add, remove, or change any fields.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(6)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(remote.config.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack(alignment: .top) {
                                    Text(key)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .frame(width: 140, alignment: .trailing)
                                        .foregroundStyle(.secondary)

                                    if key.contains("secret") || key.contains("pass") || key == "key" || key.contains("token") {
                                        Text(String(repeating: "\u{2022}", count: min(value.count, 20)))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        Text(value)
                                            .font(.system(size: 12, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                } label: {
                    HStack {
                        Text("Configuration")
                        Spacer()
                        if isEditing {
                            Button("Cancel") {
                                isEditing = false
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Button {
                                Task { await saveConfig() }
                            } label: {
                                if isSaving {
                                    ProgressView().scaleEffect(0.6)
                                } else {
                                    Text("Save")
                                }
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(isSaving)
                        } else {
                            Button {
                                // Build raw text from current config
                                configText = remote.config
                                    .sorted(by: { $0.key < $1.key })
                                    .map { "\($0.key) = \($0.value)" }
                                    .joined(separator: "\n")
                                isEditing = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .disabled(!rclone.isRcloneInstalled)
                        }
                    }
                }

                // Performance (per-remote)
                PerRemoteSettingsView(remote: remote)
                    .environmentObject(rclone)

                // Options
                GroupBox("Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Path:")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            TextField("e.g. / or Documents/Work", text: Binding(
                                get: { remote.remotePath },
                                set: { rclone.setRemotePath(for: remote, path: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        }
                        Text("Path to mount. Use / for root. Empty = remote default (usually home dir).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Toggle("Auto-mount at login", isOn: Binding(
                            get: { remote.autoMount },
                            set: { _ in rclone.toggleAutoMount(for: remote) }
                        ))
                    }
                    .padding(6)
                }

                // Actions
                HStack(spacing: 12) {
                    Button {
                        Task { await rclone.toggleMount(remote) }
                    } label: {
                        HStack(spacing: 6) {
                            if rclone.mountStatus(for: remote) == .mounting || rclone.mountStatus(for: remote) == .unmounting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            }
                            Label({
                                switch rclone.mountStatus(for: remote) {
                                case .mounted: return "Unmount"
                                case .mounting: return "Mounting..."
                                case .unmounting: return "Unmounting..."
                                default: return "Mount"
                                }
                            }() as String,
                            systemImage: rclone.mountStatus(for: remote) == .mounted ? "eject.fill" : "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(rclone.mountStatus(for: remote) == .mounted ? .red : .accentColor)
                    .disabled({
                        let status = rclone.mountStatus(for: remote)
                        return status == .mounting || status == .unmounting || !rclone.isRcloneInstalled
                    }())

                    Button {
                        editSession.start(
                            rclonePath: rclone.effectiveRclonePath,
                            name: remote.name,
                            type: remote.type,
                            edit: true
                        )
                        showEditSheet = true
                    } label: {
                        Label("Reconfigure", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(!rclone.isRcloneInstalled)

                    if rclone.mountStatus(for: remote) == .mounted {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: rclone.actualMountPath(for: remote)))
                        }
                        .controlSize(.small)
                    }

                    Spacer()
                }

                // Error display
                if case .error(let msg) = rclone.mountStatus(for: remote) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showEditSheet) {
            SetupView(session: editSession) { success in
                showEditSheet = false
                if success {
                    rclone.loadRemotes()
                }
            }
        }
    }

    private func saveConfig() async {
        isSaving = true

        // Parse edited text into key=value pairs
        var newConfig: [String: String] = [:]
        for line in configText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
                let val = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { newConfig[key] = val }
            }
        }

        // Always keep the type
        newConfig["type"] = remote.config["type"] ?? remote.type

        // Write directly to rclone.conf — rclone config update can't delete keys
        let ok = rclone.writeRemoteConfig(name: remote.name, config: newConfig)
        if ok {
            rclone.loadRemotes()
            isEditing = false
        }
        isSaving = false
    }

    private var statusBadge: some View {
        let status = rclone.mountStatus(for: remote)
        return HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(status.color.opacity(0.1), in: Capsule())
    }

    private var gradientColors: [Color] {
        switch remote.type {
        case "s3": return [.orange, .red]
        case "drive": return [.blue, .green]
        case "dropbox": return [.blue, .cyan]
        case "onedrive": return [.blue, .indigo]
        case "sftp": return [.green, .teal]
        case "b2": return [.red, .orange]
        case "webdav": return [.purple, .indigo]
        case "ftp": return [.teal, .blue]
        default: return [.gray, .secondary]
        }
    }
}

// MARK: - Per-Remote Settings View

struct PerRemoteSettingsView: View {
    let remote: Remote
    @EnvironmentObject var rclone: RcloneService
    @State private var settings: RemoteSettings = RemoteSettings.defaults(for: "")
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Optimized defaults for \(remote.displayType). Adjust only if needed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    settingsField("Cache Mode", value: $settings.vfsCacheMode, help: "off, minimal, writes, full")
                    settingsField("Cache Max Age", value: $settings.vfsCacheMaxAge, help: "e.g. 1h, 24h")
                    settingsField("Cache Max Size", value: $settings.vfsCacheMaxSize, help: "e.g. 1G, 10G")
                    settingsField("Read Chunk Size", value: $settings.vfsReadChunkSize, help: "e.g. 4M, 32M, 64M")
                    settingsField("Cache Poll", value: $settings.vfsCachePollInterval, help: "e.g. 30s, 1m")
                    settingsField("Buffer Size", value: $settings.bufferSize, help: "e.g. 256k, 512k")
                    settingsField("Transfers", value: $settings.transfers, help: "e.g. 4, 8, 16")
                    settingsField("Dir Cache Time", value: $settings.dirCacheTime, help: "e.g. 1m, 5m")
                    settingsField("Read Ahead", value: $settings.vfsReadAhead, help: "e.g. 32M, 128M")
                    settingsField("Extra Flags", value: $settings.extraFlags, help: "--flag value")

                    HStack {
                        Button("Reset to Defaults") {
                            RemoteSettings.delete(for: remote.name)
                            let fresh = RemoteSettings.defaults(for: remote.type)
                            settings = fresh
                            fresh.save(for: remote.name)
                        }
                        .controlSize(.small)

                        Spacer()

                        Text("Changes apply on next mount")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 8)
            } label: {
                Text("Performance")
            }
            .padding(6)
        }
        .onAppear {
            settings = RemoteSettings.load(for: remote.name, type: remote.type)
        }
        .onChange(of: settings) { _, newValue in
            newValue.save(for: remote.name)
        }
    }

    private func settingsField(_ label: String, value: Binding<String>, help: String) -> some View {
        HStack {
            Text(label + ":")
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField(help, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
