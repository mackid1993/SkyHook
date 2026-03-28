import SwiftUI

/// Polls rclone's RC API for live transfer stats.
@MainActor
class TransferMonitor: ObservableObject {
    static let shared = TransferMonitor()

    @Published var transfers: [TransferInfo] = []
    @Published var globalStats: GlobalStats = GlobalStats()

    private var rcPorts: [String: Int] = [:]  // remote name -> RC port
    private var pollTimer: Timer?
    private var isPolling = false
    private var emptyPollCount = 0  // consecutive polls with no active transfers

    struct TransferInfo: Identifiable {
        var id: String { name + remoteName }
        let remoteName: String
        let name: String
        let size: Int64
        let bytes: Int64
        let speed: Double
        let percentage: Int
        let isUpload: Bool

        var progress: Double {
            guard size > 0 else { return 0 }
            return Double(bytes) / Double(size)
        }

        var speedFormatted: String {
            formatBytes(Int64(speed)) + "/s"
        }

        var sizeFormatted: String {
            formatBytes(size)
        }

        var bytesFormatted: String {
            formatBytes(bytes)
        }
    }

    struct GlobalStats {
        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var totalTransfers: Int = 0
        var completedTransfers: Int = 0
        var speed: Double = 0
        var errors: Int = 0
        var activeTransfers: Int = 0

        var speedFormatted: String {
            formatBytes(Int64(speed)) + "/s"
        }

        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesTransferred) / Double(totalBytes)
        }

        var progressFormatted: String {
            "\(formatBytes(bytesTransferred)) / \(formatBytes(totalBytes))"
        }
    }

    func registerRC(remoteName: String, port: Int) {
        rcPorts[remoteName] = port
        startPolling()
    }

    func unregisterRC(remoteName: String) {
        rcPorts.removeValue(forKey: remoteName)
        // Immediately remove transfers for this remote so UI doesn't show stale data
        transfers.removeAll { $0.remoteName == remoteName }
        if rcPorts.isEmpty {
            stopPolling()
            transfers = []
            globalStats = GlobalStats()
        }
    }

    func cancelTransfer(_ transfer: TransferInfo) async {
        guard let port = rcPorts[transfer.remoteName],
              let url = URL(string: "http://127.0.0.1:\(port)/vfs/forget") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["file": transfer.name])
        request.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: request)
        transfers.removeAll { $0.id == transfer.id }
    }

    func unregisterAll() {
        rcPorts.removeAll()
        stopPolling()
        transfers = []
        globalStats = GlobalStats()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        var allTransfers: [TransferInfo] = []
        var combinedStats = GlobalStats()

        for (remoteName, port) in rcPorts {
            guard let stats = await fetchStats(port: port) else { continue }

            combinedStats.bytesTransferred += stats.bytesTransferred
            combinedStats.totalBytes += stats.totalBytes
            combinedStats.totalTransfers += stats.totalTransfers
            combinedStats.completedTransfers += stats.completedTransfers
            combinedStats.speed += stats.speed
            combinedStats.errors += stats.errors
            combinedStats.activeTransfers += stats.activeTransfers

            for t in stats.transferring {
                allTransfers.append(TransferInfo(
                    remoteName: remoteName,
                    name: t.name,
                    size: t.size,
                    bytes: t.bytes,
                    speed: t.speed,
                    percentage: t.percentage,
                    isUpload: false // rclone RC doesn't expose transfer direction
                ))
            }
        }

        // Avoid flickering: only clear the transfer list after 3 consecutive
        // empty polls (~9s), since rclone momentarily reports no active transfers
        // between chunks.
        if allTransfers.isEmpty && !transfers.isEmpty {
            emptyPollCount += 1
            if emptyPollCount < 3 { return }
        } else {
            emptyPollCount = 0
        }

        transfers = allTransfers
        globalStats = combinedStats
    }

    private struct RCStats {
        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var totalTransfers: Int = 0
        var completedTransfers: Int = 0
        var speed: Double = 0
        var errors: Int = 0
        var activeTransfers: Int = 0
        var transferring: [RCTransfer] = []
    }

    private struct RCTransfer {
        var name: String
        var size: Int64
        var bytes: Int64
        var speed: Double
        var percentage: Int
    }

    private func fetchStats(port: Int) async -> RCStats? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/core/stats") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            var stats = RCStats()
            stats.bytesTransferred = (json["bytes"] as? NSNumber)?.int64Value ?? 0
            stats.totalBytes = (json["totalBytes"] as? NSNumber)?.int64Value ?? 0
            stats.totalTransfers = (json["totalTransfers"] as? Int) ?? 0
            stats.completedTransfers = (json["transfers"] as? Int) ?? 0
            stats.speed = (json["speed"] as? Double) ?? 0
            // rclone accumulates harmless "errors" (e.g. Finder probing .DS_Store) — ignore them
            stats.errors = 0

            if let transferring = json["transferring"] as? [[String: Any]] {
                stats.activeTransfers = transferring.count
                stats.transferring = transferring.map { t in
                    RCTransfer(
                        name: (t["name"] as? String) ?? "unknown",
                        size: (t["size"] as? NSNumber)?.int64Value ?? 0,
                        bytes: (t["bytes"] as? NSNumber)?.int64Value ?? 0,
                        speed: (t["speed"] as? Double) ?? (t["speedAvg"] as? Double) ?? 0,
                        percentage: (t["percentage"] as? Int) ?? 0
                    )
                }
            }

            return stats
        } catch {
            return nil
        }
    }
}

// MARK: - Transfer Activity View

struct TransferActivityView: View {
    @StateObject private var monitor = TransferMonitor.shared
    @State private var transfers: [TransferMonitor.TransferInfo] = []
    @State private var stats: TransferMonitor.GlobalStats = .init()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if transfers.isEmpty && stats.activeTransfers == 0 {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No active transfers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                // Global progress
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Label("\(stats.activeTransfers) active", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(stats.speedFormatted)
                            .monospacedDigit()
                        if stats.errors > 0 {
                            Text("\(stats.errors) errors")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if stats.totalBytes > 0 {
                        ProgressView(value: stats.progress)
                            .tint(.blue)
                        HStack {
                            Text(stats.progressFormatted)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(stats.completedTransfers)/\(stats.totalTransfers)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Individual transfers
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(transfers) { transfer in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.arrow.down.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transfer.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if transfer.size > 0 {
                                        Text(transfer.sizeFormatted)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if transfer.speed > 0 {
                                    Text(transfer.speedFormatted)
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
        }
        .onAppear {
            transfers = monitor.transfers
            stats = monitor.globalStats
        }
        .onReceive(monitor.objectWillChange) { _ in
            DispatchQueue.main.async {
                transfers = monitor.transfers
                stats = monitor.globalStats
            }
        }
    }
}

// MARK: - Byte Formatting

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 { return "\(bytes) B" }
    return String(format: "%.1f %@", value, units[unitIndex])
}
