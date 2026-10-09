import SwiftUI
import TalkieCore

struct DictationView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundStyle(.orange)
                    Text("Your voice, in your words.").font(.largeTitle.weight(.semibold))
                    Text("Dictate in Bahasa Indonesia, English, or a mix of both. Transcription runs on this Mac.").font(.title3).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label(store.phase, systemImage: "mic").font(.headline)
                            Spacer()
                            Text(store.preferences.language.title).foregroundStyle(.secondary)
                        }
                        Text("Press \(store.preferences.shortcutTitle) in your editor to start and stop. Customize the shortcut or enable push-to-talk in Settings.")
                        Button("Start Dictation", systemImage: "mic.fill") { store.toggleDictation() }.buttonStyle(.borderedProminent).tint(.orange).disabled(store.isBusy || store.recording)
                        Text("Starting here produces a preview. The global shortcut can insert into a verified editable field.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                @Bindable var preferences = store.preferences
                Toggle("AI Cleanup \(preferences.cleanupEnabled ? "ON" : "OFF")", isOn: $preferences.cleanupEnabled).toggleStyle(.switch)
                Text(preferences.cleanupEnabled ? "A local editor improves readability. Review its output before copying. Original ASR is always kept." : "Returns raw ASR without an editor model. ASR itself may add punctuation or normalize speech.").foregroundStyle(.secondary)
                if !store.speechModelInstalled {
                    Label("Install the multilingual speech model in Settings. Recording can still save audio for later transcription.", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 32) {
                    Label("Offline after model setup", systemImage: "wifi.slash")
                    Label("No subscription or API fees", systemImage: "checkmark.seal")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(36).frame(maxWidth: 800, alignment: .leading)
        }
    }
}
