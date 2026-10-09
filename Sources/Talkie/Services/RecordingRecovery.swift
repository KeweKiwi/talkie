import Foundation
import AVFoundation
import TalkieCore

struct RecordingRecovery {
    static func recover(_ input: RecordingSession, repository: SessionRepository) throws -> RecordingSession {
        var session = input
        guard [.recording, .paused, .transcribing].contains(session.status) else { return session }
        let files = try FileManager.default.contentsOfDirectory(at: repository.directory(session.id), includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        let known = Set(session.coverage.compactMap(\.file))
        for file in files where !known.contains(file.lastPathComponent) {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)
            guard parts.count == 3, let source = AudioSource(rawValue: String(parts[0])), let microseconds = Double(parts[1]) else { continue }
            let start = microseconds / 1_000_000
            if let audio = try? AVAudioFile(forReading: file), audio.length > 0 {
                session.coverage.append(CaptureInterval(source: source, start: start, end: start + Double(audio.length) / audio.fileFormat.sampleRate, state: .pending, file: file.lastPathComponent, note: "Recovered after interruption"))
            } else { session.coverage.append(CaptureInterval(source: source, start: start, end: max(start, session.duration), state: .missing, file: file.lastPathComponent, note: "Interrupted chunk has no readable samples")) }
        }
        if let draft = session.draftTranscript { session.versions.append(draft); session.draftTranscript = nil }
        session.duration = max(session.duration, session.coverage.map(\.end).max() ?? 0)
        session.status = .incomplete; session.error = "Recovered interrupted session. Valid chunks are retained; final unsaved audio may be missing. Transcribe again to process pending chunks."
        for source in session.sources { session.coverage.append(CaptureInterval(source: source, start: session.duration, end: session.duration, state: .missing, note: "End of interrupted capture is unknown")) }
        try repository.save(session); return session
    }
}
