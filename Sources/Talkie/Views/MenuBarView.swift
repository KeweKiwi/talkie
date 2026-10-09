import SwiftUI
import AppKit

struct MenuBarView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("talkie · \(store.phase)")
        if store.active?.kind == .meeting {
            Button(store.isPaused ? "Resume Meeting" : "Pause Meeting") { store.pauseResume() }
            Button("Stop Meeting") { store.stopRecording() }.disabled(store.isBusy)
        } else { Button(store.recording ? "Stop Dictation" : "Start Dictation") { store.toggleDictation() }.disabled(store.isBusy) }
        Toggle("AI Cleanup", isOn: Binding(get: { store.preferences.cleanupEnabled }, set: { store.preferences.cleanupEnabled = $0 }))
        Divider()
        Button("Open talkie") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit talkie") { DispatchQueue.main.async { NSApp.terminate(nil) } }.keyboardShortcut("q")
    }
}
