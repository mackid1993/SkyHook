import SwiftUI

struct MenuBarView: View {
    @StateObject private var rclone = RcloneService.shared
    @Environment(\.openWindow) var openWindow

    @StateObject private var transferMonitor = TransferMonitor.shared

    // MenuBarExtra (.window style) doesn't drive @ObservedObject re-renders.
    // Mirror published properties into @State so SwiftUI picks up changes.
    @State private var remotes: [Remote] = []
    @State private var mountStatuses: [String: MountStatus] = [:]
    @State private var isRcloneInstalled: Bool = false
    @State private var isDownloadingRclone: Bool = false
    @State private var rcloneVersion: String?
    @State private var updateAvailable: Bool = false
    @State private var statusMessage: String?
    private func syncState() {
        remotes = rclone.remotes
        mountStatuses = rclone.mountStatuses
        isRcloneInstalled = rclone.isRcloneInstalled
        isDownloadingRclone = rclone.isDownloadingRclone
        rcloneVersion = rclone.rcloneVersion
        updateAvailable = rclone.updateAvailable
        statusMessage = rclone.statusMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
            if mountStatuses.values.contains(.mounted) {
                Divider()
                transferSection
            }
            Divider()
            footerSection
        }
        .frame(width: 340)
        .onAppear { syncState() }
        .onReceive(rclone.objectWillChange) { _ in
            DispatchQueue.main.async { syncState() }
        }
        .onReceive(transferMonitor.objectWillChange) { _ in
            DispatchQueue.main.async { syncState() }
        }
    }

    // MARK: - Transfers

    private var transferSection: some View {
        DisclosureGroup {
            TransferActivityView()
                .padding(.horizontal, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Transfers")
                    .font(.subheadline.weight(.medium))
                if transferMonitor.globalStats.activeTransfers > 0 {
                    Text("\(transferMonitor.globalStats.activeTransfers)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SkyHook")
                    .font(.headline)
                if isRcloneInstalled, let version = rcloneVersion {
                    Text("rclone \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isDownloadingRclone {
                ProgressView()
                    .scaleEffect(0.7)
            } else if updateAvailable {
                Button {
                    Task { await rclone.updateRclone() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Update")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    // MARK: - Content

    private var contentSection: some View {
        Group {
            if !remotes.isEmpty {
                remoteListView
            } else if !isRcloneInstalled {
                notInstalledView
            } else {
                emptyStateView
            }
        }
    }

    private var notInstalledView: some View {
        VStack(spacing: 12) {
            if isDownloadingRclone {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 4)
                Text(statusMessage ?? "Downloading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)

                Text("rclone not found")
                    .font(.subheadline.weight(.medium))

                Text("Install rclone to get started")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Download & Install rclone") {
                    Task { await rclone.downloadAndInstallRclone() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.bolt")
                .font(.system(size: 36))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("No remotes configured")
                .font(.subheadline.weight(.medium))

            Text("Add a remote to start mounting cloud storage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Configure Remotes") {
                openWindow(id: "config")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var remoteListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(remotes) { remote in
                    RemoteRow(remote: remote)
                        .environmentObject(rclone)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 600)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                openWindow(id: "config")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Configure...", systemImage: "gear")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Spacer()

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
