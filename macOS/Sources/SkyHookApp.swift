import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build a main menu with App + Edit menus so Cmd+Q works
        NSApplication.shared.mainMenu = {
            let mainMenu = NSMenu()
            let appItem = NSMenuItem()
            appItem.submenu = {
                let sub = NSMenu()
                sub.addItem(withTitle: "Quit SkyHook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                return sub
            }()
            mainMenu.addItem(appItem)
            return mainMenu
        }()

        // Close the config window that auto-opens on launch
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "SkyHook" {
                window.close()
            }
        }

        // MenuBarExtra apps don't route Cmd+key to the Edit menu properly.
        // Intercept standard editing shortcuts and send them to the focused field.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            switch key {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) { return nil }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) { return nil }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) { return nil }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) { return nil }
            case "z":
                let sel = event.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
                if NSApp.sendAction(sel, to: nil, from: nil) { return nil }
            default:
                break
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let mountBase = UserDefaults.standard.string(forKey: "defaultMountBase")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mnt").path

        // 1. Find NFS mounts from SkyHook (localhost NFS in mount base)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            guard line.contains("nfs") && line.contains("localhost") else { continue }
            if let onRange = line.range(of: " on "),
               let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex) {
                let mountPath = String(line[onRange.upperBound..<parenRange.lowerBound])
                guard mountPath.hasPrefix(mountBase) else { continue }
                let unmount = Process()
                unmount.executableURL = URL(fileURLWithPath: "/sbin/umount")
                unmount.arguments = [mountPath]
                unmount.standardOutput = FileHandle.nullDevice
                unmount.standardError = FileHandle.nullDevice
                try? unmount.run()
                unmount.waitUntilExit()
                try? FileManager.default.removeItem(atPath: mountPath)
            }
        }

        // 2. Kill SkyHook-tagged rclone and proxy processes
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/sh")
        kill.arguments = ["-c", "for pid in $(pgrep -f 'rclone serve\\|skyhook-nfs-proxy'); do if ps eww -p $pid 2>/dev/null | grep -q SKYHOOK=1; then kill $pid; fi; done"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
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
            Image(nsImage: Self.menuBarImage(rclone.mountedCount > 0 ? "cloud.fill" : "cloud"))
        }
        .menuBarExtraStyle(.window)

        Window("SkyHook", id: "config") {
            ConfigWindow()
                .environmentObject(rclone)
        }
        .defaultSize(width: 680, height: 480)
        .windowResizability(.contentSize)
    }

    static func menuBarImage(_ symbolName: String) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor])) else { return false }
            let symbolSize = symbol.size
            let x = round((rect.width - symbolSize.width) / 2) + 2
            let y = round((rect.height - symbolSize.height) / 2)
            symbol.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
            return true
        }
        img.isTemplate = true
        img.alignmentRect = NSRect(origin: .zero, size: size)
        return img
    }
}
