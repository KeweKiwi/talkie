import XCTest
@testable import TalkieCore

final class CoreTests: XCTestCase {
    func fixture() -> (RecordingSession, TranscriptVersion) {
        let chunk = UUID()
        let intervals = [CaptureInterval(source: .microphone, start: 0, end: 30, state: .processed), CaptureInterval(source: .system, start: 30, end: 40, state: .failed, note: "synthetic failure"), CaptureInterval(source: .microphone, start: 60, end: 70, state: .missing, note: "capture gap"), CaptureInterval(source: .system, start: 80, end: 90, state: .paused)]
        let segments = [TranscriptSegment(id: "begin", chunkID: chunk, source: .microphone, start: 1, end: 2, text: "BEGIN — Rina 日本語"), TranscriptSegment(id: "middle", chunkID: chunk, source: .system, start: 50, end: 51, text: "MIDDLE Payload CMS"), TranscriptSegment(id: "end", chunkID: chunk, source: .microphone, start: 100, end: 101, text: "END jangan production")]
        var session = RecordingSession(title: "Synthetic fixture", kind: .meeting, sources: [.microphone, .system])
        session.duration = 110
        let version = TranscriptVersion(model: "synthetic", language: .auto, segments: segments.reversed(), coverage: intervals)
        session.versions = [version]; return (session, version)
    }
    func testFullExportIncludesAllSegmentsAndGapStates() throws {
        let (session, version) = fixture()
        let full = TranscriptExporter.full(session: session, version: version)
        for marker in ["BEGIN", "MIDDLE", "END", "FAILED", "MISSING", "PAUSED", "PARTIAL", "日本語"] { XCTAssertTrue(full.contains(marker)) }
        XCTAssertLessThan(full.range(of: "BEGIN")!.lowerBound, full.range(of: "MIDDLE")!.lowerBound)
        XCTAssertLessThan(full.range(of: "MIDDLE")!.lowerBound, full.range(of: "END")!.lowerBound)
        let json = try JSONSerialization.jsonObject(with: TranscriptExporter.json(session: session, version: version)) as! [String: Any]
        XCTAssertEqual((json["transcript"] as! [String: Any])["segments"] as? [[String: Any]] != nil, true)
        let srt = TranscriptExporter.srt(version: version)
        XCTAssertTrue(srt.contains("00:01:40,000")); XCTAssertTrue(srt.contains("FAILED")); XCTAssertTrue(srt.contains("END"))
        XCTAssertFalse(version.accountedFor)
    }
    func testRawVersionsAndSummarySourceSurviveCorrectionRoundtrip() throws {
        var (session, raw) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try SessionRepository(root: root)
        var changed = raw.segments; changed[0].text = "Corrected ending"
        let corrected = TranscriptVersion(parentID: raw.id, isRaw: false, model: raw.model, language: raw.language, segments: changed, coverage: raw.coverage)
        let content = GroundedSummary(overview: [.init(text: "Synthetic claim", references: ["begin"])], discussion: [], decisions: [], actions: [], questions: [])
        session.summaries = [SummaryVersion(transcriptID: raw.id, model: "synthetic", digest: "test", runtime: "test", promptVersion: "test", language: "English", content: content)]
        session.versions.append(corrected); try repo.save(session)
        let loaded = try XCTUnwrap(repo.load().first)
        XCTAssertEqual(loaded.versions.first?.text, raw.text)
        XCTAssertEqual(loaded.versions.last?.parentID, raw.id)
        XCTAssertEqual(loaded.summaries.first?.transcriptID, raw.id)
        XCTAssertNotEqual(loaded.summaries.first?.transcriptID, loaded.latestTranscript?.id)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: repo.directory(session.id).appendingPathComponent("session.json").path)[.posixPermissions] as? Int, 0o600)
    }
    func testCleanupOffSnapshotsDoNotCallEditor() {
        let startSetting = false
        let subsequentSetting = true
        XCTAssertFalse(EditingPolicy.shouldCallEditor(cleanupEnabledAtStart: startSetting))
        XCTAssertTrue(EditingPolicy.shouldCallEditor(cleanupEnabledAtStart: subsequentSetting))
    }
    func testDangerousSemanticChangesAreFlagged() {
        XCTAssertFalse(EditingPolicy.concerns(original: "Jangan deploy ke production. Push staging 16.", edited: "Deploy ke production 60.").isEmpty)
        XCTAssertFalse(EditingPolicy.concerns(original: "Kalau QA lolos, mungkin Jumat", edited: "QA lolos Jumat").isEmpty)
    }
    func testSummaryRejectsFabricatedEvidence() {
        let (_, version) = fixture()
        let summary = GroundedSummary(overview: [.init(text: "Invented", references: ["does-not-exist"])], discussion: [], decisions: [], actions: [], questions: [])
        XCTAssertThrowsError(try summary.validate(against: version))
    }
    func testLargeTranscriptBatchesPreserveEverySegment() throws {
        let (_, original) = fixture(); var version = original
        version.segments = (0..<400).map { i in .init(id: "s\(i)", chunkID: UUID(), source: .microphone, start: Double(i * 15), end: Double(i * 15 + 14), text: String(repeating: "uji ", count: 40)) }
        let batches = try SummaryPolicy.batches(version, characterBudget: 4000)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), version.orderedSegments.map(\.id))
        XCTAssertTrue(TranscriptExporter.full(session: fixture().0, version: version).contains("[s399]"))
    }
    func testDeleteAudioKeepsTextAndDeleteSessionRemovesVersions() throws {
        var (session, _) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }; let repo = try SessionRepository(root: root)
        try repo.save(session); try Data([0, 1]).write(to: repo.directory(session.id).appendingPathComponent("synthetic.wav"))
        try repo.deleteAudio(&session); XCTAssertFalse(session.audioRetained); XCTAssertEqual(try repo.load()[0].versions.count, 1)
        try repo.delete(session.id); XCTAssertTrue(try repo.load().isEmpty)
    }
}
