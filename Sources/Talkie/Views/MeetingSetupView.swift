import SwiftUI

struct MeetingSetupView: View {
    @Bindable var store: AppStore
    @State private var title = ""
    @State private var includeSystem = false
    @State private var consent = false
    @State private var application: Int32 = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Keep the whole conversation.").font(.largeTitle.weight(.semibold))
                Text("Record deliberately. Save a complete timestamped transcript, then export it or summarize locally.").font(.title3).foregroundStyle(.secondary)
                Form {
                    TextField("Meeting title", text: $title, prompt: Text("Weekly planning"))
                    Toggle("Include system / application audio", isOn: $includeSystem)
                    if includeSystem {
                        Picker("Capture scope", selection: $application) {
                            Text("All system audio").tag(Int32(0))
                            ForEach(store.applications, id: \.pid) { app in Text(app.name).tag(app.pid) }
                        }
                        Button("Refresh Applications") { store.refreshApplications() }
                        Text("Application capture includes its audio across windows and browser tabs. Headphones reduce speaker echo. ScreenCaptureKit saves only audio; microphone and system are separate sources.").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Uses the Mac’s default microphone. Change the input in System Settings → Sound.").font(.caption).foregroundStyle(.secondary) }
                }.formStyle(.grouped)
                Toggle("I have permission from the participants to record this meeting.", isOn: $consent)
                Text("macOS capture permission does not establish participant consent. No meeting is recorded automatically.").font(.caption).foregroundStyle(.secondary)
                Button("Start Meeting", systemImage: "record.circle") { store.startMeeting(title: title, includeSystem: includeSystem, application: application == 0 ? nil : application) }.buttonStyle(.borderedProminent).tint(.orange).disabled(!consent || store.isBusy || store.recording)
                Text("Audio is saved in bounded chunks. Pause, recorder microphone mute, and Stop remain available during recording. Dictation is unavailable while a meeting records.").foregroundStyle(.secondary)
            }.padding(36).frame(maxWidth: 800, alignment: .leading)
        }.onAppear { store.refreshApplications() }
    }
}
