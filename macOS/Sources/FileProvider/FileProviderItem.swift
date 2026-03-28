import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Represents a file or folder in the File Provider.
/// Maps rclone file metadata to NSFileProviderItem.
class SkyHookItem: NSObject, NSFileProviderItem {

    private let file: RcloneFile?
    private let path: String
    private let remote: String
    private let isRoot: Bool
    private let localURL: URL?

    // Root container item
    static func rootItem(remoteName: String) -> SkyHookItem {
        let item = SkyHookItem(
            file: nil,
            path: "",
            remote: remoteName,
            isRoot: true,
            localURL: nil
        )
        return item
    }

    // Standard file/folder item
    convenience init(file: RcloneFile, parentPath: String, remoteName: String, materializedURL: URL?) {
        let fullPath = parentPath.isEmpty ? file.name : "\(parentPath)/\(file.name)"
        self.init(file: file, path: fullPath, remote: remoteName, isRoot: false, localURL: materializedURL)
    }

    // Folder item helper
    static func folderItem(name: String, path: String, remoteName: String) -> SkyHookItem {
        let fakeFile = RcloneFile(
            name: name,
            size: 0,
            mimeType: "inode/directory",
            modTime: Date(),
            isDir: true
        )
        return SkyHookItem(file: fakeFile, path: path, remote: remoteName, isRoot: false, localURL: nil)
    }

    private init(file: RcloneFile?, path: String, remote: String, isRoot: Bool, localURL: URL?) {
        self.file = file
        self.path = path
        self.remote = remote
        self.isRoot = isRoot
        self.localURL = localURL
        super.init()
    }

    // MARK: - NSFileProviderItem

    var itemIdentifier: NSFileProviderItemIdentifier {
        if isRoot { return .rootContainer }
        return NSFileProviderItemIdentifier(path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if isRoot { return .rootContainer }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." || parent == "/" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(parent)
    }

    var filename: String {
        if isRoot { return remote }
        return file?.name ?? (path as NSString).lastPathComponent
    }

    var contentType: UTType {
        guard let file = file else { return .folder }
        if file.isDir { return .folder }

        // Determine type from extension
        let ext = (file.name as NSString).pathExtension.lowercased()
        if let uttype = UTType(filenameExtension: ext) {
            return uttype
        }

        // Fallback to MIME type
        if let mime = file.mimeType, let uttype = UTType(mimeType: mime) {
            return uttype
        }

        return .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if isRoot || (file?.isDir ?? false) {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
    }

    var documentSize: NSNumber? {
        guard let file = file, !file.isDir else { return nil }
        return NSNumber(value: file.size)
    }

    var contentModificationDate: Date? {
        return file?.modTime
    }

    var creationDate: Date? {
        return file?.modTime
    }

    var itemVersion: NSFileProviderItemVersion {
        // Use modification time as version
        let content = file?.modTime?.timeIntervalSince1970 ?? 0
        let contentData = withUnsafeBytes(of: content) { Data($0) }
        return NSFileProviderItemVersion(
            contentVersion: contentData,
            metadataVersion: contentData
        )
    }

    // Offline availability — users can pin files for offline access
    var isDownloaded: Bool {
        guard let url = localURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var isDownloading: Bool {
        return false
    }

    var isUploaded: Bool {
        return true // Items from remote are always "uploaded"
    }

    var isUploading: Bool {
        return false
    }
}
