import AppKit
import AVFoundation
import Observation
import OSLog
import TalkieCore

/// Owns one temporary voice-input operation. Shares the meeting capture/ASR/text
/// services, but never opens the persistent session repository.
@Observable @MainActor final class DictationController {
    struct Metrics: Codable {
        var recognitionMilliseconds: Double = 0
        var cleanupMilliseconds: Double = 0
        var stopToOutcomeMilliseconds: Double = 0
        var stopToInsertMilliseconds: Double?
        var inserted = false
        var uncertain = false
        var reason = "idle"
        var temporaryAudioRemoved = true
        var microphonePeak: Float = 0
        var microphoneObserved = false
        var missingIntervals = 0
        var recognizedBytes = 0
        var deliveryReason = "not_attempted"
    }
    struct FixtureResult { var raw: String; var output: String; var metrics: Metrics; var message: String }
    private let preferences: AppPreferences
    private let recognition: RecognitionService
    private let textService: LocalTextService
    private let insertion = TextInsertionService()
    private let overlay = RecordingOverlay()
    private let logger = Logger(subsystem: "co.kewekiwi.talkie", category: "VoiceInput")
    private var capture: AudioRecorder?
    private var workspace: TransientDictationAudio?
    private var task: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var recoveryExpiry: Task<Void, Never>?
    private var recovery = TransientRecovery()
    private var recoveryMessage = ""
    private(set) var recoveryUncertain = false
    private var operationID: UUID?
    private var options: AppPreferences.Snapshot?
    private var releaseWhileStarting = false
    private var captureFailed = false
    private(set) var isBusy = false
    private(set) var phase = "Ready"
    private(set) var notice = "Ready"
    private(set) var metrics = Metrics()
    var setCancellation: ((Bool) -> Void)?
    var recording: Bool { capture != nil && !isBusy }
    var isActive: Bool { capture != nil || isBusy }
    var hasRecovery: Bool { recovery.text != nil }
    var recoveryByteCount: Int { recovery.text?.utf8.count ?? 0 }
    var temporaryAudioDirectoryForDiagnostic: URL? { workspace?.directory }
    var canRestoreClipboard: Bool { insertion.canRestoreClipboard }
    static let recoverySeconds = 60.0
    static let maximumTextBytes = 64 * 1024
    init(preferences: AppPreferences, recognition: RecognitionService, textService: LocalTextService) {
        self.preferences = preferences; self.recognition = recognition; self.textService = textService
    }
    func toggle() {
        if recording { if options?.pushToTalk != true { stop() }; return }
        guard !isBusy else { return }
        if let workspace {
            do { try workspace.remove(); self.workspace = nil }
            catch { notice = "Temporary audio cleanup failed; another recording cannot start."; return }
        }
        clearRecovery()
        let id = UUID(); operationID = id; metrics = Metrics(); options = preferences.snapshot
        // Capture before any Talkie panel appears. Never refocus an old editor.
        insertion.capture(operationID: id)
        overlay.anchor = insertion.overlayAnchor
        overlay.inputLevel = 0
        logger.info("dictation_requested cleanup=\(self.options?.cleanupEnabled == true, privacy: .public) auto_insert=\(self.options?.autoInsert != false, privacy: .public) destination_captured=\(self.insertion.target != nil, privacy: .public)")
        releaseWhileStarting = false; captureFailed = false; isBusy = true; phase = "Starting"; setCancellation?(true)
        overlay.show("Starting", detail: "Microphone · Esc to cancel", actions: [cancelAction])
        let microphoneID = options?.microphoneID ?? ""
        task = Task {
            var localCapture: AudioRecorder?
            do {
                let space = try TransientDictationAudio(); workspace = space
                let session = RecordingSession(title: "Temporary voice input", kind: .dictation, sources: [.microphone])
                let recorder = AudioRecorder(); localCapture = recorder
                recorder.onMeters = { [weak self] levels in Task { @MainActor in
                    guard let self, self.operationID == id else { return }
                    self.metrics.microphoneObserved = true
                    self.metrics.microphonePeak = max(self.metrics.microphonePeak, levels[.microphone] ?? 0)
                    self.overlay.inputLevel = levels[.microphone] ?? 0
                } }
                recorder.onFailure = { [weak self] _ in Task { @MainActor in
                    guard let self, self.operationID == id else { return }; self.captureFailed = true; self.stop(interrupted: "Microphone capture was interrupted.")
                } }
                try await recorder.start(session: session, transientDirectory: space.directory, microphoneID: microphoneID, systemApp: nil)
                try Task.checkCancellation(); if captureFailed { throw TalkieError.message("Microphone capture was interrupted.") }; guard operationID == id else { throw CancellationError() }
                capture = recorder; localCapture = nil; isBusy = false; phase = "Recording"
                logger.info("dictation_capture_ready")
                overlay.show("Recording", detail: "Shortcut to stop · Esc to cancel", actions: [.init(title: "Stop", handler: { [weak self] in self?.stop() }), cancelAction])
                recordingLimit = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)); guard let self, self.operationID == id else { return }; self.stop() } catch {}
                }
                if options?.pushToTalk == true && releaseWhileStarting { stop() }
            } catch {
                if let localCapture { _ = try? await localCapture.stop(incomplete: "Temporary input cancelled") }
                if operationID == id {
                    metrics.reason = Task.isCancelled ? "cancelled" : "capture_failed"
                    notice = Task.isCancelled ? "Dictation cancelled." : "Microphone or temporary audio could not start. Check permissions and storage."
                    overlay.show("Could not start", detail: notice, actions: [dismissAction], dismissAfter: true)
                    finish(id)
                }
            }
        }
    }
    func releaseShortcut() {
        guard options?.pushToTalk == true else { return }
        if phase == "Starting" { releaseWhileStarting = true } else if recording { stop() }
    }
    func stop(interrupted: String? = nil) {
        guard let capture, !isBusy, let id = operationID, let workspace, let options else { return }
        recordingLimit?.cancel(); recordingLimit = nil
        isBusy = true; phase = "Transcribing"; let stopped = ProcessInfo.processInfo.systemUptime
        overlay.show("Transcribing", detail: "Local speech recognition · Esc to cancel", actions: [cancelAction])
        task = Task {
            defer { finish(id) }
            var captureStopped = false
            do {
                let session = try await capture.stop(incomplete: interrupted); self.capture = nil
                captureStopped = true
                try Task.checkCancellation()
                _ = try await process(session, directory: workspace.directory, options: options, id: id, stopped: stopped)
            } catch {
                self.capture = nil; insertion.clear()
                metrics.reason = Task.isCancelled ? "cancelled" : (captureStopped ? "processing_failed" : "capture_failed")
                metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
                notice = Task.isCancelled ? "Dictation cancelled." : (captureStopped ? "Speech processing failed. No text was inserted." : "Microphone capture could not finish. No text was inserted.")
                if Task.isCancelled { clearRecovery() }
                else { overlay.show(captureStopped ? "Processing failed" : "Capture failed", detail: notice, actions: [dismissAction], dismissAfter: true) }
            }
        }
    }
    func cancel() {
        metrics.reason = "cancelled"
        recordingLimit?.cancel(); recordingLimit = nil; insertion.clear(); clearRecovery()
        if recording, let capture, let id = operationID {
            isBusy = true; phase = "Cancelling"
            task = Task {
                _ = try? await capture.stop(incomplete: "Temporary input cancelled")
                self.capture = nil; notice = "Dictation cancelled."; finish(id)
            }
        } else { task?.cancel() }
    }
    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        insertion.clear(); operationID = nil; options = nil; task = nil; recordingLimit?.cancel(); recordingLimit = nil; isBusy = false; phase = "Ready"; setCancellation?(false)
        if let workspace {
            do { try workspace.remove(); self.workspace = nil }
            catch { metrics.temporaryAudioRemoved = false; notice = "Temporary audio cleanup failed. Another recording is blocked until cleanup succeeds." }
        }
        // Static reason codes and scalar timings/counts only. Never interpolate
        // ASR/output strings, field/clipboard contents, dictionary or paths.
        logger.info("dictation_finished reason=\(self.metrics.reason, privacy: .public) delivery=\(self.metrics.deliveryReason, privacy: .public) recognized_bytes=\(self.metrics.recognizedBytes, privacy: .public) missing_intervals=\(self.metrics.missingIntervals, privacy: .public) microphone_peak=\(self.metrics.microphonePeak, privacy: .public) asr_ms=\(self.metrics.recognitionMilliseconds, privacy: .public) cleanup_ms=\(self.metrics.cleanupMilliseconds, privacy: .public) inserted=\(self.metrics.inserted, privacy: .public) audio_removed=\(self.metrics.temporaryAudioRemoved, privacy: .public)")
    }
    private func process(_ session: RecordingSession, directory: URL, options: AppPreferences.Snapshot, id: UUID, stopped: Double, forcePaste: Bool = false) async throws -> FixtureResult {
        var version = TranscriptVersion(model: RecognitionService.identity, language: options.language, segments: [], coverage: session.coverage)
        let recognitionStart = ProcessInfo.processInfo.systemUptime
        metrics.missingIntervals = session.coverage.filter { [.missing, .failed].contains($0.state) }.count
        let captureComplete = session.status != .incomplete && metrics.missingIntervals == 0
        var complete = captureComplete
        var recognitionFailed = false
        logger.info("dictation_recognition_started missing_intervals=\(self.metrics.missingIntervals, privacy: .public) capture_complete=\(captureComplete, privacy: .public)")
        for index in version.coverage.indices {
            try Task.checkCancellation()
            guard let file = version.coverage[index].file else { complete = false; continue }
            do {
                let recognized = try await recognition.transcribe(file: directory.appendingPathComponent(file), interval: version.coverage[index], language: options.language, dictionary: options.dictionary)
                version.segments += recognized.segments
                if !recognized.detectedSilence && recognized.segments.isEmpty { complete = false }
                version.coverage[index].state = recognized.detectedSilence ? .silence : .processed
            } catch is CancellationError { throw CancellationError() }
            catch { recognitionFailed = true; complete = false; version.coverage[index].state = .failed }
        }
        metrics.recognitionMilliseconds = (ProcessInfo.processInfo.systemUptime - recognitionStart) * 1000
        complete = complete && !session.coverage.contains { [.missing, .failed].contains($0.state) }
        let raw = version.text
        metrics.recognizedBytes = raw.utf8.count
        guard raw.utf8.count <= Self.maximumTextBytes else { throw TalkieError.message("Temporary text limit exceeded.") }
        guard complete, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
            let title: String
            if recognitionFailed { metrics.reason = "asr_failed"; title = "ASR failed"; notice = "Local ASR failed. Check the speech model in Settings; nothing inserted." }
            else if !captureComplete { metrics.reason = "incomplete_capture"; title = "Capture interrupted"; notice = "Microphone capture had missing audio or was interrupted; nothing inserted." }
            else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metrics.reason = "empty_asr"
                let silent = metrics.microphoneObserved && metrics.microphonePeak < 0.001
                title = silent ? "Microphone silent" : "No speech recognized"
                notice = silent ? "No microphone signal was captured. Check the macOS input device and mute state." : "The speech model returned no recognizable speech. Try a clear, complete phrase."
            } else { metrics.reason = "incomplete_asr"; title = "Recognition incomplete"; notice = "Some audio could not be recognized; nothing inserted." }
            recover(raw, outcome: .preview(notice), title: title); return FixtureResult(raw: raw, output: raw, metrics: metrics, message: notice)
        }
        var output = raw; var withoutCleanup = false
        if options.cleanupEnabled {
            phase = "Cleaning"; overlay.show("Cleaning", detail: "Local cleanup and corrections · Esc to cancel", actions: [cancelAction])
            let cleanupStart = ProcessInfo.processInfo.systemUptime
            do {
                await recognition.unload()
                let (edited, _) = try await boundedCleanup(raw, options: options)
                if edited.text.utf8.count <= Self.maximumTextBytes, DictationInsertionPolicy.cleanupCanInsert(original: raw, edited: edited.text, needsReview: edited.needs_review, model: options.cleanupModel) { output = edited.text }
                else { withoutCleanup = true; metrics.reason = "cleanup_rejected_raw_fallback" }
            } catch {
                try Task.checkCancellation()
                withoutCleanup = true; metrics.reason = "cleanup_unavailable_raw_fallback"
            }
            metrics.cleanupMilliseconds = (ProcessInfo.processInfo.systemUptime - cleanupStart) * 1000
        }
        try Task.checkCancellation(); guard operationID == id else { throw CancellationError() }
        let outcome: TextInsertionService.Outcome
        if options.autoInsert == false { insertion.clear(); outcome = .preview("Auto Insert is OFF. Enable it in the talkie menu.", failure: .autoInsertOff) }
        else { outcome = await insertion.insert(output, operationID: id, forcePasteForDiagnostic: forcePaste) }
        metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
        metrics.inserted = outcome.inserted; metrics.uncertain = outcome.uncertain
        metrics.deliveryReason = outcome.failure.rawValue
        metrics.stopToInsertMilliseconds = outcome.inserted ? metrics.stopToOutcomeMilliseconds : nil
        // Cancellation can arrive while bounded delivery verification awaits.
        // Do not resurrect preview text after Cancel already cleared recovery.
        guard !Task.isCancelled, operationID == id else {
            metrics.reason = "cancelled"; clearRecovery()
            notice = outcome.uncertain || outcome.inserted ? "Cancelled during delivery. Check the editor; no retry." : "Dictation cancelled."
            return FixtureResult(raw: "", output: "", metrics: metrics, message: notice)
        }
        if !outcome.inserted { metrics.reason = outcome.failure.rawValue }
        else if metrics.reason == "idle" { metrics.reason = "inserted" }
        notice = outcome.inserted && withoutCleanup ? "Inserted without cleanup." : outcome.message
        if outcome.inserted {
            clearRecovery()
            if withoutCleanup { overlay.show("Inserted without cleanup", detail: notice, dismissAfter: true) }
        }
        else { recover(output, outcome: outcome) }
        return FixtureResult(raw: raw, output: output, metrics: metrics, message: notice)
    }
    private func boundedCleanup(_ raw: String, options: AppPreferences.Snapshot) async throws -> (LocalTextService.CleanupResponse, LocalTextService.ModelIdentity) {
        try await withThrowingTaskGroup(of: (LocalTextService.CleanupResponse, LocalTextService.ModelIdentity).self) { group in
            group.addTask { [textService] in try await textService.cleanup(raw, model: options.cleanupModel, digest: options.cleanupDigest) }
            group.addTask { try await Task.sleep(for: .seconds(12)); throw TalkieError.message("Cleanup timeout") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private var cancelAction: RecordingOverlay.Action { .init(title: "Cancel", handler: { [weak self] in self?.cancel() }) }
    private var dismissAction: RecordingOverlay.Action { .init(title: "Dismiss", handler: { [weak self] in self?.clearRecovery() }) }
    private func recover(_ text: String, outcome: TextInsertionService.Outcome, title: String? = nil) {
        let title = title ?? outcome.failure.title
        clearRecovery(); guard !text.isEmpty else { overlay.show(title, detail: outcome.message, dismissAfter: true); return }
        guard recovery.replace(text), let id = recovery.id else { return }
        recoveryMessage = outcome.message; recoveryUncertain = outcome.uncertain
        // A sent but unconfirmed write may already be in the editor. Never cover
        // it with text/Copy controls or encourage a duplicate. Recovery is opt-in
        // from the menu bar and retains the same one-result, 60-second lifetime.
        overlay.show(title, detail: outcome.message + " Recovery is available in the talkie menu for 60 seconds.", dismissAfter: true)
        recoveryExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.recoverySeconds)); guard let self, self.recovery.id == id else { return }; self.clearRecovery() } catch {}
        }
    }
    func showRecovery() {
        recovery.expire()
        guard let text = recovery.text, let id = recovery.id else { clearRecovery(); return }
        var actions = [RecordingOverlay.Action(title: "Copy", handler: { [weak self] in
            guard let self else { return }
            guard let text = self.recovery.take(id: id) else { self.clearRecovery(); return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); self.clearRecovery()
        })]
        if canRestoreClipboard { actions.append(.init(title: "Restore Clipboard", handler: { [weak self] in self?.restoreClipboard() })) }
        actions.append(dismissAction)
        overlay.show(recoveryUncertain ? "Check editor before copying" : "Temporary recovery", detail: recoveryMessage, actions: actions, preview: text)
    }
    func clearRecovery() { recoveryExpiry?.cancel(); recoveryExpiry = nil; recovery.clear(); recoveryMessage = ""; recoveryUncertain = false; overlay.hide() }
    func restoreClipboard() { notice = insertion.restoreClipboard() ? "Previous clipboard restored." : "Newer clipboard contents preserved." }
    /// Isolates Accessibility/Paste from speech recognition with a fixed known
    /// string and disposable target guard. Never runs on ordinary dictation.
    func runInsertionFixture(allowedValues: [String], forcePaste: Bool = false, processingDelay: Double = 0, requiredPID: pid_t? = nil) async throws -> Metrics {
        guard !isActive else { throw TalkieError.message("Voice input is already active.") }
        clearRecovery(); let id = UUID(); operationID = id; metrics = Metrics(); isBusy = true
        defer { finish(id) }
        insertion.capture(operationID: id, allowDestination: !allowedValues.isEmpty, requiredPID: requiredPID)
        overlay.anchor = insertion.overlayAnchor
        if !allowedValues.contains(insertion.target?.value ?? "") { insertion.reject("Disposable fixture is not the active verified destination.") }
        if processingDelay > 0 { try await Task.sleep(for: .seconds(processingDelay)) }
        try Task.checkCancellation(); let start = ProcessInfo.processInfo.systemUptime
        let text = "talkie fixture — café 日本語"
        let outcome = await insertion.insert(text, operationID: id, forcePasteForDiagnostic: forcePaste)
        metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metrics.inserted = outcome.inserted; metrics.uncertain = outcome.uncertain
        metrics.deliveryReason = outcome.failure.rawValue
        metrics.reason = outcome.inserted ? "fixed_fixture_inserted" : "fixed_fixture_target_unavailable_or_uncertain"
        notice = outcome.message
        if outcome.inserted { clearRecovery() }
        else { recover(text, outcome: outcome) }
        return metrics
    }
    /// Explicit, synthetic-only harness; production ASR/cleanup/delivery is reused.
    func runFixture(file: URL, allowedValues: [String], forcePaste: Bool = false, requiredPID: pid_t? = nil) async throws -> FixtureResult {
        guard !isActive else { throw TalkieError.message("Voice input is already active.") }
        clearRecovery(); let id = UUID(); operationID = id; metrics = Metrics(); isBusy = true; options = preferences.snapshot
        insertion.capture(operationID: id, allowDestination: !allowedValues.isEmpty, requiredPID: requiredPID)
        overlay.anchor = insertion.overlayAnchor
        if !allowedValues.contains(insertion.target?.value ?? "") { insertion.reject("Disposable fixture is not the active verified destination.") }
        defer { finish(id) }
        let space = try TransientDictationAudio(); workspace = space
        let input = space.directory.appendingPathComponent("synthetic.aiff"); try FileManager.default.copyItem(at: file, to: input)
        let audio = try AVAudioFile(forReading: input)
        var session = RecordingSession(title: "Synthetic transient input", kind: .dictation, sources: [.microphone]); session.status = .saved
        session.coverage = [.init(source: .microphone, start: 0, end: Double(audio.length) / audio.fileFormat.sampleRate, state: .pending, file: input.lastPathComponent)]
        var result = try await process(session, directory: space.directory, options: options!, id: id, stopped: ProcessInfo.processInfo.systemUptime, forcePaste: forcePaste)
        finish(id); result.metrics = metrics; return result
    }
}
