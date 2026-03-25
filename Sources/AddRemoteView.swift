import SwiftUI

struct AddRemoteView: View {
    @EnvironmentObject var rclone: RcloneService
    @Environment(\.dismiss) var dismiss

    @State private var remoteName: String = ""
    @State private var selectedType: String = "s3"
    @State private var autoMount: Bool = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var allBackends: [(type: String, name: String)] {
        RemoteType.allBackendTypes
    }

    private var needsOAuth: Bool {
        RemoteType.oauthTypes.contains(selectedType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Add Remote")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Remote name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remote Name")
                            .font(.subheadline.weight(.medium))
                        TextField("my-remote", text: $remoteName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Provider dropdown
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provider")
                            .font(.subheadline.weight(.medium))

                        Picker("", selection: $selectedType) {
                            ForEach(allBackends, id: \.type) { backend in
                                HStack {
                                    Image(systemName: RemoteType.icon(for: backend.type))
                                    Text(backend.name)
                                }
                                .tag(backend.type)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider()

                    // Setup info
                    HStack {
                        Image(systemName: needsOAuth ? "key.fill" : "terminal.fill")
                            .foregroundStyle(needsOAuth ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(needsOAuth ? "Browser Authorization" : "Interactive Setup")
                                .font(.subheadline.weight(.medium))
                            Text(needsOAuth
                                ? "A browser window will open to authorize access."
                                : "You'll configure connection details in the next step.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background((needsOAuth ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Divider()

                    Toggle("Auto-mount at login", isOn: $autoMount)

                    // Error display
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                        }
                        .padding(10)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20)
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isCreating ? "Creating..." : "Add Remote") {
                    createRemote()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(remoteName.isEmpty || isCreating)
            }
            .padding(16)
        }
        .frame(width: 500, height: 520)
        .sheet(isPresented: $showSetup) {
            SetupView(session: setupSession) { success in
                showSetup = false
                if success {
                    rclone.loadRemotes()
                    dismiss()
                } else {
                    // Clean up the partial remote config so user can retry
                    Task {
                        _ = await rclone.runProcess(
                            rclone.effectiveRclonePath,
                            args: ["config", "delete", remoteName])
                        rclone.loadRemotes()
                    }
                    UserDefaults.standard.removeObject(forKey: "autoMount_\(remoteName)")
                    errorMessage = "Setup was cancelled"
                }
            }
        }
    }

    @State private var showSetup = false
    @StateObject private var setupSession = SetupSession()

    // MARK: - Create Remote

    private func createRemote() {
        errorMessage = nil

        if autoMount {
            UserDefaults.standard.set(true, forKey: "autoMount_\(remoteName)")
        }

        setupSession.start(
            rclonePath: rclone.effectiveRclonePath,
            name: remoteName,
            type: selectedType
        )
        showSetup = true
    }
}
