import SwiftUI

enum MoveDirection { case up, down }

struct RemoteRow: View {
    let remote: Remote
    var index: Int = 0
    var total: Int = 1
    var onMove: ((MoveDirection) -> Void)?
    @EnvironmentObject var rclone: RcloneService
    @State private var isHovering = false

    private var status: MountStatus {
        rclone.mountStatus(for: remote)
    }

    private var isBusy: Bool {
        status == .mounting || status == .unmounting
    }

    var body: some View {
        HStack(spacing: 8) {
            // Reorder buttons (only in popover, shown on hover)
            if onMove != nil {
                VStack(spacing: 0) {
                    Button {
                        onMove?(.up)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.3 : 1)

                    Button {
                        onMove?(.down)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(index >= total - 1)
                    .opacity(index >= total - 1 ? 0.3 : 1)
                }
                .opacity(isHovering ? 1 : 0)
            }

            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconGradient)
                    .frame(width: 24, height: 24)
                Image(systemName: remote.typeIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }

            // Name
            Text(remote.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if remote.autoMount {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
            }

            Spacer()

            // Status dot
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)

            // Mount/unmount button
            Button {
                Task { await rclone.toggleMount(remote) }
            } label: {
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 20, height: 20)
                } else if status == .mounted {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(status == .mounted ? .red : .accentColor)
            .disabled(isBusy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var shadowColor: Color {
        switch remote.type {
        case "s3": return .orange
        case "drive": return .blue
        case "dropbox": return .cyan
        case "onedrive": return .indigo
        case "sftp": return .green
        case "b2": return .red
        case "webdav": return .purple
        case "ftp": return .teal
        default: return .gray
        }
    }

    private var iconGradient: LinearGradient {
        let colors: [Color] = {
            switch remote.type {
            case "s3": return [.orange, .red]
            case "drive": return [.blue, .green]
            case "dropbox": return [.blue, .cyan]
            case "onedrive": return [.blue, .indigo]
            case "sftp": return [.green, .teal]
            case "b2": return [.red, .orange]
            case "webdav": return [.purple, .indigo]
            case "ftp": return [.teal, .blue]
            case "gcs": return [.blue, .cyan]
            case "smb": return [.indigo, .purple]
            case "box": return [.blue, .indigo]
            default: return [.gray, .secondary]
            }
        }()
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
