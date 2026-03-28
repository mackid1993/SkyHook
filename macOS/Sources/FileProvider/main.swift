// Entry point for the File Provider extension process.
// The system launches this binary via PlugInKit when files are accessed.
// NSExtensionMain bootstraps the extension lifecycle.

import Foundation

// NSExtensionMain is the standard entry point for macOS extensions.
// It reads the NSExtension configuration from Info.plist and instantiates
// the principal class (SkyHookFileProvider).
autoreleasepool {
    let _ = ProcessInfo.processInfo
}
dispatchMain()
