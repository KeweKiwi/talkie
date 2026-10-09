import SwiftUI
import TalkieCore

struct TranscriptCorrectionView: View {
    let store: AppStore
    let sessionID: UUID
    let source: TranscriptVersion
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct a transcript derivative").font(.title2)
            Text("Raw ASR remains unchanged. Segment IDs, source labels and timestamps are preserved.").foregroundStyle(.secondary)
            ScrollView {
                ForEach(source.orderedSegments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(TranscriptExporter.timestamp(segment.start)) · \(segment.source.rawValue)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { edits[segment.id] ?? segment.text }, set: { edits[segment.id] = $0 })).frame(minHeight: 80).border(.quaternary)
                    }.padding(.bottom, 12)
                }
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save Corrected Version") { store.correct(sessionID, source: source, edits: edits); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 700, height: 540)
    }
}
