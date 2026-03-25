import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous cleanup — can't use async here without deadlocking MainActor
        // 1. Kill all rclone server processes
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "rclone serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        // 2. Unmount all SkyHook WebDAV volumes
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in contents {
                let path = "/Volumes/\(vol)"
                // Check if it's a WebDAV mount on localhost
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/sbin/mount")
                let pipe = Pipe()
                check.standardOutput = pipe
                check.standardError = FileHandle.nullDevice
                try? check.run()
                check.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if output.contains("127.0.0") && output.contains(path) && output.contains("webdav") {
                    let unmount = Process()
                    unmount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    unmount.arguments = ["unmount", "force", path]
                    unmount.standardOutput = FileHandle.nullDevice
                    unmount.standardError = FileHandle.nullDevice
                    try? unmount.run()
                    unmount.waitUntilExit()
                }
            }
        }
    }
}

@main
struct SkyHookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var rclone = RcloneService.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(rclone)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: rclone.mountedCount > 0 ? "cloud.fill" : "cloud")
                if rclone.mountedCount > 0 {
                    Text("\(rclone.mountedCount)")
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("SkyHook", id: "config") {
            ConfigWindow()
                .environmentObject(rclone)
        }
        .defaultSize(width: 680, height: 480)
        .windowResizability(.contentSize)
    }
}
