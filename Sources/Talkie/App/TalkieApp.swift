import SwiftUI
import AppKit

@main struct TalkieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore(registerShortcut: !CommandLine.arguments.contains("--self-test"))
    var body: some Scene {
        let _ = connectDelegate()
        Window("Meetings", id: "main") { ContentView(store: store).onAppear { delegate.store = store }.frame(minWidth: 900, minHeight: 630) }
            .defaultSize(width: 1060, height: 740)
            .defaultLaunchBehavior(.suppressed)
            .commands { CommandGroup(after: .newItem) {
                Button("Start / Stop Dictation") { store.toggleDictation() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Cancel Processing") { store.cancel() }.disabled(!store.isBusy)
            } }
        Settings { SettingsView(store: store).frame(width: 650, height: 660) }
        MenuBarExtra { MenuBarView(store: store) } label: { Label("talkie", systemImage: store.recording ? "mic.fill" : "waveform") }
    }
    private func connectDelegate() { delegate.store = store }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminateSignal: DispatchSourceSignal?
    private var drainingBeforeQuit = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminateSignal = source
        if CommandLine.arguments.contains("--self-test") { Task { @MainActor in await SelfTestRunner.run(primaryStore: { [weak self] in self?.store }) } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if drainingBeforeQuit { return .terminateCancel }
        guard let store, store.recording || store.isBusy || store.isDownloading else { return .terminateNow }
        drainingBeforeQuit = true
        Task { @MainActor in
            if store.dictation.isActive { store.dictation.cancel() }
            else if store.recording { store.stopRecording(incomplete: "App quit; meeting audio saved; temporary voice input discarded.") } else { store.cancel() }
            while store.isBusy || store.isDownloading { try? await Task.sleep(for: .milliseconds(100)) }
            if store.recording { store.stopRecording(incomplete: "App quit; meeting audio saved; temporary voice input discarded.") }
            while store.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            drainingBeforeQuit = false
            // terminateLater enters AppKit's nested loop and can block queued
            // main-actor save tasks when Quit came from a DispatchSource signal.
            // Cancel this first request, drain normally, then quit while idle.
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}
