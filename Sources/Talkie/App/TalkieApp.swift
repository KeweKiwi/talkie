import SwiftUI
import AppKit

@main struct TalkieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore(registerShortcut: !CommandLine.arguments.contains("--self-test"))
    var body: some Scene {
        WindowGroup("talkie", id: "main") { ContentView(store: store).onAppear { delegate.store = store }.frame(minWidth: 900, minHeight: 630) }
            .defaultSize(width: 1060, height: 740)
            .commands { CommandGroup(after: .newItem) {
                Button("Start / Stop Dictation") { store.toggleDictation() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Cancel Processing") { store.cancel() }.disabled(!store.isBusy)
            } }
        Settings { SettingsView(store: store).frame(width: 650, height: 660) }
        MenuBarExtra { MenuBarView(store: store) } label: { Label("talkie", systemImage: store.recording ? "mic.fill" : "waveform") }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminateSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminateSignal = source
        if CommandLine.arguments.contains("--self-test") { Task { @MainActor in await SelfTestRunner.run() } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.recording || store.isBusy || store.isDownloading else { return .terminateNow }
        Task { @MainActor in
            if store.recording { store.stopRecording(incomplete: "App quit; saved audio can be reviewed.") } else { store.cancel() }
            while store.isBusy || store.isDownloading { try? await Task.sleep(for: .milliseconds(100)) }
            if store.recording { store.stopRecording(incomplete: "App quit; saved audio can be reviewed.") }
            while store.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
