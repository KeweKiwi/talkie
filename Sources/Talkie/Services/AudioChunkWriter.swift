import AVFoundation
import CoreMedia
import TalkieCore

/// Owned exclusively by the recorder's serial audio queue. No inference here.
final class AudioChunkWriter {
    struct OpenChunk { var interval: CaptureInterval; var file: AVAudioFile; var frames: Int64 = 0 }
    let repository: SessionRepository
    var session: RecordingSession
    let startHost: Double
    private let clock: () -> Double
    private var open: [AudioSource: OpenChunk] = [:]
    private var converters: [AudioSource: AVAudioConverter] = [:]
    private var previousEnd: [AudioSource: Double] = [:]
    private var pausedAt: Double?
    private var mutedAt: Double?
    private var lastMeter: Double = 0
    var onMeters: (([AudioSource: Float]) -> Void)?
    private var meters: [AudioSource: Float] = [:]
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    init(session: RecordingSession, repository: SessionRepository, startHost: Double, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        self.session = session; self.repository = repository; self.startHost = startHost; self.clock = clock
        try repository.save(session)
    }
    var elapsed: Double { max(0, clock() - startHost) }
    func consume(_ input: AVAudioPCMBuffer, source: AudioSource, hostSeconds: Double) throws {
        guard pausedAt == nil, !(source == .microphone && mutedAt != nil) else { return }
        let offset = max(0, hostSeconds - startHost)
        if let last = previousEnd[source], offset - last > 0.5 { try flush(source); session.coverage.append(CaptureInterval(source: source, start: last, end: offset, state: .missing, note: "Capture callback gap")) }
        else if previousEnd[source] == nil && offset > 0.75 { session.coverage.append(CaptureInterval(source: source, start: 0, end: offset, state: .missing, note: "Source started late")) }
        guard let buffer = try convert(input, source: source), buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0; for i in 0..<count { sum += samples[i] * samples[i] }
            meters[source] = min(1, sqrt(sum / Float(max(1, count))) * 5)
        }
        if elapsed - lastMeter > 0.15 { onMeters?(meters); lastMeter = elapsed }
        if open[source] == nil {
            let name = "\(source.rawValue)-\(Int64(offset * 1_000_000))-\(UUID().uuidString).wav"
            let url = repository.directory(session.id).appendingPathComponent(name)
            let file = try AVAudioFile(forWriting: url, settings: output.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            open[source] = OpenChunk(interval: CaptureInterval(source: source, start: offset, end: offset, state: .pending, file: name), file: file)
        }
        guard var chunk = open[source] else { return }
        try chunk.file.write(from: buffer)
        chunk.frames += Int64(buffer.frameLength); chunk.interval.end = chunk.interval.start + Double(chunk.frames) / 16_000
        open[source] = chunk
        previousEnd[source] = offset + Double(buffer.frameLength) / 16_000
        if chunk.frames >= 16_000 * 15 { try flush(source) }
    }
    private func convert(_ input: AVAudioPCMBuffer, source: AudioSource) throws -> AVAudioPCMBuffer? {
        if input.format == output { return input }
        if converters[source]?.inputFormat != input.format { converters[source] = AVAudioConverter(from: input.format, to: output) }
        guard let converter = converters[source] else { throw TalkieError.message("Unsupported audio format; recording is recoverable.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 64)
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw TalkieError.message("Audio conversion allocation failed.") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? TalkieError.message("Audio conversion failed.") as NSError }
        return result
    }
    func flush(_ source: AudioSource) throws {
        guard open[source] != nil else { return }
        var chunk = open.removeValue(forKey: source)
        var interval = chunk!.interval
        // Release AVAudioFile before syncing so the WAV header is finalized.
        let name = interval.file!
        interval.end = interval.start + Double(chunk!.frames) / 16_000
        chunk = nil
        // Synchronize finalized audio before metadata lists it as durable.
        // A crash before the metadata save leaves an orphan for recovery.
        let handle = try FileHandle(forWritingTo: repository.directory(session.id).appendingPathComponent(name))
        try handle.synchronize(); try handle.close()
        session.coverage.append(interval)
        session.duration = elapsed
        try repository.save(session)
    }
    func pause() throws {
        guard pausedAt == nil else { return }
        for source in session.sources { try flush(source) }
        pausedAt = elapsed; session.status = .paused; try repository.save(session)
    }
    func resume() throws {
        guard let start = pausedAt else { return }
        for source in session.sources { session.coverage.append(CaptureInterval(source: source, start: start, end: elapsed, state: .paused, note: "Deliberately paused")); previousEnd[source] = elapsed }
        pausedAt = nil; session.status = .recording; try repository.save(session)
    }
    func muteMicrophone(_ muted: Bool) throws {
        if muted && mutedAt == nil { try flush(.microphone); mutedAt = elapsed }
        else if !muted, let start = mutedAt { session.coverage.append(CaptureInterval(source: .microphone, start: start, end: elapsed, state: .paused, note: "Recorder microphone muted")); mutedAt = nil; previousEnd[.microphone] = elapsed; try repository.save(session) }
    }
    func finish(incomplete: String? = nil) throws -> RecordingSession {
        try resume(); try muteMicrophone(false)
        for source in session.sources {
            try flush(source)
            let end = previousEnd[source] ?? 0
            if elapsed - end > 0.75 { session.coverage.append(CaptureInterval(source: source, start: end, end: elapsed, state: .missing, note: "Source stopped or no buffers received")) }
        }
        session.duration = max(elapsed, session.coverage.map(\.end).max() ?? 0); session.status = incomplete == nil ? .saved : .incomplete; session.error = incomplete
        try repository.save(session); return session
    }
}
