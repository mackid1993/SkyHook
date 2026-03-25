import FileProvider
import Foundation

/// Main File Provider extension — one instance per rclone remote (domain).
/// Handles all file operations by shelling out to the rclone binary.
class SkyHookFileProvider: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain
    let remoteName: String
    let tempDir: URL
    let rclonePath: String

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.remoteName = domain.identifier.rawValue
        self.rclonePath = RcloneHelper.findRclone()

        // Each domain gets its own temp directory for materialized files
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyHook")
            .appendingPathComponent(domain.identifier.rawValue)
        self.tempDir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        super.init()
    }

    func invalidate() {
        // Cleanup temp files when domain is removed
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            let root = SkyHookItem.rootItem(remoteName: remoteName)
            completionHandler(root, nil)
            progress.completedUnitCount = 1
            return progress
        }

        let remotePath = identifierToPath(identifier)

        DispatchQueue.global().async {
            let items = RcloneHelper.lsjson(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                path: self.parentPath(of: remotePath),
                recursive: false
            )

            let filename = (remotePath as NSString).lastPathComponent
            if let match = items.first(where: { $0.name == filename }) {
                let item = SkyHookItem(
                    file: match,
                    parentPath: self.parentPath(of: remotePath),
                    remoteName: self.remoteName,
                    materializedURL: self.materializedURL(for: remotePath)
                )
                completionHandler(item, nil)
            } else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: - Enumerate

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let path: String
        if containerItemIdentifier == .rootContainer {
            path = ""
        } else {
            path = identifierToPath(containerItemIdentifier)
        }

        return SkyHookEnumerator(
            remoteName: remoteName,
            remotePath: path,
            rclonePath: rclonePath,
            tempDir: tempDir
        )
    }

    // MARK: - Fetch (Download)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let remotePath = identifierToPath(itemIdentifier)
        let localURL = materializedURL(for: remotePath)

        DispatchQueue.global().async {
            // Download file from remote
            let success = RcloneHelper.copyToLocal(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                remotePath: remotePath,
                localURL: localURL
            )

            if success {
                // Get item metadata
                let parentDir = self.parentPath(of: remotePath)
                let items = RcloneHelper.lsjson(
                    rclonePath: self.rclonePath,
                    remote: self.remoteName,
                    path: parentDir,
                    recursive: false
                )
                let filename = (remotePath as NSString).lastPathComponent
                if let match = items.first(where: { $0.name == filename }) {
                    let item = SkyHookItem(
                        file: match,
                        parentPath: parentDir,
                        remoteName: self.remoteName,
                        materializedURL: localURL
                    )
                    progress.completedUnitCount = 100
                    completionHandler(localURL, item, nil)
                } else {
                    completionHandler(localURL, nil, nil)
                }
            } else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            }
        }

        return progress
    }

    // MARK: - Create

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let parentPath = identifierToPath(itemTemplate.parentItemIdentifier)
        let itemPath = parentPath.isEmpty
            ? itemTemplate.filename
            : "\(parentPath)/\(itemTemplate.filename)"

        DispatchQueue.global().async {
            if itemTemplate.contentType == .folder {
                // Create directory
                let success = RcloneHelper.mkdir(
                    rclonePath: self.rclonePath,
                    remote: self.remoteName,
                    path: itemPath
                )
                if success {
                    let item = SkyHookItem.folderItem(
                        name: itemTemplate.filename,
                        path: itemPath,
                        remoteName: self.remoteName
                    )
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                }
            } else if let localURL = url {
                // Upload file
                let success = RcloneHelper.copyToRemote(
                    rclonePath: self.rclonePath,
                    remote: self.remoteName,
                    localURL: localURL,
                    remotePath: itemPath
                )
                if success {
                    // Re-fetch metadata
                    let items = RcloneHelper.lsjson(
                        rclonePath: self.rclonePath,
                        remote: self.remoteName,
                        path: parentPath,
                        recursive: false
                    )
                    if let match = items.first(where: { $0.name == itemTemplate.filename }) {
                        let item = SkyHookItem(
                            file: match,
                            parentPath: parentPath,
                            remoteName: self.remoteName,
                            materializedURL: localURL
                        )
                        completionHandler(item, [], false, nil)
                    } else {
                        completionHandler(nil, [], false, nil)
                    }
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                }
            } else {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            }
            progress.completedUnitCount = 100
        }

        return progress
    }

    // MARK: - Modify

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let remotePath = identifierToPath(item.itemIdentifier)

        DispatchQueue.global().async {
            // If contents changed, re-upload
            if changedFields.contains(.contents), let localURL = newContents {
                let success = RcloneHelper.copyToRemote(
                    rclonePath: self.rclonePath,
                    remote: self.remoteName,
                    localURL: localURL,
                    remotePath: remotePath
                )
                if !success {
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                    return
                }
            }

            // If filename changed, move/rename
            if changedFields.contains(.filename) {
                let parentPath = self.identifierToPath(item.parentItemIdentifier)
                let newPath = parentPath.isEmpty
                    ? item.filename
                    : "\(parentPath)/\(item.filename)"
                let success = RcloneHelper.moveTo(
                    rclonePath: self.rclonePath,
                    remote: self.remoteName,
                    fromPath: remotePath,
                    toPath: newPath
                )
                if !success {
                    completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                    return
                }
            }

            // Return updated item
            let parentDir = self.parentPath(of: remotePath)
            let items = RcloneHelper.lsjson(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                path: parentDir,
                recursive: false
            )
            let filename = item.filename
            if let match = items.first(where: { $0.name == filename }) {
                let updatedItem = SkyHookItem(
                    file: match,
                    parentPath: parentDir,
                    remoteName: self.remoteName,
                    materializedURL: self.materializedURL(for: remotePath)
                )
                completionHandler(updatedItem, [], false, nil)
            } else {
                completionHandler(nil, [], false, nil)
            }
            progress.completedUnitCount = 100
        }

        return progress
    }

    // MARK: - Delete

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let remotePath = identifierToPath(identifier)

        DispatchQueue.global().async {
            let success = RcloneHelper.delete(
                rclonePath: self.rclonePath,
                remote: self.remoteName,
                path: remotePath
            )
            completionHandler(success ? nil : NSFileProviderError(.serverUnreachable))

            // Clean up local materialized file
            let localURL = self.materializedURL(for: remotePath)
            try? FileManager.default.removeItem(at: localURL)

            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: - Path Helpers

    func identifierToPath(_ identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer { return "" }
        // Identifier format: "path/to/file" (relative to remote root)
        return identifier.rawValue
    }

    func parentPath(of path: String) -> String {
        return (path as NSString).deletingLastPathComponent
    }

    func materializedURL(for remotePath: String) -> URL {
        let safeComponents = remotePath.components(separatedBy: "/").filter { !$0.isEmpty }
        var url = tempDir
        for component in safeComponents {
            url = url.appendingPathComponent(component)
        }
        // Ensure parent directory exists
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }
}
