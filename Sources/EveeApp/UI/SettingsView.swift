import AppKit
import EveeCore
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var newAppName = ""
    @State private var newBundleIdentifier = ""
    @State private var newAppTone: WritingTone = .natural
    @State private var selectedModelReady = false
    @State private var integrationMessage: String?

    var body: some View {
        Form {
            Section("Dictation") {
                KeyboardShortcuts.Recorder("Push to talk:", name: .pushToTalk)
                KeyboardShortcuts.Recorder("Transform selection:", name: .transformSelection)
                Picker("Local model", selection: $store.settings.model) {
                    ForEach(SpeechModel.allCases, id: \.self) { model in Text(model.title).tag(model) }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.settings.model.detail).font(.caption).foregroundStyle(.secondary)
                        if let progress = store.modelProgress {
                            ProgressView(value: progress.fraction) { Text(progress.status) }.frame(maxWidth: 280)
                        }
                    }
                    Spacer()
                    Button(selectedModelReady ? "Downloaded" : "Download") {
                        Task { await store.downloadSelectedModel() }
                    }
                    .disabled(selectedModelReady || store.modelProgress != nil)
                }
                Picker("Language", selection: $store.settings.languageCode) {
                    Text("Automatic").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("Japanese").tag("ja")
                }
                Picker("Default writing style", selection: $store.settings.defaultTone) {
                    ForEach(WritingTone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("After dictation", selection: $store.settings.textDeliveryMode) {
                    ForEach(TextDeliveryMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(store.settings.textDeliveryMode.detail)
                    .font(.caption)
                    .foregroundStyle(store.settings.textDeliveryMode == .pasteAndSend ? .orange : .secondary)
                Text("Selection transform is local and deterministic in this build: concise, clean up, case changes, lists, and ‘replace … with …’. Unsupported generative rewrites leave the selection unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Microphone", value: "System default")
                Text("Input-device selection is not available in this build. Evee follows the macOS system input device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-app writing") {
                if store.settings.appStyles.isEmpty {
                    Text("Add an app to give it a different tone, punctuation or paragraph style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($store.settings.appStyles) { $style in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("App name", text: $style.displayName)
                            Text(style.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { removeStyle(id: style.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this app style")
                        }
                        HStack {
                            Picker("Tone", selection: $style.tone) {
                                ForEach(WritingTone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            Toggle("Final punctuation", isOn: $style.appendPeriod)
                            Toggle("Paragraphs", isOn: $style.useParagraphs)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    TextField("App name", text: $newAppName)
                    TextField("Bundle identifier (for example com.apple.mail)", text: $newBundleIdentifier)
                    Picker("Tone", selection: $newAppTone) {
                        ForEach(WritingTone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    Button("Add", action: addStyle)
                        .disabled(trimmedBundleIdentifier.isEmpty || newAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Privacy and storage") {
                Toggle("Capture system audio in meetings", isOn: $store.settings.meetingCaptureEnabled)
                Toggle("Separate anonymous meeting speakers", isOn: $store.settings.meetingDiarizationEnabled)
                    .disabled(!store.settings.meetingCaptureEnabled)
                Toggle("Retain dictation audio", isOn: $store.settings.retainDictationAudio)
                Toggle("Retain memo audio for playback", isOn: $store.settings.retainMemoAudio)
                Toggle("Retain meeting audio", isOn: $store.settings.retainMeetingAudio)
                Toggle("Store app and window context with dictations", isOn: $store.settings.retainContextMetadata)
                Toggle("Store original selected text for transforms", isOn: $store.settings.retainSelectedText)
                Text("Context is captured in memory to guard delivery. Long-term app/window metadata and original selected text are off by default and controlled separately. Password and protected fields are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("System-audio meeting capture is off by default and requires Screen & System Audio Recording permission. Audio retention is controlled separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Anonymous speaker separation is off by default. Enabling it downloads and runs an additional local model when a meeting is processed; speaker names are never inferred.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Transcripts and preferences stay under Application Support/Evee. Dictation and meeting audio retention is off by default; memo audio is retained for playback. Failed transcriptions keep recoverable audio until you transcribe or discard it, while cancelled captures are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Automatic history expiry is not available yet. Delete individual records from the workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local API") {
                Toggle("Enable loopback API", isOn: $store.settings.localAPIEnabled)
                if store.settings.localAPIEnabled {
                    TextField("Port", value: $store.settings.localAPIPort, format: .number)
                    LabeledContent("Endpoint", value: store.localAPICredentials?.baseURL.absoluteString ?? "Available after Save")
                    HStack {
                        SecureField("API token", text: .constant(store.localAPICredentials?.token ?? ""))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Copy") { copy(store.localAPICredentials?.token ?? "") }
                            .disabled(store.localAPICredentials == nil)
                        Button("Rotate", action: store.rotateLocalAPIToken)
                            .disabled(store.localAPICredentials == nil)
                        Button("Revoke", role: .destructive) { Task { await store.revokeLocalAPIAccess() } }
                            .disabled(store.localAPICredentials == nil)
                    }
                    Text("Save to publish a token. The API is read-only, accepts connections from this Mac only, and stores its token in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Meeting webhook URL", text: $store.settings.webhookURL)
                SecureField("Webhook signing secret", text: $store.webhookSecret)
                if store.webhookOutboxCount > 0 {
                    HStack {
                        Text("\(store.webhookOutboxCount) undelivered webhook \(store.webhookOutboxCount == 1 ? "item" : "items")")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Retry now") { Task { await store.retryWebhookDeliveriesNow() } }
                    }
                }
                Text("Webhook secrets are stored in Keychain. HTTPS is required except for localhost development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("MCP") {
                Text("Register Evee with Claude Desktop so local agents can search your voice workspace. Registration only changes Claude's local MCP configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Register with Claude Desktop", action: registerMCP)
                    if let integrationMessage {
                        Text(integrationMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Local activity context") {
                WorkspaceIntelligencePrivacyView()
            }

            Section("Application") {
                LaunchAtLogin.Toggle()
                Text("Audio cues and wake-word mode are not available in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save settings") { Task { await store.saveSettings() } }
                    .buttonStyle(AlphaButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AnimaTheme.paper)
        .task { refreshModelState() }
        .onChange(of: store.settings.model) { _, _ in refreshModelState() }
        .onChange(of: store.modelReady) { _, ready in selectedModelReady = ready }
    }

    private var trimmedBundleIdentifier: String {
        newBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addStyle() {
        let identifier = trimmedBundleIdentifier
        guard !identifier.isEmpty,
              !store.settings.appStyles.contains(where: { $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            integrationMessage = "That app already has a style."
            return
        }
        store.settings.appStyles.append(AppWritingStyle(
            bundleIdentifier: identifier,
            displayName: newAppName.trimmingCharacters(in: .whitespacesAndNewlines),
            tone: newAppTone
        ))
        newAppName = ""
        newBundleIdentifier = ""
        newAppTone = .natural
    }

    private func removeStyle(id: String) {
        store.settings.appStyles.removeAll { $0.id == id }
    }

    private func refreshModelState() {
        selectedModelReady = (try? TranscriberFactory.make(store.settings.model).isDownloaded) == true
    }

    private func registerMCP() {
        let mcpURL = MCPRegistration.bundledExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: mcpURL.path) else {
            integrationMessage = "The MCP helper is not bundled in this installation."
            return
        }
        do {
            try MCPRegistration.writeClaudeDesktopConfiguration(executablePath: mcpURL.path)
            integrationMessage = "Registered. Restart Claude Desktop to connect."
        } catch {
            integrationMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
