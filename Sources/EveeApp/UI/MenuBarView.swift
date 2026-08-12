import EveeCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { AlphaMark(size: 24); Text("Evee").font(.headline); Spacer(); Text(status).font(.caption).foregroundStyle(.secondary) }
            Divider()
            if case .recording = store.captureState {
                Button("Stop recording") { Task { await store.finishCapture() } }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button("Start dictation") { Task { await store.beginDictation() } }.buttonStyle(.borderedProminent).tint(AnimaTheme.indigo)
                Button("Record meeting") { Task { await store.beginMeeting() } }
                Button("Record memo") { Task { await store.beginMemo() } }
            }
            Divider()
            Text("Hold ⌥⌘Space in any app").font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(width: 260)
    }

    private var status: String { switch store.captureState { case .idle: "Ready"; case .recording: "Recording"; case .transcribing: "Transcribing"; case .delivering: "Pasting"; case .failed: "Error" } }
}
