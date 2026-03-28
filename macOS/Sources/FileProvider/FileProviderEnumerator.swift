import FileProvider
import Foundation

/// Enumerates files and folders in a given rclone remote path.
/// Used by the system to populate Finder with directory contents.
class SkyHookEnumerator: NSObject, NSFileProviderEnumerator {

    let remoteName: String
    let remotePath: String
    let rclonePath: String
    let tempDir: URL
    private var lastSyncAnchor: UInt64 = 0

    init(remoteName: String, remotePath: String, rclonePath: String, tempDir: URL) {
        self.remoteName = remoteName
        self.remotePath = remotePath
        self.rclonePath = rclonePath
        self.tempDir = tempDir
        super.init()
    }

    func invalidate() {}

    // MARK: - Enumerate Items

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        DispatchQueue.global().async {
            let files = RcloneHelper.lsjson(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                path: self.remotePath,
                recursive: false
            )

            let items: [NSFileProviderItem] = files.map { file in
                SkyHookItem(
                    file: file,
                    parentPath: self.remotePath,
                    remoteName: self.remoteName,
                    materializedURL: self.materializedURL(for: file)
                )
            }

            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    // MARK: - Enumerate Changes

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // Re-enumerate everything as "changed" — rclone doesn't track deltas.
        // The system will diff against its cache.
        DispatchQueue.global().async {
            let files = RcloneHelper.lsjson(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                path: self.remotePath,
                recursive: false
            )

            let items: [NSFileProviderItem] = files.map { file in
                SkyHookItem(
                    file: file,
                    parentPath: self.remotePath,
                    remoteName: self.remoteName,
                    materializedURL: self.materializedURL(for: file)
                )
            }

            observer.didUpdate(items)

            let newAnchor = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(newAnchor),
                moreComing: false
            )
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let data = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(data))
    }

    // MARK: - Helpers

    private func materializedURL(for file: RcloneFile) -> URL {
        let fullPath = remotePath.isEmpty ? file.name : "\(remotePath)/\(file.name)"
        let safeComponents = fullPath.components(separatedBy: "/").filter { !$0.isEmpty }
        var url = tempDir
        for component in safeComponents {
            url = url.appendingPathComponent(component)
        }
        return url
    }
}
