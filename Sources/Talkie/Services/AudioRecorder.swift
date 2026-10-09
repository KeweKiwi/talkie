import AVFoundation
import ScreenCaptureKit
import CoreMedia
import TalkieCore

final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.kewekiwi.talkie.audio", qos: .userInitiated)
    private var writer: AudioChunkWriter?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private let slots = DispatchSemaphore(value: 16)
    private var failed = false
    var onMeters: (([AudioSource: Float]) -> Void)?
    var onFailure: ((String) -> Void)?
    static func requestMicrophone() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw TalkieError.message("Microphone access was denied. Enable talkie in System Settings → Privacy & Security → Microphone.") }
    }
    @MainActor func start(session: RecordingSession, repository: SessionRepository? = nil, transientDirectory: URL? = nil, microphoneID: String, systemApp: pid_t?) async throws {
        try await Self.requestMicrophone()
        let startHost = ProcessInfo.processInfo.systemUptime
        if let repository { writer = try AudioChunkWriter(session: session, repository: repository, startHost: startHost) }
        else if let transientDirectory { writer = AudioChunkWriter(session: session, directory: transientDirectory, startHost: startHost) }
        else { throw TalkieError.message("No audio destination available.") }
        writer?.onMeters = onMeters; failed = false
        do {
            if session.sources.contains(.system) {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let display = content.displays.first else { throw TalkieError.message("No capturable display is available.") }
                let filter: SCContentFilter
                if let systemApp {
                    guard let app = content.applications.first(where: { $0.processID == systemApp }) else { throw TalkieError.message("The selected application is no longer available.") }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                    writer?.session.sourceIDs[AudioSource.system.rawValue] = app.bundleIdentifier
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
                    writer?.session.sourceIDs[AudioSource.system.rawValue] = "all system audio excluding talkie"
                }
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1); config.queueDepth = 3
                config.capturesAudio = true; config.captureMicrophone = true; config.sampleRate = 48_000; config.channelCount = 2; config.excludesCurrentProcessAudio = true
                if !microphoneID.isEmpty { config.microphoneCaptureDeviceID = microphoneID }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                // No .screen output is registered. No screen frames are saved or read.
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
                writer?.session.sourceIDs[AudioSource.microphone.rawValue] = microphoneID.isEmpty ? "system default microphone" : microphoneID
                try Task.checkCancellation()
                self.stream = stream; try await stream.startCapture()
            } else {
                let engine = AVAudioEngine(); let node = engine.inputNode
                // Microphone-only uses the system default. Explicit device selection is
                // supported by ScreenCaptureKit for online meetings, never silently rerouted.
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw TalkieError.message("No microphone input is available.") }
                writer?.session.sourceIDs[AudioSource.microphone.rawValue] = "system default microphone"
                node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
                    guard let self else { return }
                    guard self.slots.wait(timeout: .now()) == .success else { self.reportFailure("Audio queue overflow; recording stopped with recoverable chunks."); return }
                    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { self.slots.signal(); self.reportFailure("Audio buffer allocation failed."); return }
                    copy.frameLength = buffer.frameLength
                    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    let dest = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for i in 0..<source.count { if let s = source[i].mData, let d = dest[i].mData { memcpy(d, s, Int(source[i].mDataByteSize)) } }
                    let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                    self.queue.async { defer { self.slots.signal() }; self.consume(copy, source: .microphone, host: host) }
                }
                self.engine = engine; engine.prepare(); try engine.start()
            }
        } catch {
            engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; stream = nil
            _ = try? writer?.finish(incomplete: "Capture did not start: \(error.localizedDescription)"); throw error
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let desc = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples), into: buffer.mutableAudioBufferList)
        guard status == noErr else { reportFailure("System audio format changed or could not be decoded."); return }
        let host = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard host.isFinite else { reportFailure("Invalid source timestamp."); return }
        consume(buffer, source: type == .microphone ? .microphone : .system, host: host)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { reportFailure("Capture interrupted: \(error.localizedDescription)") }
    private func consume(_ buffer: AVAudioPCMBuffer, source: AudioSource, host: Double) {
        guard !failed else { return }
        do { try writer?.consume(buffer, source: source, hostSeconds: host) } catch { failed = true; onFailure?("Audio could not be saved: \(error.localizedDescription)") }
    }
    private func reportFailure(_ text: String) { queue.async { if !self.failed { self.failed = true; self.onFailure?(text) } } }
    func pause() async throws { try await onQueue { try self.writer?.pause() } }
    func resume() async throws { try await onQueue { try self.writer?.resume() } }
    func muteMicrophone(_ muted: Bool) async throws { try await onQueue { try self.writer?.muteMicrophone(muted) } }
    @MainActor func stop(incomplete: String? = nil) async throws -> RecordingSession {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        var failure = incomplete
        if let stream { do { try await stream.stopCapture() } catch { failure = failure ?? error.localizedDescription } }
        stream = nil
        let reason = failure
        return try await onQueue {
            guard let writer = self.writer else { throw TalkieError.message("No active recording.") }
            let session = try writer.finish(incomplete: reason); self.writer = nil; return session
        }
    }
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) } } }
    }
}
