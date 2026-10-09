import AppKit
import AVFoundation
import Observation
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
    }
    struct FixtureResult { var raw: String; var output: String; var metrics: Metrics; var message: String }
    private let preferences: AppPreferences
    private let recognition: RecognitionService
    private let textService: LocalTextService
    private let insertion = TextInsertionService()
    private let overlay = RecordingOverlay()
    private var capture: AudioRecorder?
    private var workspace: TransientDictationAudio?
    private var task: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var recoveryExpiry: Task<Void, Never>?
    private var recovery = TransientRecovery()
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
        releaseWhileStarting = false; captureFailed = false; isBusy = true; phase = "Starting"; setCancellation?(true)
        overlay.show("Starting", detail: "Microphone · Esc to cancel", actions: [cancelAction])
        let microphoneID = options?.microphoneID ?? ""
        task = Task {
            var localCapture: AudioRecorder?
            do {
                let space = try TransientDictationAudio(); workspace = space
                let session = RecordingSession(title: "Temporary voice input", kind: .dictation, sources: [.microphone])
                let recorder = AudioRecorder(); localCapture = recorder
                recorder.onFailure = { [weak self] _ in Task { @MainActor in
                    guard let self, self.operationID == id else { return }; self.captureFailed = true; self.stop(interrupted: "Microphone capture was interrupted.")
                } }
                try await recorder.start(session: session, transientDirectory: space.directory, microphoneID: microphoneID, systemApp: nil)
                try Task.checkCancellation(); if captureFailed { throw TalkieError.message("Microphone capture was interrupted.") }; guard operationID == id else { throw CancellationError() }
                capture = recorder; localCapture = nil; isBusy = false; phase = "Recording"
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
                    overlay.show("Could not start", detail: notice, actions: [dismissAction])
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
            do {
                let session = try await capture.stop(incomplete: interrupted); self.capture = nil
                try Task.checkCancellation()
                _ = try await process(session, directory: workspace.directory, options: options, id: id, stopped: stopped)
            } catch {
                self.capture = nil; insertion.clear()
                metrics.reason = Task.isCancelled ? "cancelled" : "processing_failed"
                metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
                notice = Task.isCancelled ? "Dictation cancelled." : "Speech recognition failed. No text was inserted."
                if Task.isCancelled { clearRecovery() }
                else { overlay.show("No insertion", detail: notice, actions: [dismissAction]) }
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
    }
    private func process(_ session: RecordingSession, directory: URL, options: AppPreferences.Snapshot, id: UUID, stopped: Double, forcePaste: Bool = false) async throws -> FixtureResult {
        var version = TranscriptVersion(model: RecognitionService.identity, language: options.language, segments: [], coverage: session.coverage)
        let recognitionStart = ProcessInfo.processInfo.systemUptime
        var complete = session.status != .incomplete
        var recognitionFailed = false
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
        guard raw.utf8.count <= Self.maximumTextBytes else { throw TalkieError.message("Temporary text limit exceeded.") }
        guard complete, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
            notice = recognitionFailed ? "Local ASR failed. Check the pinned speech model in Settings; nothing inserted." : (complete ? "No speech was recognized; nothing inserted." : "Capture or speech recognition was incomplete; nothing inserted.")
            metrics.reason = recognitionFailed ? "asr_failed" : (complete ? "empty_asr" : "incomplete_asr")
            recover(raw, outcome: .preview(notice)); return FixtureResult(raw: raw, output: raw, metrics: metrics, message: notice)
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
        if options.autoInsert == false { insertion.clear(); outcome = .preview("Auto Insert is OFF.") }
        else { outcome = await insertion.insert(output, operationID: id, forcePasteForDiagnostic: forcePaste) }
        metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
        metrics.inserted = outcome.inserted; metrics.uncertain = outcome.uncertain
        metrics.stopToInsertMilliseconds = outcome.inserted ? metrics.stopToOutcomeMilliseconds : nil
        // Cancellation can arrive while bounded delivery verification awaits.
        // Do not resurrect preview text after Cancel already cleared recovery.
        guard !Task.isCancelled, operationID == id else {
            metrics.reason = "cancelled"; clearRecovery()
            notice = outcome.uncertain || outcome.inserted ? "Cancelled during delivery. Check the editor; no retry." : "Dictation cancelled."
            return FixtureResult(raw: "", output: "", metrics: metrics, message: notice)
        }
        if metrics.reason == "idle" { metrics.reason = outcome.inserted ? "inserted" : "target_unavailable_or_uncertain" }
        notice = outcome.inserted && withoutCleanup ? "Inserted without cleanup." : outcome.message
        if outcome.inserted { clearRecovery(); overlay.show("Inserted", detail: notice, dismissAfter: true) }
        else { recover(output, outcome: .preview(notice, uncertain: outcome.uncertain)) }
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
    private func recover(_ text: String, outcome: TextInsertionService.Outcome) {
        clearRecovery(); guard !text.isEmpty else { overlay.show("No insertion", detail: outcome.message, actions: [dismissAction]); return }
        guard recovery.replace(text), let id = recovery.id else { return }
        var actions = [RecordingOverlay.Action(title: "Copy", handler: { [weak self] in
            guard let self, let text = self.recovery.take(id: id) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); self.clearRecovery()
        })]
        if canRestoreClipboard { actions.append(.init(title: "Restore Clipboard", handler: { [weak self] in self?.restoreClipboard() })) }
        actions.append(dismissAction)
        overlay.show(outcome.uncertain ? "Check editor before copying" : "Temporary recovery", detail: outcome.message + " Expires in 60 seconds.", actions: actions, preview: text)
        recoveryExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.recoverySeconds)); guard let self, self.recovery.id == id else { return }; self.clearRecovery() } catch {}
        }
    }
    func clearRecovery() { recoveryExpiry?.cancel(); recoveryExpiry = nil; recovery.clear(); overlay.hide() }
    func restoreClipboard() { notice = insertion.restoreClipboard() ? "Previous clipboard restored." : "Newer clipboard contents preserved." }
    /// Isolates Accessibility/Paste from speech recognition with a fixed known
    /// string and disposable target guard. Never runs on ordinary dictation.
    func runInsertionFixture(allowedValues: [String], forcePaste: Bool = false, processingDelay: Double = 0) async throws -> Metrics {
        guard !isActive else { throw TalkieError.message("Voice input is already active.") }
        clearRecovery(); let id = UUID(); operationID = id; metrics = Metrics(); isBusy = true
        defer { finish(id) }
        insertion.capture(operationID: id)
        if !allowedValues.contains(insertion.target?.value ?? "") { insertion.reject("Disposable fixture is not the active verified destination.") }
        if processingDelay > 0 { try await Task.sleep(for: .seconds(processingDelay)) }
        try Task.checkCancellation(); let start = ProcessInfo.processInfo.systemUptime
        let text = "talkie fixture — café 日本語"
        let outcome = await insertion.insert(text, operationID: id, forcePasteForDiagnostic: forcePaste)
        metrics.stopToOutcomeMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metrics.inserted = outcome.inserted; metrics.uncertain = outcome.uncertain
        metrics.reason = outcome.inserted ? "fixed_fixture_inserted" : "fixed_fixture_target_unavailable_or_uncertain"
        notice = outcome.message
        if outcome.inserted { overlay.show("Inserted", detail: notice, dismissAfter: true) }
        else { recover(text, outcome: outcome) }
        return metrics
    }
    /// Explicit, synthetic-only harness; production ASR/cleanup/delivery is reused.
    func runFixture(file: URL, allowedValues: [String], forcePaste: Bool = false) async throws -> FixtureResult {
        guard !isActive else { throw TalkieError.message("Voice input is already active.") }
        clearRecovery(); let id = UUID(); operationID = id; metrics = Metrics(); isBusy = true; options = preferences.snapshot
        insertion.capture(operationID: id)
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
