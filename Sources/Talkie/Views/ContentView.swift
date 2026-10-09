import SwiftUI
import TalkieCore

struct ContentView: View {
    @Bindable var store: AppStore
    private enum Destination: Hashable { case area(String), session(UUID) }
    private var selection: Binding<Destination?> { Binding(get: { store.selectedID.map(Destination.session) ?? .area(store.area) }, set: { value in
        switch value { case .area(let area): store.area = area; store.selectedID = nil
        case .session(let id): store.selectedID = id; store.area = "Meetings"
        case nil: break }
    }) }
    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    Label("Meetings", systemImage: "person.2").tag(Destination.area("Meetings"))
                }
                Section("Meetings") {
                    ForEach(store.sessions) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).lineLimit(1)
                            Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }.tag(Destination.session(session.id))
                    }
                }
            }.listStyle(.sidebar).navigationTitle("talkie").navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if store.active != nil { RecordingControlsView(store: store).padding().background(.bar) }
                if let session = store.selected { SessionDetailView(store: store, session: session).id(session.id) }
                else { MeetingSetupView(store: store) }
                Divider()
                HStack(spacing: 10) {
                    Circle().fill(store.recording ? .orange : .secondary).frame(width: 6, height: 6)
                    Text(store.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    if store.isBusy { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() }.controlSize(.small) }
                }.padding(12)
            }.navigationTitle(store.selected?.title ?? store.area)
                .toolbar { ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } } }
        }
    }
}
struct RecordingControlsView: View {
    @Bindable var store: AppStore
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "record.circle.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.phase) · \(TranscriptExporter.timestamp(store.elapsed))").font(.headline).monospacedDigit()
                Text(store.captureScope).font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(store.active?.sources ?? [], id: \.self) { source in
                        Text(source.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(store.levels[source] ?? 0)).frame(width: 60)
                    }
                }
            }
            Spacer()
            if store.active?.kind == .meeting {
                Button(store.microphoneMuted ? "Unmute Recorder Mic" : "Mute Recorder Mic") { store.muteMicrophone() }.disabled(store.isBusy)
                Button(store.isPaused ? "Resume" : "Pause") { store.pauseResume() }.disabled(store.isBusy)
            }
            Button("Stop", systemImage: "stop.fill") { store.stopRecording() }.buttonStyle(.borderedProminent).tint(.orange).disabled(store.isBusy)
        }
    }
}
