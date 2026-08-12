import EveeCore
import SwiftUI

struct MeetingWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meetings").font(.system(size: 22, weight: .bold))
                    Text("Bot-free local capture and notes").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .recording = store.captureState {
                    Button("Stop and transcribe") { Task { await store.finishCapture() } }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { Task { await store.beginMeeting() } } label: { Label("Record meeting", systemImage: "record.circle") }.buttonStyle(AlphaButtonStyle())
                }
            }.padding(20)

            if case .recording = store.captureState {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text("Recording microphone").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("No meeting bot").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Meeting title", text: $store.meetingTitle).textFieldStyle(.roundedBorder)
                    TextEditor(text: $store.meetingNotes).frame(minHeight: 230).scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if store.meetingNotes.isEmpty { Text("Take notes while Evee listens…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
                        }
                }.animaCard().padding(20)
            } else {
                LibraryView(title: "Past meetings", kind: .meeting)
            }
        }.background(AnimaTheme.paper)
    }
}
