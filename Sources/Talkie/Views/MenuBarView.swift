import SwiftUI
import AppKit
import TalkieCore

struct MenuBarView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("talkie · \(store.displayPhase)")
        if store.active?.kind == .meeting {
            Button(store.isPaused ? "Resume Meeting" : "Pause Meeting") { store.pauseResume() }
            Button("Stop Meeting") { store.stopRecording() }.disabled(store.isBusy)
        } else { Button(store.recording ? "Stop Dictation" : "Start Dictation") { store.toggleDictation() }.disabled(store.isBusy) }
        Text(store.preferences.shortcutTitle).font(.caption)
        Picker("Language", selection: Binding(get: { store.preferences.language }, set: { store.preferences.language = $0 })) {
            ForEach(RecognitionLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Auto Insert", isOn: Binding(get: { store.preferences.autoInsert }, set: { store.preferences.autoInsert = $0 }))
        Toggle("AI Cleanup", isOn: Binding(get: { store.preferences.cleanupEnabled }, set: { store.preferences.cleanupEnabled = $0 }))
        if store.dictation.hasRecovery {
            Button(store.dictation.recoveryUncertain ? "Check Last Insertion…" : "Recover Dictation…") { store.dictation.showRecovery() }
        }
        if store.hasPendingClipboardRestore { Button("Restore Previous Clipboard") { store.restorePreviousClipboard() } }
        Divider()
        Button("Open Meetings") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit talkie") { DispatchQueue.main.async { NSApp.terminate(nil) } }.keyboardShortcut("q")
    }
}
