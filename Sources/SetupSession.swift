import SwiftUI
import Darwin

// MARK: - Prompt Model

enum PromptControl {
    case yesNo(defaultYes: Bool)
    case choices(items: [(id: String, label: String)], defaultId: String)
    case textField(placeholder: String, defaultValue: String, isSecret: Bool)
    case oauthWait(url: String)
}

struct RclonePrompt: Identifiable {
    let id = UUID()
    let title: String
    let helpText: String
    let control: PromptControl
}

// MARK: - Session State

enum SessionPhase {
    case starting
    case autoNav      // silently sending n, name, type
    case interactive  // showing prompts to user
    case done
}

// MARK: - Setup Session

@MainActor
class SetupSession: ObservableObject {
    @Published var currentPrompt: RclonePrompt?
    @Published var phase: SessionPhase = .starting
    @Published var statusText: String = "Starting..."
    @Published var succeeded = false

    private var masterFd: Int32 = -1
    private var slaveFd: Int32 = -1
    private var process: Process?
    private var buffer = ""
    private var autoNavName = ""
    private var autoNavType = ""
    private var autoNavStep = 0 // 0=menu, 1=name, 2=type, 3=done
    private var isEditMode = false
    private var debounceTimer: Timer?

    // MARK: - Start

    func start(rclonePath: String, name: String, type: String, edit: Bool = false) {
        // Kill any previous session
        process?.terminate()
        cleanup()

        autoNavName = name
        autoNavType = type
        autoNavStep = 0
        isEditMode = edit
        phase = .autoNav
        statusText = "Configuring \(name)..."
        currentPrompt = nil
        succeeded = false
        buffer = ""

        // Create pty
        masterFd = posix_openpt(O_RDWR)
        guard masterFd >= 0 else { fail("Internal error"); return }
        guard grantpt(masterFd) == 0, unlockpt(masterFd) == 0 else { fail("Internal error"); return }
        guard let sn = ptsname(masterFd) else { fail("Internal error"); return }
        slaveFd = open(String(cString: sn), O_RDWR)
        guard slaveFd >= 0 else { fail("Internal error"); return }

        // Disable echo so sent responses don't appear in output
        var term = termios()
        tcgetattr(slaveFd, &term)
        term.c_lflag &= ~UInt(ECHO)
        tcsetattr(slaveFd, TCSANOW, &term)

        // Free OAuth port if stuck from a previous attempt
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/bin/sh")
        k.arguments = ["-c", "lsof -ti :53682 | xargs kill -9 2>/dev/null; true"]
        k.standardOutput = FileHandle.nullDevice
        k.standardError = FileHandle.nullDevice
        try? k.run()
        k.waitUntilExit()

        // Run full interactive `rclone config`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath)
        proc.arguments = ["config"]
        proc.standardInput = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
        proc.standardOutput = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
        proc.standardError = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.phase = .done
                self?.succeeded = p.terminationStatus == 0
                self?.currentPrompt = nil
                self?.statusText = p.terminationStatus == 0 ? "Setup complete" : "Setup ended"
                self?.cleanup()
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            fail("Failed to launch rclone")
            return
        }

        // Read pty output
        let fd = masterFd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if let chunk = String(bytes: buf.prefix(n), encoding: .utf8) {
                    let clean = Self.stripAnsi(chunk)
                    DispatchQueue.main.async {
                        self?.onOutput(clean)
                    }
                }
            }
        }
    }

    // MARK: - Send Response

    func send(_ text: String) {
        guard masterFd >= 0 else { return }
        let data = (text + "\r").data(using: .utf8)!
        _ = data.withUnsafeBytes { write(masterFd, $0.baseAddress!, $0.count) }
        currentPrompt = nil
        buffer = "" // clear buffer so next prompt is parsed fresh
        statusText = "Working..."

        // Force a parse after a delay to catch the next prompt
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.processBuffer() }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        phase = .done
        succeeded = false
        cleanup()
        // Kill any lingering rclone config processes
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/bin/sh")
        k.arguments = ["-c", "lsof -ti :53682 | xargs kill -9 2>/dev/null; true"]
        k.standardOutput = FileHandle.nullDevice
        k.standardError = FileHandle.nullDevice
        try? k.run()
    }

    // MARK: - Output Processing

    private func onOutput(_ text: String) {
        // Token blobs freeze the UI — if we see one, we're done with OAuth
        if text.contains("access_token") || text.contains("refresh_token") || text.contains("token_type") {
            return
        }
        // Skip any massive chunk
        if text.count > 500 { return }
        buffer += text

        // Debounce: wait for rclone to finish outputting before parsing
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.processBuffer()
                // If no prompt found, retry in 1s (rclone might still be outputting)
                if self?.currentPrompt == nil && self?.phase == .interactive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.processBuffer()
                    }
                }
            }
        }
    }

    private func processBuffer() {
        let text = buffer

        // Debug: write buffer to file so we can see what's happening
        try? "phase=\(phase) step=\(autoNavStep)\n---\n\(text)\n".write(
            toFile: "/tmp/skyhook-debug.txt", atomically: true, encoding: .utf8)

        // Check if there's a prompt (line ending with "> ", ">", or "password:")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPrompt = text.contains("> ") || trimmed.hasSuffix(">") ||
            trimmed.hasSuffix(":")

        guard hasPrompt else { return }

        // Auto-navigation phase: silently send menu responses
        if phase == .autoNav {
            if isEditMode {
                // Edit flow: e -> select remote -> interactive
                if autoNavStep == 0 && (text.contains("e/n/d/r/c/s/q>") || text.contains("n/s/q>") || hasPrompt) {
                    buffer = ""
                    sendSilent("e")
                    autoNavStep = 1
                    return
                }
                if autoNavStep == 1 && (text.contains("remote>") || text.contains(autoNavName)) && hasPrompt {
                    buffer = ""
                    sendSilent(autoNavName)
                    autoNavStep = 3
                    phase = .interactive
                    statusText = "Edit \(autoNavName)"
                    return
                }
            } else {
                // Create flow: n -> name -> type -> interactive
                if autoNavStep == 0 && (text.contains("n/s/q>") || text.contains("e/n/d/r/c/s/q>") || text.contains("New remote")) {
                    buffer = ""
                    sendSilent("n")
                    autoNavStep = 1
                    return
                }
                if autoNavStep == 1 && text.contains("name>") {
                    buffer = ""
                    sendSilent(autoNavName)
                    autoNavStep = 2
                    return
                }
                if autoNavStep == 2 && (text.contains("Storage>") || text.contains("storage>") || text.contains("Type>")) {
                    buffer = ""
                    sendSilent(autoNavType)
                    autoNavStep = 3
                    phase = .interactive
                    statusText = "Configure your remote"
                    return
                }
                // Safety: if we see any prompt with ">" and step is 0, try sending n
                if autoNavStep == 0 && hasPrompt {
                    buffer = ""
                    sendSilent("n")
                    autoNavStep = 1
                    return
                }
            }
            // Past auto-nav
            if autoNavStep >= 3 {
                phase = .interactive
            }
        }

        // If OAuth completed ("Got code"), keep only text AFTER it for next prompt
        if text.contains("Got code") {
            if let range = text.range(of: "Got code") {
                buffer = String(text[range.upperBound...])
            } else {
                buffer = ""
            }
            currentPrompt = nil
            statusText = "Authorization successful, continuing setup..."
            // Re-parse immediately with remaining text
            processBuffer()
            return
        }

        // Interactive phase: parse prompt into GUI
        if phase == .interactive || phase == .autoNav {
            if let prompt = parsePrompt(text) {
                buffer = ""
                currentPrompt = prompt
            }
        }
    }

    // MARK: - Prompt Parsing

    private func parsePrompt(_ text: String) -> RclonePrompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // --- OAuth waiting ---
        if text.contains("Waiting for code") {
            var url = ""
            for line in lines {
                if line.contains("http://") || line.contains("https://") {
                    if let range = line.range(of: "http[s]?://[^ ]+", options: .regularExpression) {
                        url = String(line[range])
                    }
                }
            }
            return RclonePrompt(
                title: "Browser Authorization",
                helpText: "Complete the sign-in in your browser. SkyHook is waiting for the response.",
                control: .oauthWait(url: url)
            )
        }

        // --- y/n prompt ---
        if text.contains("y/n>") {
            let title = findTitle(lines)
            let help = findHelp(lines)
            let defaultYes = text.contains("y) Yes (default)") ||
                             text.contains("(Y/n)") ||
                             (!text.contains("n) No (default)") && text.contains("y) Yes"))
            return RclonePrompt(title: title, helpText: help, control: .yesNo(defaultYes: defaultYes))
        }

        // --- Letter-choice prompt (e.g. "e/n/d/r/c/s/q>") ---
        // Detect: prompt field is single letters separated by slashes
        var promptField = ""
        for line in lines.reversed() {
            if line.hasSuffix(">") || line.contains("> ") {
                promptField = line.replacingOccurrences(of: ">", with: "")
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        if !promptField.isEmpty {
            let parts = promptField.split(separator: "/")
            let isLetterMenu = parts.count >= 2 && parts.allSatisfy { $0.count <= 2 }

            if isLetterMenu {
                // Extract labels from "x) Label" lines above
                var choices: [(id: String, label: String)] = []
                for part in parts {
                    let key = String(part).trimmingCharacters(in: .whitespaces)
                    var label = key.uppercased()
                    // Find matching "x) Description" line
                    for line in lines {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("\(key))") || t.hasPrefix("\(key) )") {
                            label = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                    choices.append((id: key, label: label))
                }
                let title = findTitle(lines)
                let help = findHelp(lines)
                return RclonePrompt(title: title, helpText: help,
                                  control: .choices(items: choices, defaultId: ""))
            }
        }

        // --- Numbered choices ---
        var choices: [(id: String, label: String)] = []
        var defaultId = ""
        for i in 0..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineParts = trimmed.split(separator: " ", maxSplits: 2)
            if lineParts.count >= 3 && lineParts[1] == "/" {
                if let _ = Int(lineParts[0]) {
                    let num = String(lineParts[0])
                    let label = String(lineParts[2...].joined(separator: " "))
                    choices.append((id: num, label: label))
                }
            }
            if line.contains("default (") {
                if let s = line.range(of: "default (")?.upperBound,
                   let e = line[s...].firstIndex(of: ")") {
                    defaultId = String(line[s..<e])
                }
            }
        }

        if !choices.isEmpty {
            let title = findTitle(lines)
            let help = findHelp(lines)
            return RclonePrompt(title: title, helpText: help,
                              control: .choices(items: choices, defaultId: defaultId))
        }

        // --- Colon prompts (password:, Confirm password:, Enter verification code:, token:, etc.) ---
        if trimmed.hasSuffix(":") && !trimmed.contains(">") {
            let lower = trimmed.lowercased()
            let isSecret = lower.contains("password") || lower.contains("secret") || lower.contains("token")
            let lastLine = lines.last ?? trimmed
            let title = lastLine.hasSuffix(":") ? String(lastLine.dropLast()).trimmingCharacters(in: .whitespaces) : lastLine
            let help = findHelp(lines)
            return RclonePrompt(
                title: title.isEmpty ? "Enter value" : title,
                helpText: help,
                control: .textField(placeholder: "", defaultValue: "", isSecret: isSecret))
        }

        // --- Text input (fallback) ---
        if !promptField.isEmpty {
            let title = findTitle(lines)
            let help = findHelp(lines)
            var defaultVal = ""
            for line in lines {
                if line.contains("default (") || line.contains("default \"") {
                    if let s = line.range(of: "default (")?.upperBound ?? line.range(of: "default \"")?.upperBound {
                        let rest = line[s...]
                        if let e = rest.firstIndex(of: ")") ?? rest.firstIndex(of: "\"") {
                            defaultVal = String(rest[..<e])
                        }
                    }
                }
            }
            let isSecret = promptField.contains("pass") || promptField.contains("secret") ||
                           promptField.contains("token") || promptField.contains("key")
            return RclonePrompt(title: title, helpText: help,
                              control: .textField(placeholder: promptField, defaultValue: defaultVal, isSecret: isSecret))
        }

        return nil
    }

    private func findTitle(_ lines: [String]) -> String {
        for line in lines {
            if line.hasPrefix("Option ") {
                return String(line.dropFirst(7)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        // First meaningful line
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("*") && !t.hasPrefix("\\") && !t.contains(">") &&
               !t.hasPrefix("Enter") && !t.hasPrefix("Press") && !t.hasPrefix("NOTICE") &&
               !t.hasPrefix("Choose") && !t.hasPrefix("If not") && Int(String(t.prefix(1))) == nil {
                return t
            }
        }
        return "Configure"
    }

    private func findHelp(_ lines: [String]) -> String {
        var helpLines: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("*") || (t.count > 10 && !t.contains(">") && !t.hasPrefix("\\") &&
               !t.hasPrefix("Option") && Int(String(t.prefix(1))) == nil) {
                if !t.hasPrefix("Choose") && !t.hasPrefix("Press Enter") && !t.hasPrefix("Enter a") {
                    helpLines.append(t)
                }
            }
        }
        return helpLines.prefix(3).joined(separator: "\n")
    }

    // MARK: - Helpers

    private func sendSilent(_ text: String) {
        guard masterFd >= 0 else { return }
        let data = (text + "\r").data(using: .utf8)!
        _ = data.withUnsafeBytes { write(masterFd, $0.baseAddress!, $0.count) }
    }

    private func fail(_ msg: String) {
        phase = .done
        succeeded = false
        statusText = msg
        cleanup()
    }

    private func cleanup() {
        debounceTimer?.invalidate()
        if slaveFd >= 0 { close(slaveFd); slaveFd = -1 }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
    }

    nonisolated static func stripAnsi(_ s: String) -> String {
        var result = ""
        var skip = false
        for c in s {
            if c == "\u{1B}" { skip = true; continue }
            if skip { if c.isLetter { skip = false }; continue }
            if c != "\r" { result.append(c) }
        }
        return result
    }

    deinit {
        if slaveFd >= 0 { close(slaveFd) }
        if masterFd >= 0 { close(masterFd) }
    }
}

// MARK: - Setup View (Pure GUI — no terminal text)

struct SetupView: View {
    @ObservedObject var session: SetupSession
    @State private var textInput = ""
    let onDone: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Main content
            VStack {
                Spacer()
                content
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(24)

            Divider()
            footer
        }
        .frame(width: 480, height: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Setup")
                    .font(.headline)
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.phase == .autoNav || (session.phase == .interactive && session.currentPrompt == nil) {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .starting, .autoNav:
            VStack(spacing: 12) {
                ProgressView()
                Text("Setting up...")
                    .foregroundStyle(.secondary)
            }

        case .interactive:
            if let prompt = session.currentPrompt {
                promptView(prompt)
                    .id(prompt.id)
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading next option...")
                        .foregroundStyle(.secondary)
                }
            }

        case .done:
            VStack(spacing: 16) {
                Image(systemName: session.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(session.succeeded ? .green : .red)
                Text(session.succeeded ? "Remote configured successfully" : "Setup was cancelled")
                    .font(.title3.weight(.medium))
            }
        }
    }

    private var footer: some View {
        HStack {
            if session.phase != .done {
                Button("Cancel") {
                    session.cancel()
                    onDone(false)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.phase == .done {
                Button("Done") { onDone(session.succeeded) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Prompt Controls

    @ViewBuilder
    private func promptView(_ prompt: RclonePrompt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text(prompt.title)
                .font(.title3.weight(.semibold))

            // Help
            if !prompt.helpText.isEmpty {
                Text(prompt.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Control
            switch prompt.control {
            case .yesNo(let defaultYes):
                HStack(spacing: 12) {
                    bigButton("Yes", icon: "checkmark.circle.fill", primary: defaultYes) {
                        session.send("y")
                    }
                    bigButton("No", icon: "xmark.circle.fill", primary: !defaultYes) {
                        session.send("n")
                    }
                }

            case .choices(let items, let defaultId):
                VStack(spacing: 8) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(items, id: \.id) { item in
                                Button { session.send(item.id) } label: {
                                    HStack {
                                        Text(item.label)
                                            .font(.system(size: 13))
                                        Spacer()
                                        if item.id == defaultId || items.first(where: { $0.label.lowercased().contains(defaultId.lowercased()) })?.id == item.id {
                                            Text("default")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.blue.opacity(0.1), in: Capsule())
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 200)

                    skipButton(defaultId: defaultId)
                }

            case .textField(let placeholder, let defaultValue, let isSecret):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Group {
                            if isSecret {
                                SecureField(placeholder, text: $textInput)
                            } else {
                                TextField(placeholder, text: $textInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitText() }

                        Button("OK") { submitText() }
                            .buttonStyle(.borderedProminent)
                    }

                    if !defaultValue.isEmpty {
                        Button("Use default: \(defaultValue)") {
                            session.send("")
                            textInput = ""
                        }
                        .font(.caption)
                        .foregroundStyle(.blue)
                    } else {
                        Button("Skip — leave empty") {
                            session.send("")
                            textInput = ""
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

            case .oauthWait(let url):
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Complete sign-in in your browser")
                        .font(.subheadline.weight(.medium))
                    Text("SkyHook is waiting for authorization...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !url.isEmpty {
                        Button("Open browser manually") {
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func skipButton(defaultId: String = "") -> some View {
        Button {
            session.send(defaultId.isEmpty ? "" : defaultId)
            textInput = ""
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 9))
                Text(defaultId.isEmpty ? "Skip" : "Skip — use default")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func bigButton(_ label: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(primary ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(primary ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func submitText() {
        session.send(textInput)
        textInput = ""
    }
}
