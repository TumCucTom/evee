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
    @State private var mcpInspections: [MCPClientRegistrationInspection] = []
    @State private var selectedMCPClientIDs: Set<String> = []
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
                Text("Local helper access lets the selected apps search your Evee workspace. It is off by default and can be revoked at any time without changing unrelated client settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mcpInspections.isEmpty {
                    Text("No supported local clients were detected. Evee will not create a fallback configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mcpInspections) { inspection in
                        HStack(alignment: .top) {
                            if inspection.disposition == .unregistered {
                                Toggle(isOn: mcpSelectionBinding(for: inspection.client)) {
                                    mcpClientLabel(inspection)
                                }
                                .disabled(store.settings.mcpEnabled)
                            } else {
                                mcpClientLabel(inspection)
                            }
                            Spacer()
                            if !store.settings.mcpEnabled, inspection.disposition == .recognizedLegacy {
                                Button("Adopt") {
                                    Task { await adoptMCP(inspection.client) }
                                }
                                .accessibilityLabel("Adopt existing Evee registration for \(inspection.client.name)")
                                Button("Remove", role: .destructive) {
                                    Task { await removeLegacyMCP(inspection.client) }
                                }
                                .accessibilityLabel("Remove existing Evee registration from \(inspection.client.name)")
                            }
                        }
                    }
                }
                HStack {
                    if store.settings.mcpEnabled {
                        Label("Local helper access enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Revoke access", role: .destructive) {
                            Task { await revokeMCP() }
                        }
                    } else {
                        Button("Enable selected clients") {
                            Task { await registerMCP() }
                        }
                        .disabled(selectedMCPClientIDs.isEmpty)
                    }
                }
                if let integrationMessage {
                    Text(integrationMessage).font(.caption).foregroundStyle(.secondary)
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
            await refreshMCPClients()
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

    private func refreshMCPClients() async {
        do {
            mcpInspections = try await store.inspectLocalHelperClients()
            selectedMCPClientIDs = Set(
                mcpInspections
                    .filter { $0.disposition == .unregistered }
                    .map(\.client.id)
            )
        } catch {
            mcpInspections = []
            selectedMCPClientIDs = []
            integrationMessage = "Client registration scan failed without changing any configuration: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func mcpClientLabel(_ inspection: MCPClientRegistrationInspection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(inspection.client.name)
            Text(inspection.client.configurationURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            switch inspection.disposition {
            case .unregistered:
                Text("No Evee entry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ownedCurrent:
                Text("Owned Evee registration")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .recognizedLegacy:
                Text("Existing Evee entry — adopt it or remove it")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .ambiguous:
                Text("Manual or ambiguous Evee entry — review this file manually")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func mcpSelectionBinding(for client: MCPClientConfiguration) -> Binding<Bool> {
        Binding(
            get: { selectedMCPClientIDs.contains(client.id) },
            set: { selected in
                if selected {
                    selectedMCPClientIDs.insert(client.id)
                } else {
                    selectedMCPClientIDs.remove(client.id)
                }
            }
        )
    }

    private func registerMCP() async {
        let mcpURL = MCPRegistration.bundledExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: mcpURL.path) else {
            integrationMessage = "The MCP helper is not bundled in this installation."
            return
        }
        let selected = mcpInspections
            .filter { $0.disposition == .unregistered && selectedMCPClientIDs.contains($0.client.id) }
            .map(\.client)
        guard !selected.isEmpty else { return }
        do {
            let results = try await store.enableLocalHelperAccess(for: selected)
            integrationMessage = "Enabled \(results.count) \(results.count == 1 ? "client" : "clients"). Restart them to connect."
        } catch {
            integrationMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func adoptMCP(_ client: MCPClientConfiguration) async {
        do {
            _ = try await store.adoptLegacyLocalHelperAccess(for: [client])
            integrationMessage = "Adopted the existing Evee entry for \(client.name). Revoking access will remove that entry rather than restore it."
            await refreshMCPClients()
        } catch {
            integrationMessage = "Adoption failed without authorizing the helper: \(error.localizedDescription)"
        }
    }

    private func removeLegacyMCP(_ client: MCPClientConfiguration) async {
        do {
            let outcome = try await store.removeLegacyLocalHelperRegistrations(for: [client])
            integrationMessage = outcome.cleanupFailures.isEmpty
                ? "Removed the recognized Evee entry from \(client.name) and preserved its other settings."
                : "Local helper access remains disabled, but the client entry needs manual cleanup."
            await refreshMCPClients()
        } catch {
            integrationMessage = "Removal failed without changing an ambiguous entry: \(error.localizedDescription)"
        }
    }

    private func revokeMCP() async {
        do {
            let outcome = try await store.revokeLocalHelperAccess()
            let removed = outcome.removals.filter(\.removedRegistration).count
            if !outcome.authorizationDisabled {
                integrationMessage = outcome.cleanupFailures.isEmpty
                    ? "Local helper access remains enabled because the setting could not be saved."
                    : "Local helper access remains enabled. Registration recovery needs manual cleanup."
            } else if outcome.cleanupFailures.isEmpty, outcome.cleanupWarnings.isEmpty {
                integrationMessage = removed == 0
                    ? "Local helper access is disabled. No owned client registrations were present."
                    : "Local helper access is disabled. Removed \(removed) owned \(removed == 1 ? "client entry" : "client entries"). Restart those clients to disconnect."
            } else {
                let cleanupCount = outcome.cleanupWarnings.count + outcome.cleanupFailures.count
                integrationMessage = "Local helper access is disabled. Removed \(removed) owned \(removed == 1 ? "client entry" : "client entries"); \(cleanupCount) \(cleanupCount == 1 ? "item needs" : "items need") manual cleanup."
            }
            await refreshMCPClients()
        } catch {
            integrationMessage = store.settings.mcpEnabled
                ? "Local helper access remains enabled because the setting could not be saved: \(error.localizedDescription)"
                : "Local helper access is disabled, but registration cleanup failed: \(error.localizedDescription)"
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
