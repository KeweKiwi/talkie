import AppKit
import AVFoundation
import Observation
import TalkieCore

@Observable @MainActor final class AppStore {
    let preferences: AppPreferences
    var sessions: [RecordingSession] = []
    var selectedID: UUID?
    var area = "Dictation"
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
    var isBusy = false
    var shortcutStatus = ""
    var applications: [(pid: pid_t, name: String)] = []
    private(set) var repository: SessionRepository?
    private let recognition = RecognitionService()
    private let textService = LocalTextService()
    private let downloader = ModelDownloadService()
    private let insertion = TextInsertionService()
    private let overlay = RecordingOverlay()
    private let shortcut = GlobalShortcutService()
    private var recorder: AudioRecorder?
    private var timer: Timer?
    private var recordingClock = Date()
    private var operation: Task<Void, Never>?
    private var dictationOptions: AppPreferences.Snapshot?
    private var releaseWhileStarting = false
    private var observers: [NSObjectProtocol] = []
    var active: RecordingSession? { sessions.first { $0.id == activeID } }
    var selected: RecordingSession? { sessions.first { $0.id == selectedID } }
    var recording: Bool { recorder != nil }
    var speechModelInstalled: Bool { FileManager.default.fileExists(atPath: AppPaths.modelFolder.appendingPathComponent("installed.json").path) }
    init(preferences: AppPreferences? = nil, registerShortcut: Bool = true) {
        self.preferences = preferences ?? AppPreferences()
        do {
            let repo = try SessionRepository(root: AppPaths.sessions); repository = repo
            sessions = try repo.load().map { try RecordingRecovery.recover($0, repository: repo) }
        } catch { message = "Local storage could not be opened: \(error.localizedDescription)" }
        shortcut.onPress = { [weak self] in self?.toggleDictation() }
        shortcut.onRelease = { [weak self] in
            guard let self, self.preferences.pushToTalk else { return }
            if self.phase == "Starting" { self.releaseWhileStarting = true }
            else if self.active?.kind == .dictation { self.stopRecording() }
        }
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
        shortcutStatus = shortcut.register(key: preferences.shortcutKey, modifiers: preferences.shortcutModifiers) ? "Global shortcut registered" : "Shortcut unavailable; choose another combination."
    }
    func toggleDictation() {
        // Explicit developer-only component probe, initiated by the same shortcut.
        // This tests AX behavior in disposable editors without recording speech.
        if CommandLine.arguments.contains("--insertion-probe") {
            guard !isBusy, !recording else { return }
            isBusy = true; phase = "Insertion probe"
            operation = Task {
                do {
                    // UI automation can focus a disposable editor during this
                    // explicit diagnostic delay. Normal dictation has no delay.
                    if CommandLine.arguments.contains("--probe-focus-delay") { try await Task.sleep(for: .seconds(8)) }
                    insertion.capture()
                    try await Task.sleep(for: .seconds(8)); try Task.checkCancellation()
                    message = insertion.insert("talkie fixture — café 日本語")
                }
                catch { insertion.clear(); message = "Insertion probe cancelled." }
                isBusy = false; phase = "Ready"
            }
            return
        }
        if active?.kind == .meeting { message = "A meeting is recording. Stop it before starting dictation."; return }
        if active?.kind == .dictation { if !preferences.pushToTalk { stopRecording() }; return }
        guard !isBusy else { message = "Wait for the current task or cancel it first."; return }
        insertion.capture(); dictationOptions = preferences.snapshot; releaseWhileStarting = false
        begin(kind: .dictation, title: "Dictation", sources: [.microphone], systemApp: nil)
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
                recorder = capture; activeID = session.id; selectedID = session.id; sessions.insert(session, at: 0)
                captureScope = sources.contains(.system) ? "Microphone + \(systemApp.flatMap { pid in applications.first { $0.pid == pid }?.name } ?? "all system audio")" : "Default microphone"
                area = kind == .meeting ? "Meetings" : "Dictation"; phase = "Recording"; isBusy = false
                recordingClock = session.startedAt; elapsed = 0; isPaused = false; microphoneMuted = false
                shortcut.setCancellation(kind == .dictation)
                overlay.show("Recording", detail: kind == .meeting ? "Meeting · microphone\(sources.contains(.system) ? " + system" : "")" : "Shortcut to stop · Esc to cancel")
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in
                    guard let self else { return }; self.elapsed = Date().timeIntervalSince(self.recordingClock)
                    if self.active?.kind == .meeting { self.overlay.show(self.isPaused ? "Paused" : "Recording", detail: "Meeting · \(TranscriptExporter.timestamp(self.elapsed))") }
                } }
                if kind == .dictation && preferences.pushToTalk && releaseWhileStarting { stopRecording() }
            } catch { isBusy = false; phase = "Error"; message = error.localizedDescription; insertion.clear(); reload() }
        }
    }
    func stopRecording(incomplete: String? = nil) {
        guard let capture = recorder, !isBusy else { return }
        isBusy = true; phase = "Saving"; timer?.invalidate(); timer = nil; shortcut.setCancellation(false)
        operation = Task {
            do {
                let session = try await capture.stop(incomplete: incomplete)
                recorder = nil; activeID = nil; update(session); overlay.hide(); isBusy = false
                if session.kind == .dictation && incomplete == nil { transcribe(session.id, dictation: true) }
                else { phase = "Saved"; message = session.error ?? "Audio saved. Transcribe, then export or summarize independently." }
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
        if recording, active?.kind == .dictation {
            guard !isBusy else { message = "Audio is being saved; wait for it to finish."; return }
            guard let capture = recorder else { return }
            timer?.invalidate(); timer = nil; isBusy = true
            operation = Task {
                do { let session = try await capture.stop(incomplete: "Dictation cancelled; audio retained for recovery."); update(session) } catch { message = error.localizedDescription }
                recorder = nil; activeID = nil; overlay.hide(); insertion.clear(); shortcut.setCancellation(false); isBusy = false; phase = "Cancelled"
            }
        } else if active?.kind == .meeting { message = "Use Stop to finish the meeting; Escape does not interrupt it." }
        else { operation?.cancel(); insertion.clear(); overlay.hide(); message = "Cancellation requested. Saved data is preserved." }
    }
    func transcribe(_ id: UUID, dictation: Bool = false) {
        guard !isBusy, !recording, let repository, var session = sessions.first(where: { $0.id == id }), session.audioRetained else { return }
        isBusy = true; phase = "Transcribing"; selectedID = id; shortcut.setCancellation(true)
        let options = dictation ? dictationOptions ?? preferences.snapshot : preferences.snapshot
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
                if dictation {
                    var result = DictationResult(original: version.text, cleanupRequested: options.cleanupEnabled, cleanupStatus: options.cleanupEnabled ? "Cleanup requested" : "Cleanup OFF — raw ASR")
                    if EditingPolicy.shouldCallEditor(cleanupEnabledAtStart: options.cleanupEnabled), !version.text.isEmpty {
                        phase = "Cleaning"; overlay.show("Cleaning", detail: "Local editor · Esc to cancel")
                        await recognition.unload()
                        do {
                            let (cleaned, identity) = try await textService.cleanup(version.text, model: options.cleanupModel, digest: options.cleanupDigest)
                            result.cleaned = cleaned.text; result.model = identity.name; result.digest = identity.digest; result.runtime = identity.runtime; result.promptVersion = EditingPolicy.version
                            let concerns = EditingPolicy.concerns(original: version.text, edited: cleaned.text)
                            if !concerns.isEmpty || cleaned.needs_review { result.usedOriginal = true }
                            result.cleanupStatus = concerns.isEmpty && !cleaned.needs_review ? "Cleanup ready — review before copying" : "Needs review — \(concerns.joined(separator: "; "))"
                        } catch { result.cleanupStatus = "Cleanup failed — original retained: \(error.localizedDescription)" }
                        message = "Cleanup is preview-only. Review the original and edited text before copying."
                        insertion.clear()
                    } else if version.accountedFor && !version.text.isEmpty { message = insertion.insert(version.text) }
                    else { insertion.clear(); message = "Partial or empty dictation. Review available text and use Copy." }
                    session.dictation = result; try repository.save(session)
                    if version.accountedFor && !options.cleanupEnabled { try repository.deleteAudio(&session) }
                    update(session)
                } else { message = session.error ?? "Full transcript saved. Copy/export works independently of Ollama." }
                phase = "Ready"
            } catch {
                session.draftTranscript = nil; session.versions.append(version); session.status = .incomplete; session.error = error.localizedDescription
                try? repository.save(session); update(session); message = "Processing stopped; saved chunks and available transcript are retained."; phase = "Error"
            }
            isBusy = false; shortcut.setCancellation(false); overlay.hide()
        }
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
    func useOriginal(_ id: UUID) { guard var session = selected, session.id == id else { return }; session.dictation?.usedOriginal = true; persist(session) }
    func saveReviewedDictation(_ id: UUID, text: String) {
        guard !isBusy, var session = sessions.first(where: { $0.id == id }) else { return }
        session.dictation?.reviewedText = text; session.dictation?.usedOriginal = false
        session.dictation?.cleanupStatus = "Manually reviewed text"; persist(session)
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
                message = "Installed model digests pinned. Ollama \(cleanup.runtime). Cleanup still requires review."
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
    private func reload() { do { if let repository { sessions = try repository.load() } } catch { message = error.localizedDescription } }
}
