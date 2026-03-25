import FileProvider
import Foundation

/// Manages File Provider domains — registers/unregisters rclone remotes
/// as File Provider domains so they appear in ~/Library/CloudStorage/.
/// Handles clean teardown to prevent orphaned entries.
enum DomainManager {

    /// Register a remote as a File Provider domain.
    /// Creates an entry in Finder sidebar under Cloud Storage.
    static func addDomain(remoteName: String) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: remoteName),
            displayName: remoteName
        )
        try await NSFileProviderManager.add(domain)
    }

    /// Remove a File Provider domain cleanly.
    /// This removes the entry from ~/Library/CloudStorage/ and Finder sidebar.
    /// Also cleans up any cached/materialized files.
    static func removeDomain(remoteName: String) async throws {
        let domains = try await NSFileProviderManager.domains()
        guard let domain = domains.first(where: { $0.identifier.rawValue == remoteName }) else {
            return
        }

        // Get the manager to clean up materialized files first
        if let manager = NSFileProviderManager(for: domain) {
            // Signal the extension to clean up
            try? await manager.signalEnumerator(for: .rootContainer)
            // Evict all downloaded content
            try? await manager.evictItem(identifier: .rootContainer)
        }

        // Remove the domain — this cleans up ~/Library/CloudStorage/remoteName
        try await NSFileProviderManager.remove(domain)

        // Clean up temp files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyHook")
            .appendingPathComponent(remoteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Remove ALL SkyHook File Provider domains.
    /// Call this on app uninstall or full cleanup.
    static func removeAllDomains() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            for domain in domains {
                try? await NSFileProviderManager.remove(domain)
            }
        } catch {}

        // Nuke the entire temp directory
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyHook")
        try? FileManager.default.removeItem(at: tempBase)
    }

    /// Get list of currently registered domains.
    static func registeredDomains() async -> [String] {
        do {
            let domains = try await NSFileProviderManager.domains()
            return domains.map { $0.identifier.rawValue }
        } catch {
            return []
        }
    }

    /// Sync domains with current rclone remotes.
    /// Adds missing domains, removes stale ones.
    static func syncDomains(remoteNames: [String]) async {
        let registered = await registeredDomains()

        // Add new domains
        for name in remoteNames where !registered.contains(name) {
            try? await addDomain(remoteName: name)
        }

        // Remove stale domains
        for name in registered where !remoteNames.contains(name) {
            try? await removeDomain(remoteName: name)
        }
    }
}
