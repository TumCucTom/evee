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
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var newLinkPhrase = ""
    @State private var newLinkDestination = ""

    var body: some View {
        Form {
            Section("Dictation") {
                KeyboardShortcuts.Recorder("Push to talk:", name: .pushToTalk)
                KeyboardShortcuts.Recorder("Hands-free toggle:", name: .toggleHandsFree)
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
                    ForEach(SupportedLanguage.all) { language in
                        Text(language.name).tag(language.code)
                    }
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
                Picker("Microphone", selection: $store.settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in Text(device.name).tag(device.uid) }
                }
                Toggle("Low-latency microphone buffering", isOn: $store.settings.lowLatencyMode)
                Text("The selected input and latency mode take effect on the next capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Writing enhancements") {
                Picker("Email formatting", selection: $store.settings.emailFormattingMode) {
                    ForEach(EmailFormattingMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                TextField("Email sign-off name (optional)", text: $store.settings.emailSignOff)
                Toggle("Learn simple corrections from edited dictations", isOn: $store.settings.learnCorrections)
                Text("Learning is opt-in and accepts only one-word substitutions. Learned terms appear in Dictionary where you can review or remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !store.settings.smartLinks.isEmpty {
                    ForEach(store.settings.smartLinks) { link in
                        HStack {
                            Text(link.phrase).font(.callout.weight(.medium))
                            Image(systemName: "arrow.right")
                            Text(link.destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                store.settings.smartLinks.removeAll { $0.id == link.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove smart link for \(link.phrase)")
                        }
                    }
                }
                HStack {
                    TextField("Spoken phrase", text: $newLinkPhrase)
                    TextField("https://destination.example", text: $newLinkDestination)
                    Button("Add", action: addSmartLink)
                        .disabled(!validNewLink)
                }
                Text("Smart links replace an exact spoken phrase with its web address locally. Only HTTP and HTTPS destinations are accepted.")
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
                Toggle("Show a live local transcript while recording", isOn: $store.settings.liveMeetingTranscriptionEnabled)
                    .disabled(store.settings.model != .parakeet)
                HStack {
                    Toggle("Separate anonymous meeting speakers", isOn: $store.settings.meetingDiarizationEnabled)
                        .disabled(!store.settings.meetingCaptureEnabled)
                    Spacer()
                    if store.meetingDiarizationReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button(store.isPreparingMeetingDiarization ? "Preparing…" : "Prepare model") {
                            Task { await store.prepareMeetingDiarization() }
                        }
                        .disabled(
                            !store.settings.meetingCaptureEnabled ||
                            !store.settings.meetingDiarizationEnabled ||
                            store.isPreparingMeetingDiarization ||
                            store.captureState != .idle
                        )
                    }
                }
                Toggle("Retain dictation audio", isOn: $store.settings.retainDictationAudio)
                Toggle("Retain memo audio for playback", isOn: $store.settings.retainMemoAudio)
                Toggle("Retain meeting audio", isOn: $store.settings.retainMeetingAudio)
                Picker("Delete workspace records after", selection: $store.settings.historyRetentionDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Toggle("Store app and window context with dictations", isOn: $store.settings.retainContextMetadata)
                Toggle("Store original selected text for transforms", isOn: $store.settings.retainSelectedText)
                Toggle("Capture and store visible accessibility text", isOn: $store.settings.captureVisibleContext)
                Text("Context is captured only as needed for guarded delivery and optional formatting. Long-term metadata, selected text and visible accessibility text are off by default and controlled separately. Password and protected fields are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("System-audio meeting capture is off by default, captures all Mac audio except Evee, and requires Screen & System Audio Recording permission. Pause unrelated media and notifications. Audio retention is controlled separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Anonymous speaker separation is off by default and uses an additional local model. Prepare it before a meeting to avoid a download while processing. If separation is unavailable, Evee still saves the transcript with honest channel labels; speaker names are never inferred.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Transcripts and preferences stay under Application Support/Evee. Dictation and meeting audio retention is off by default; memo audio is retained for playback. Failed transcriptions keep recoverable audio until you transcribe or discard it, while cancelled captures are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export JSON") { Task { await store.exportWorkspace(format: .json) } }
                    Button("Export Markdown") { Task { await store.exportWorkspace(format: .markdown) } }
                    Spacer()
                    Text("Exports omit retry payload bodies and never include Keychain secrets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        Button("Cancel outbox", role: .destructive) { Task { await store.cancelWebhookOutbox() } }
                    }
                }
                Text("Webhook secrets are stored in Keychain. HTTPS is required except for localhost development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("MCP") {
                Text("Register Evee with detected local MCP clients so local agents can search your voice workspace. Existing server entries are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Register detected clients", action: registerMCP)
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
                Toggle("Play capture audio cues", isOn: $store.settings.audioCuesEnabled)
                Toggle("Listen locally for a wake phrase", isOn: $store.settings.hotMicEnabled)
                    .disabled(store.settings.model != .parakeet)
                if store.settings.hotMicEnabled {
                    TextField("Wake phrase", text: $store.settings.wakePhrase)
                    LabeledContent("Wake listener", value: store.hotMicActive ? "Active" : "Starts after Save")
                }
                Text("Audio cues mark recording start, processing, completion and errors. Wake-phrase listening is off by default, keeps audio in memory, uses the selected microphone and releases it before normal dictation begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(store.isCheckingForUpdates ? "Checking…" : "Check for updates") {
                        Task { await store.checkForUpdates() }
                    }
                    .disabled(store.isCheckingForUpdates)
                    if let update = store.availableUpdate {
                        Link("Open Evee \(update.version) release", destination: update.pageURL)
                    }
                    Button("Export diagnostics") { Task { await store.exportDiagnostics() } }
                }
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
        .task {
            refreshModelState()
            inputDevices = AudioInputDevices.available()
        }
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

    private var validNewLink: Bool {
        guard !newLinkPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: newLinkDestination.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private func addSmartLink() {
        guard validNewLink else { return }
        store.settings.smartLinks.append(SmartLink(
            phrase: newLinkPhrase.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: newLinkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        newLinkPhrase = ""
        newLinkDestination = ""
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
            let results = try MCPRegistration.writeDetectedClientConfigurations()
            integrationMessage = "Registered \(results.count) \(results.count == 1 ? "client" : "clients"). Restart them to connect."
        } catch {
            integrationMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return }
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
        }
    }
}
