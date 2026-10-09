import Foundation

public enum RecognitionLanguage: String, Codable, CaseIterable, Sendable {
    case auto, indonesian, english
    public var title: String { switch self { case .auto: "Auto/Mixed"; case .indonesian: "Bahasa Indonesia"; case .english: "English" } }
    public var code: String? { switch self { case .auto: nil; case .indonesian: "id"; case .english: "en" } }
}
public enum AudioSource: String, Codable, CaseIterable, Sendable { case microphone, system }
public enum SessionKind: String, Codable, Sendable { case dictation, meeting }
public enum SessionStatus: String, Codable, Sendable { case recording, paused, saved, transcribing, ready, incomplete }
public enum CoverageState: String, Codable, Sendable { case pending, processed, failed, paused, missing, silence }

public struct CaptureInterval: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var state: CoverageState
    public var file: String?
    public var note: String?
    public init(source: AudioSource, start: Double, end: Double, state: CoverageState, file: String? = nil, note: String? = nil) {
        self.source = source; self.start = start; self.end = end; self.state = state; self.file = file; self.note = note
    }
}
public struct TranscriptSegment: Identifiable, Codable, Sendable {
    public var id: String
    public var chunkID: UUID
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var uncertain: Bool
    public init(id: String = UUID().uuidString, chunkID: UUID, source: AudioSource, start: Double, end: Double, text: String, uncertain: Bool = false) {
        self.id = id; self.chunkID = chunkID; self.source = source; self.start = start; self.end = end; self.text = text; self.uncertain = uncertain
    }
}
public struct TranscriptVersion: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var parentID: UUID?
    public var isRaw: Bool
    public var model: String
    public var language: RecognitionLanguage
    public var segments: [TranscriptSegment]
    public var coverage: [CaptureInterval]
    public init(parentID: UUID? = nil, isRaw: Bool = true, model: String, language: RecognitionLanguage, segments: [TranscriptSegment], coverage: [CaptureInterval]) {
        self.parentID = parentID; self.isRaw = isRaw; self.model = model; self.language = language; self.segments = segments; self.coverage = coverage
    }
    public var text: String { orderedSegments.map(\.text).joined(separator: " ") }
    public var orderedSegments: [TranscriptSegment] { segments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start } }
    public var accountedFor: Bool { !coverage.isEmpty && coverage.allSatisfy { ![.pending, .failed, .missing].contains($0.state) } }
}
public struct EvidenceItem: Codable, Sendable, Equatable {
    public var text: String
    public var references: [String]
    public var owner: String?
    public var deadline: String?
    public init(text: String, references: [String], owner: String? = nil, deadline: String? = nil) {
        self.text = text; self.references = references; self.owner = owner; self.deadline = deadline
    }
}
public struct GroundedSummary: Codable, Sendable {
    public var overview: [EvidenceItem]
    public var discussion: [EvidenceItem]
    public var decisions: [EvidenceItem]
    public var actions: [EvidenceItem]
    public var questions: [EvidenceItem]
    public init(overview: [EvidenceItem], discussion: [EvidenceItem], decisions: [EvidenceItem], actions: [EvidenceItem], questions: [EvidenceItem]) {
        self.overview = overview; self.discussion = discussion; self.decisions = decisions; self.actions = actions; self.questions = questions
    }
    public var allItems: [EvidenceItem] { overview + discussion + decisions + actions + questions }
    public func validate(against transcript: TranscriptVersion) throws {
        let ids = Set(transcript.segments.map(\.id))
        guard !allItems.isEmpty, allItems.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.references.isEmpty && Set($0.references).isSubset(of: ids) }) else {
            throw TalkieError.message("Summary has empty claims or invalid evidence references. Transcript is preserved.")
        }
    }
    public func markdown(transcript: TranscriptVersion) -> String {
        let byID = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        let sections: [(String, [EvidenceItem])] = [("Overview", overview), ("Discussion", discussion), ("Decisions", decisions), ("Action items", actions), ("Open questions", questions)]
        return sections.map { name, items in
            "## \(name)\n\n" + (items.isEmpty ? "None stated." : items.map { item in
                let refs = item.references.compactMap { byID[$0] }.map { "[\(TranscriptExporter.timestamp($0.start)) · \($0.source.rawValue) · \($0.id)]" }.joined(separator: " ")
                let assignment = name == "Action items" ? " Owner: \(item.owner ?? "unknown"); deadline: \(item.deadline ?? "unknown")." : ""
                return "- \(item.text)\(assignment) \(refs)"
            }.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }
}
public struct SummaryVersion: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var transcriptID: UUID
    public var createdAt = Date()
    public var model: String
    public var digest: String
    public var runtime: String
    public var promptVersion: String
    public var language: String
    public var content: GroundedSummary
    public var editedMarkdown: String?
    public init(transcriptID: UUID, model: String, digest: String, runtime: String, promptVersion: String, language: String, content: GroundedSummary) {
        self.transcriptID = transcriptID; self.model = model; self.digest = digest; self.runtime = runtime; self.promptVersion = promptVersion; self.language = language; self.content = content
    }
}
public struct DictationResult: Codable, Sendable {
    public var original: String
    public var cleaned: String?
    public var cleanupRequested: Bool
    public var cleanupStatus: String
    public var model: String?
    public var digest: String?
    public var runtime: String?
    public var promptVersion: String?
    public var reviewedText: String?
    public var usedOriginal = false
    public init(original: String, cleaned: String? = nil, cleanupRequested: Bool, cleanupStatus: String) {
        self.original = original; self.cleaned = cleaned; self.cleanupRequested = cleanupRequested; self.cleanupStatus = cleanupStatus
    }
    public var output: String { usedOriginal ? original : reviewedText ?? cleaned ?? original }
}
public struct RecordingSession: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var kind: SessionKind
    public var startedAt = Date()
    public var timeZone = TimeZone.current.identifier
    public var duration: Double = 0
    public var status: SessionStatus = .recording
    public var sources: [AudioSource]
    public var sourceIDs: [String: String] = [:]
    public var coverage: [CaptureInterval] = []
    public var versions: [TranscriptVersion] = []
    public var draftTranscript: TranscriptVersion?
    public var summaries: [SummaryVersion] = []
    public var dictation: DictationResult?
    public var error: String?
    public var audioRetained = true
    public init(title: String, kind: SessionKind, sources: [AudioSource]) { self.title = title; self.kind = kind; self.sources = sources }
    public var latestTranscript: TranscriptVersion? { versions.last }
}
public enum TalkieError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
