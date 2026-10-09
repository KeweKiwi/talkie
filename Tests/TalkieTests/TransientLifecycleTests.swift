import XCTest
import AVFoundation
@testable import Talkie
import TalkieCore

final class TransientLifecycleTests: XCTestCase {
    func testSharedWriterUsesOnlyTemporaryAudioAndRemovesEveryOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for reason in [nil, "Synthetic interruption", "Synthetic cancellation"] as [String?] {
            let workspace = try TransientDictationAudio(root: root)
            let session = RecordingSession(title: "Synthetic transient", kind: .dictation, sources: [.microphone])
            var now = 100.0
            let writer = AudioChunkWriter(session: session, directory: workspace.directory, startHost: now, clock: { now })
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for index in 0..<1600 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.1) * 0.01 }
            try writer.consume(buffer, source: .microphone, hostSeconds: now); now += 0.1
            let result = try writer.finish(incomplete: reason)
            let files = try FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].pathExtension, "wav")
            XCTAssertGreaterThan(try AVAudioFile(forReading: files[0]).length, 0)
            XCTAssertEqual(result.status, reason == nil ? .saved : .incomplete)
            try workspace.remove(); XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testOrphansOnlyDeleteOwnedDeadProcessDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alive = try TransientDictationAudio(root: root)
        let dead = root.appendingPathComponent("2000000000-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: false)
        try Data([1, 2]).write(to: dead.appendingPathComponent("synthetic.wav"))
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("2000000001-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        try TransientDictationAudio.removeOrphans(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        let rootLink = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootLink) }
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertThrowsError(try TransientDictationAudio.removeOrphans(root: rootLink))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.directory.path))
    }
    func testExplicitLegacyMigrationPreservesMeetingFilesByteForByte() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try SessionRepository(root: root)
        let meeting = RecordingSession(title: "Synthetic meeting", kind: .meeting, sources: [.microphone, .system])
        let old = RecordingSession(title: "Synthetic legacy dictation", kind: .dictation, sources: [.microphone])
        try repo.save(meeting); try repo.save(old)
        let meetingAudio = repo.directory(meeting.id).appendingPathComponent("synthetic.wav")
        try Data([1, 2, 3]).write(to: meetingAudio)
        try Data([4, 5]).write(to: repo.directory(old.id).appendingPathComponent("synthetic.wav"))
        let metadata = try Data(contentsOf: repo.directory(meeting.id).appendingPathComponent("session.json"))
        XCTAssertEqual(try repo.deleteLegacyDictations(), 1)
        XCTAssertEqual(try repo.load().map(\.id), [meeting.id])
        XCTAssertEqual(try Data(contentsOf: meetingAudio), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: repo.directory(meeting.id).appendingPathComponent("session.json")), metadata)
        XCTAssertEqual(try repo.deleteLegacyDictations(), 0)
    }
    @MainActor func testStaleDeliveryDoesNotConsumeNewOperation() async {
        let service = TextInsertionService(permissionCheck: { false })
        let old = UUID(), current = UUID()
        service.capture(operationID: old); service.capture(operationID: current)
        let stale = await service.insert("Synthetic", operationID: old)
        XCTAssertFalse(stale.inserted); XCTAssertTrue(stale.message.contains("Stale"))
        let next = await service.insert("Synthetic", operationID: current)
        XCTAssertFalse(next.inserted); XCTAssertTrue(next.message.contains("Accessibility"))
    }
}
