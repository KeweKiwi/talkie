import SwiftUI
import AppKit
import AVFoundation
import Carbon
import TalkieCore

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var removeModel = false
    @State private var deleteLegacy = false
    @State private var permissionStatus = ""
    var body: some View {
        @Bindable var preferences = store.preferences
        TabView {
            Form {
                Section("Dictation") {
                    Toggle("Enable System-Wide Dictation", isOn: $preferences.systemWideEnabled)
                    Toggle("Auto Insert After Dictation", isOn: $preferences.autoInsert)
                    Toggle("AI Cleanup ON", isOn: $preferences.cleanupEnabled)
                    Text("The shortcut records without switching apps. Auto Insert replaces only a verified selection. OFF skips Ollama; ON inserts accepted cleanup. Cleanup failure or suspect rewrites use complete raw ASR. Unsafe destinations use temporary recovery. Dictation is never archived.").font(.caption).foregroundStyle(.secondary)
                    Picker("Recognition language", selection: $preferences.language) { ForEach(RecognitionLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Toggle("Push-to-talk (hold shortcut)", isOn: $preferences.pushToTalk)
                    Picker("Shortcut key", selection: $preferences.shortcutKey) {
                        Text("Space").tag(UInt32(kVK_Space)); Text("F6").tag(UInt32(kVK_F6)); Text("F8").tag(UInt32(kVK_F8)); Text("D").tag(UInt32(kVK_ANSI_D))
                    }
                    Picker("Shortcut modifiers", selection: $preferences.shortcutModifiers) {
                        Text("Control + Option").tag(UInt32(controlKey | optionKey))
                        Text("Command + Shift").tag(UInt32(cmdKey | shiftKey))
                        Text("Control + Command").tag(UInt32(controlKey | cmdKey))
                    }
                    Text(store.shortcutStatus).font(.caption).foregroundStyle(.secondary)
                    Text(TextInsertionService.trusted ? "Accessibility available for automatic insertion." : "Accessibility unavailable; dictation remains recoverable as preview/Copy.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Permissions") {
                    Button("Request Microphone Access") { permissionStatus = "Requesting microphone permission…"; Task { do { try await AudioRecorder.requestMicrophone(); permissionStatus = "Microphone permission granted." } catch { permissionStatus = error.localizedDescription } } }
                    Button("Enable Accessibility Insertion") { TextInsertionService.requestPermission() }
                    Button("Request System Audio Permission") { _ = CGRequestScreenCaptureAccess() }
                    Text("System audio asks for Screen & System Audio Recording permission when a meeting starts. talkie registers no screen-frame output.").font(.caption).foregroundStyle(.secondary)
                    Text(permissionStatus).font(.caption)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            Form {
                Section("Multilingual speech model") {
                    LabeledContent("Model", value: "Large v3 Turbo · 626 MB")
                    LabeledContent("State", value: store.speechModelInstalled ? "Installed" : "Not installed")
                    Text("Pinned Argmax Core ML model. Approximately 0.63 GB download plus device compilation/cache storage. Requires no account.").font(.caption).foregroundStyle(.secondary)
                    if store.isDownloading { ProgressView(value: store.downloadProgress); Text(store.downloadStatus).font(.caption); Button("Cancel Download") { store.cancel() } }
                    else { Button(store.speechModelInstalled ? "Verify / Repair Speech Model" : "Download Speech Model") { store.downloadModel() }.disabled(store.recording || store.isBusy) }
                    Button("Remove Speech Model", role: .destructive) { removeModel = true }.disabled(store.recording || store.isBusy || !store.speechModelInstalled)
                }
                Section("Local text models · Ollama") {
                    Picker("Cleanup model", selection: $preferences.cleanupModel) { ForEach(LocalTextService.allowedModels, id: \.self) { Text($0).tag($0) } }
                    Picker("Summary model", selection: $preferences.summaryModel) { ForEach(LocalTextService.allowedModels, id: \.self) { Text($0).tag($0) } }
                    Picker("Summary language", selection: $preferences.summaryLanguage) { Text("Bahasa Indonesia").tag("Bahasa Indonesia"); Text("English").tag("English") }
                    Button("Verify & Pin Installed Digests") { store.pinModels() }.disabled(store.isBusy || store.recording)
                    Text("Endpoint: 127.0.0.1:11434. Run script/start_ollama.sh and install the exact tags with script/setup_text_models.sh. No automatic pulls, cloud fallback, or silent substitution.").font(.caption).foregroundStyle(.secondary)
                    Text("Cleanup pin: \(preferences.cleanupDigest.isEmpty ? "not pinned" : String(preferences.cleanupDigest.prefix(16)))\nSummary pin: \(preferences.summaryDigest.isEmpty ? "not pinned" : String(preferences.summaryDigest.prefix(16)))").font(.caption.monospaced())
                    Text("Text tasks are serialized. Speech models are unloaded before text inference. Summaries use a bounded context and validated evidence references; review remains necessary.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Models", systemImage: "cpu") }
            Form {
                Section("Personal dictionary") {
                    Text("One term or name per line, up to 48 entries. These are conservative ASR hints; terms are never replaced after recognition. Hints may bias ASR, so include only terms you use.").foregroundStyle(.secondary)
                    TextEditor(text: $preferences.dictionary).font(.body.monospaced()).frame(height: 270).border(.quaternary)
                }
                Section("Online meeting microphone") {
                    Picker("Microphone", selection: $preferences.microphoneID) {
                        Text("System default").tag("")
                        ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                    }
                    Text("This selector applies to ScreenCaptureKit online meetings. Dictation and microphone-only meetings use the system default input.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Recognition", systemImage: "text.book.closed") }
            Form {
                Section("Private local storage") {
                    Text("Meeting audio, raw versions, corrections, and summaries are stored in your Application Support/talkie folder with restrictive file permissions. No analytics or transcript logging.")
                    Text("Dictation uses engine-required temporary WAV files outside the meeting library, removed after processing, cancellation, or failure. Orphans are removed after restart. One in-memory recovery expires after 60 seconds or dismissal. No dictation text or field context is archived. Meetings retain audio until deletion. Normal deletion is not forensic secure erasure.").foregroundStyle(.secondary)
                    if store.legacyDictationCount > 0 {
                        Button("Delete Old Dictation History…", role: .destructive) { deleteLegacy = true }.disabled(store.recording || store.isBusy)
                        Text("\(store.legacyDictationCount) old dictation archives remain. This explicit migration preserves every meeting.").font(.caption)
                    }
                    Button("Reveal Local Data") { NSWorkspace.shared.open(AppPaths.root) }
                    Text(AppPaths.root.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("Offline operation") {
                    Text("Inference only reads local files or calls loopback Ollama. External network access occurs only during explicit model setup/repair. Exports prepare local files; talkie never submits them to another AI.")
                    Text("No required subscription, paid API, backend, cloud credits, or account. Storage, memory, power, and initial downloads still use your hardware and connection.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "lock") }
        }.padding(12)
            .onChange(of: preferences.systemWideEnabled) { _, _ in store.configureShortcut() }
            .onChange(of: preferences.shortcutKey) { _, _ in store.configureShortcut() }
            .onChange(of: preferences.shortcutModifiers) { _, _ in store.configureShortcut() }
            .alert("Delete old dictation history?", isPresented: $deleteLegacy) {
                Button("Delete Old Dictations", role: .destructive) { store.deleteLegacyDictations() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Deletes only old dictation archives and their audio. Meetings, transcripts, summaries, and settings remain. This cannot be undone in talkie.") }
            .alert("Remove the downloaded speech model?", isPresented: $removeModel) { Button("Remove", role: .destructive) { store.removeSpeechModel() }; Button("Cancel", role: .cancel) {} } message: { Text("Recordings and transcripts remain. Transcription requires downloading this model again.") }
    }
}
