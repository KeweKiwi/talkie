import AppKit
import AVFoundation
import Observation
import TalkieCore

@Observable @MainActor final class AppStore {
    private static var sweptTemporaryAudio = false
    let preferences: AppPreferences
    var sessions: [RecordingSession] = []
    var selectedID: UUID?
    var area = "Meetings"
    var message = "Ready. Audio and text stay on this Mac."
    var phase = "Ready"
    var activeID: UUID?
    var elapsed: Double = 0
    var levels: [AudioSource: Float] = [:]
    var microphoneMuted = false
    var captureScope = "Default microphone"
    var isPaused = false
    var downloadProgress: Double = 0
    var downloadStatus = ""
    var isDownloading = false
    private var meetingBusy = false
    var isBusy: Bool { get { meetingBusy || dictation.isBusy } set { meetingBusy = newValue } }
    var displayPhase: String { dictation.isActive ? dictation.phase : phase }
    let dictation: DictationController
    var legacyDictationCount = 0
    var shortcutStatus = ""
    var applications: [(pid: pid_t, name: String)] = []
    private(set) var repository: SessionRepository?
    private let recognition = RecognitionService()
    private let textService = LocalTextService()
    private let downloader = ModelDownloadService()
    private let overlay = RecordingOverlay()
    private let shortcut: GlobalShortcutService
    private var recorder: AudioRecorder?
    private var timer: Timer?
    private var recordingClock = Date()
    private var operation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    var active: RecordingSession? { sessions.first { $0.id == activeID } }
    var selected: RecordingSession? { sessions.first { $0.id == selectedID } }
    var recording: Bool { recorder != nil || dictation.recording }
    var speechModelInstalled: Bool { FileManager.default.fileExists(atPath: AppPaths.modelFolder.appendingPathComponent("installed.json").path) }
    var hasPendingClipboardRestore: Bool { dictation.canRestoreClipboard }
    init(preferences: AppPreferences? = nil, registerShortcut: Bool = true) {
        self.preferences = preferences ?? AppPreferences()
        self.shortcut = GlobalShortcutService(enabled: registerShortcut)
        self.dictation = DictationController(preferences: self.preferences, recognition: recognition, textService: textService)
        dictation.setCancellation = { [weak self] active in self?.shortcut.setCancellation(active) }
        if !Self.sweptTemporaryAudio {
            Self.sweptTemporaryAudio = true
            do { try TransientDictationAudio.removeOrphans(includeCurrentProcess: true) } catch { message = "Temporary audio cleanup failed. Check available storage." }
        }
        do {
            let repo = try SessionRepository(root: AppPaths.sessions); repository = repo
            let stored = try repo.load()
            legacyDictationCount = stored.filter { $0.kind == .dictation }.count
            sessions = try stored.filter { $0.kind == .meeting }.map { try RecordingRecovery.recover($0, repository: repo) }
        } catch { message = "Local storage could not be opened: \(error.localizedDescription)" }
        shortcut.onPress = { [weak self] in self?.toggleDictation() }
        shortcut.onRelease = { [weak self] in self?.dictation.releaseShortcut() }
        shortcut.onCancel = { [weak self] in self?.cancel() }
        if registerShortcut { configureShortcut() }
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stopRecording(incomplete: "Mac went to sleep; capture was interrupted.") } }
        observers.append(sleep)
        let device = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            guard let self, self.recording else { return }; self.stopRecording(incomplete: "Audio device configuration changed. Review saved sources before resuming in a new session.")
        } }
        observers.append(device)
    }
    func editorCallCount() async -> Int { await textService.cleanupCalls }
    func configureShortcut() {
        guard preferences.systemWideEnabled else { shortcut.unregister(); shortcutStatus = "System-wide dictation disabled"; return }
        shortcutStatus = shortcut.register(key: preferences.shortcutKey, modifiers: preferences.shortcutModifiers) ? "Global shortcut registered" : "Shortcut unavailable; choose another combination."
    }
    func toggleDictation() {
        guard recorder == nil, !meetingBusy, !isDownloading else { message = "Finish the meeting or processing task first."; return }
        dictation.toggle()
    }
    func startMeeting(title: String, includeSystem: Bool, application: pid_t?) {
        guard !recording, !isBusy else { message = "Finish the current recording or processing task first."; return }
        begin(kind: .meeting, title: title.isEmpty ? "Meeting" : title, sources: includeSystem ? [.microphone, .system] : [.microphone], systemApp: application)
    }
    private func begin(kind: SessionKind, title: String, sources: [AudioSource], systemApp: pid_t?) {
        guard let repository else { message = "Local storage is unavailable."; return }
        isBusy = true; phase = "Starting"
        operation = Task {
            do {
                try await AudioRecorder.requestMicrophone()
                try Task.checkCancellation()
                let session = RecordingSession(title: title, kind: kind, sources: sources)
                let capture = AudioRecorder()
                capture.onMeters = { [weak self] meters in Task { @MainActor in self?.levels = meters } }
                capture.onFailure = { [weak self] reason in Task { @MainActor in self?.stopRecording(incomplete: reason) } }
                try await capture.start(session: session, repository: repository, microphoneID: preferences.microphoneID, systemApp: systemApp)
                if Task.isCancelled {
                    let cancelled = try await capture.stop(incomplete: "Start cancelled; available audio retained.")
                    update(cancelled); throw CancellationError()
                }
                recorder = capture; activeID = session.id; sessions.insert(session, at: 0)
                selectedID = session.id; area = "Meetings"
                captureScope = sources.contains(.system) ? "Microphone + \(systemApp.flatMap { pid in applications.first { $0.pid == pid }?.name } ?? "all system audio")" : "Default microphone"
                phase = "Recording"; isBusy = false
                recordingClock = session.startedAt; elapsed = 0; isPaused = false; microphoneMuted = false
                overlay.show("Recording", detail: "Meeting · microphone\(sources.contains(.system) ? " + system" : "")")
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in
                    guard let self else { return }; self.elapsed = Date().timeIntervalSince(self.recordingClock)
                    if self.active?.kind == .meeting { self.overlay.show(self.isPaused ? "Paused" : "Recording", detail: "Meeting · \(TranscriptExporter.timestamp(self.elapsed))") }
                } }
            } catch { isBusy = false; phase = "Error"; message = error.localizedDescription; reload(); overlay.show("Could not start", detail: message) }
        }
    }
    func stopRecording(incomplete: String? = nil) {
        if dictation.isActive { dictation.stop(interrupted: incomplete); return }
        guard let capture = recorder, !isBusy else { return }
        isBusy = true; phase = "Saving"; timer?.invalidate(); timer = nil; shortcut.setCancellation(false)
        operation = Task {
            do {
                let session = try await capture.stop(incomplete: incomplete)
                recorder = nil; activeID = nil; update(session); overlay.hide(); isBusy = false
                phase = "Saved"; message = session.error ?? "Audio saved. Transcribe, then export or summarize independently."
            } catch { recorder = nil; activeID = nil; isBusy = false; phase = "Error"; overlay.hide(); message = error.localizedDescription; reload() }
        }
    }
    func pauseResume() {
        guard let recorder, !isBusy else { return }
        isBusy = true
        operation = Task { do { if isPaused { try await recorder.resume() } else { try await recorder.pause() }; isPaused.toggle(); phase = isPaused ? "Paused" : "Recording"; isBusy = false } catch { isBusy = false; stopRecording(incomplete: error.localizedDescription) } }
    }
    func muteMicrophone() {
        guard let recorder, !isBusy else { return }
        isBusy = true
        operation = Task { do { try await recorder.muteMicrophone(!microphoneMuted); microphoneMuted.toggle(); isBusy = false } catch { isBusy = false; stopRecording(incomplete: error.localizedDescription) } }
    }
    func cancel() {
        if dictation.isActive { dictation.cancel(); return }
        if active?.kind == .meeting { message = "Use Stop to finish the meeting; Escape does not interrupt it." }
        else { operation?.cancel(); overlay.hide(); message = "Cancellation requested. Saved meeting data is preserved." }
    }
    func transcribe(_ id: UUID) {
        guard !isBusy, !recording, let repository, var session = sessions.first(where: { $0.id == id }), session.audioRetained else { return }
        isBusy = true; phase = "Transcribing"; selectedID = id
        let options = preferences.snapshot
        operation = Task {
            var version = TranscriptVersion(model: RecognitionService.identity, language: options.language, segments: [], coverage: session.coverage)
            session.status = .transcribing; session.draftTranscript = version
            do {
                try repository.save(session)
                for index in version.coverage.indices {
                    try Task.checkCancellation()
                    guard let file = version.coverage[index].file else { continue }
                    version.coverage[index].state = .pending
                    let interval = version.coverage[index]
                    message = "Transcribing chunk \(index + 1) of \(version.coverage.count)…"
                    do {
                        let recognized = try await recognition.transcribe(file: repository.directory(id).appendingPathComponent(file), interval: interval, language: options.language, dictionary: options.dictionary)
                        version.segments += recognized.segments; version.coverage[index].state = recognized.detectedSilence ? .silence : .processed
                        if recognized.segments.isEmpty { version.coverage[index].note = recognized.detectedSilence ? "Digital silence below -80 dBFS" : "No ASR text returned; speech may have been missed" }
                    } catch is CancellationError { throw CancellationError() }
                    catch { version.coverage[index].state = .failed; version.coverage[index].note = error.localizedDescription }
                    session.draftTranscript = version; try repository.save(session)
                }
                session.versions.append(version); session.draftTranscript = nil
                session.status = version.accountedFor ? .ready : .incomplete; session.coverage = version.coverage
                session.error = version.accountedFor ? nil : "Partial transcript. Review failed/missing intervals; all available text can be exported."
                try repository.save(session); update(session)
                message = session.error ?? "Full transcript saved. Copy/export works independently of Ollama."
                phase = "Ready"
            } catch {
                session.draftTranscript = nil
                if !session.versions.contains(where: { $0.id == version.id }) { session.versions.append(version) }
                session.status = .incomplete; session.error = error.localizedDescription
                try? repository.save(session); update(session)
                message = "Processing stopped; saved meeting chunks and available transcript are retained."; phase = "Error"
            }
            isBusy = false; overlay.hide()
        }
    }
    func restorePreviousClipboard() { dictation.restoreClipboard() }
    func deleteLegacyDictations() {
        guard !recording, !isBusy, let repository else { return }
        do { let removed = try repository.deleteLegacyDictations(); legacyDictationCount = 0; message = "Removed \(removed) old dictations. Meetings preserved." }
        catch { message = "Legacy deletion stopped: \(error.localizedDescription)"; legacyDictationCount = (try? repository.load().filter { $0.kind == .dictation }.count) ?? legacyDictationCount }
    }
    func summarize(_ id: UUID, versionID: UUID) {
        guard !isBusy, !recording, let repository, var session = sessions.first(where: { $0.id == id }), let transcript = session.versions.first(where: { $0.id == versionID }) else { return }
        isBusy = true; phase = "Summarizing"
        operation = Task {
            defer { isBusy = false; phase = "Ready" }
            do {
                await recognition.unload()
                let summary = try await textService.summarize(transcript, model: preferences.summaryModel, digest: preferences.summaryDigest, language: preferences.summaryLanguage, startedAt: session.startedAt, timeZone: session.timeZone) { [weak self] status in Task { @MainActor in self?.message = status } }
                session.summaries.append(summary); try repository.save(session); update(session); message = "Summary saved for review. Evidence IDs are validated; verify the claims against the transcript."
            } catch { message = "Summary failed: \(error.localizedDescription). Full transcript is preserved." }
        }
    }
    func correct(_ id: UUID, source: TranscriptVersion, edits: [String: String]) {
        guard !isBusy, !recording, var session = sessions.first(where: { $0.id == id }) else { return }
        var segments = source.segments
        for i in segments.indices { if let text = edits[segments[i].id] { segments[i].text = text } }
        let version = TranscriptVersion(parentID: source.id, isRaw: false, model: source.model, language: source.language, segments: segments, coverage: source.coverage)
        session.versions.append(version); persist(session); message = "Corrected derivative saved. Raw versions remain unchanged."
    }
    func saveSummaryEdit(_ id: UUID, summaryID: UUID, text: String) {
        guard !isBusy, var session = sessions.first(where: { $0.id == id }), let index = session.summaries.firstIndex(where: { $0.id == summaryID }) else { return }
        session.summaries[index].editedMarkdown = text; persist(session)
    }
    func deleteAudio(_ id: UUID) {
        guard !recording, !isBusy, let repository, var session = sessions.first(where: { $0.id == id }) else { return }
        do { try repository.deleteAudio(&session); update(session) } catch { message = error.localizedDescription }
    }
    func deleteSession(_ id: UUID) {
        guard !recording, !isBusy else { return }
        do { try repository?.delete(id); sessions.removeAll { $0.id == id }; if selectedID == id { selectedID = nil } } catch { message = error.localizedDescription }
    }
    func downloadModel() {
        guard !isDownloading, !isBusy, !recording else { return }; isDownloading = true
        operation = Task {
            defer { isDownloading = false }
            do { try await downloader.download { [weak self] fraction, file in Task { @MainActor in self?.downloadProgress = fraction; self?.downloadStatus = file } }; message = "Multilingual speech model installed." }
            catch { message = "Download stopped: \(error.localizedDescription)" }
        }
    }
    func pinModels() {
        guard !isBusy, !recording else { return }; isBusy = true
        operation = Task {
            defer { isBusy = false }
            do {
                let cleanup = try await textService.identity(preferences.cleanupModel)
                let summary = try await textService.identity(preferences.summaryModel)
                preferences.cleanupDigest = cleanup.digest; preferences.summaryDigest = summary.digest
                message = "Installed model digests pinned. Ollama \(cleanup.runtime). Suspect cleanup uses raw ASR."
            } catch { message = error.localizedDescription }
        }
    }
    func removeSpeechModel() {
        guard !recording, !isBusy, !isDownloading else { return }; isBusy = true
        operation = Task { defer { isBusy = false }; await recognition.unload(); do { try FileManager.default.removeItem(at: AppPaths.modelFolder); message = "Speech model removed. Sessions are retained." } catch { message = error.localizedDescription } }
    }
    func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.map { ($0.processIdentifier, $0.localizedName ?? "Application") }.sorted { $0.name < $1.name }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "Copied. Paste manually into your intended destination." }
    private func persist(_ session: RecordingSession) { do { try repository?.save(session); update(session) } catch { message = error.localizedDescription } }
    private func update(_ session: RecordingSession) { if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.insert(session, at: 0) } }
    private func reload() { do { if let repository { sessions = try repository.load().filter { $0.kind == .meeting } } } catch { message = error.localizedDescription } }
}
