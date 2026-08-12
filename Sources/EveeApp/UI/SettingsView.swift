import EveeCore
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Dictation") {
                KeyboardShortcuts.Recorder("Push to talk:", name: .pushToTalk)
                Picker("Local model", selection: $store.settings.model) {
                    ForEach(SpeechModel.allCases, id: \.self) { model in Text(model.title).tag(model) }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text(store.settings.model.detail).font(.caption).foregroundStyle(.secondary)
                        if let progress = store.modelProgress { ProgressView(value: progress.fraction) { Text(progress.status) }.frame(maxWidth: 260) }
                    }
                    Spacer()
                    Button(store.modelReady ? "Downloaded" : "Download") { Task { await store.downloadSelectedModel() } }.disabled(store.modelReady)
                }
                Picker("Language", selection: $store.settings.languageCode) {
                    Text("Automatic").tag("auto"); Text("English").tag("en"); Text("French").tag("fr"); Text("German").tag("de"); Text("Spanish").tag("es"); Text("Japanese").tag("ja")
                }
                Picker("Default writing style", selection: $store.settings.defaultTone) {
                    ForEach(WritingTone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }

            Section("Privacy and storage") {
                Toggle("Retain dictation audio", isOn: $store.settings.retainDictationAudio)
                Toggle("Retain meeting audio", isOn: $store.settings.retainMeetingAudio)
                Text("Transcripts and preferences stay under Application Support/Evee. Audio retention is off by default.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Local integrations") {
                Toggle("Enable loopback API", isOn: $store.settings.localAPIEnabled)
                if store.settings.localAPIEnabled { TextField("Port", value: $store.settings.localAPIPort, format: .number) }
                TextField("Meeting webhook URL", text: $store.settings.webhookURL)
                SecureField("Webhook signing secret", text: $store.settings.webhookSecret)
            }

            Section("Application") { LaunchAtLogin.Toggle() }

            HStack { Spacer(); Button("Save settings") { Task { await store.saveSettings() } }.buttonStyle(AlphaButtonStyle()) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AnimaTheme.paper)
    }
}
