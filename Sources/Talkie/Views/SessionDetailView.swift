import SwiftUI
import AVFoundation
import TalkieCore

struct SessionDetailView: View {
    @Bindable var store: AppStore
    let session: RecordingSession
    @State private var versionID: UUID?
    @State private var showOriginal = false
    @State private var editingDictation = false
    @State private var dictationEdit = ""
    @State private var editingTranscript = false
    @State private var editingSummary = false
    @State private var summaryEdit = ""
    @State private var deleteConfirmation = false
    @State private var player: AVAudioPlayer?
    private var version: TranscriptVersion? { session.versions.first { $0.id == versionID } ?? session.latestTranscript }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title).font(.title.weight(.semibold))
                        Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TranscriptExporter.timestamp(session.duration)) · \(session.sources.map(\.rawValue).joined(separator: " + "))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Delete Audio", role: .destructive) { store.deleteAudio(session.id) }.disabled(!session.audioRetained)
                        Button("Delete Session…", role: .destructive) { deleteConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(store.recording || store.isBusy)
                }
                if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if session.kind == .dictation, let result = session.dictation {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(result.cleanupStatus).font(.headline); Spacer(); Button("Copy") { store.copy(result.output) } }
                            Text(result.output).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Button("Review / Edit Output…") { dictationEdit = result.cleaned ?? result.original; editingDictation = true }
                            if result.usedOriginal, let candidate = result.cleaned { DisclosureGroup("Show Cleaned Candidate") { Text(candidate).textSelection(.enabled) } }
                            DisclosureGroup("Show Original", isExpanded: $showOriginal) {
                                Text(result.original).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.vertical, 8)
                                Button("Use Original") { store.useOriginal(session.id) }
                            }
                        }.padding(8)
                    }
                }
                HStack {
                    Button(session.versions.isEmpty ? "Transcribe Saved Audio" : "Create New ASR Version", systemImage: "waveform") { store.transcribe(session.id) }.disabled(!session.audioRetained || store.isBusy || store.recording)
                    if !session.audioRetained { Text("Audio removed").font(.caption).foregroundStyle(.secondary) }
                }
                if let version {
                    HStack {
                        Picker("Transcript version", selection: Binding(get: { version.id }, set: { versionID = $0 })) {
                            ForEach(Array(session.versions.enumerated()), id: \.element.id) { index, item in Text("\(index + 1) · \(item.isRaw ? "Raw ASR" : "Corrected")").tag(item.id) }
                        }.frame(maxWidth: 260)
                        Spacer()
                        Text(version.accountedFor ? "Known intervals accounted for" : "Partial transcript").font(.caption).foregroundStyle(version.accountedFor ? Color.secondary : Color.orange)
                    }
                    HStack {
                        Button("Copy Full Transcript", systemImage: "doc.on.doc") { store.copy(TranscriptExporter.full(session: session, version: version)) }
                        Menu("Export Full Transcript") {
                            Button("Markdown (.md)") { export(version, format: "md") }
                            Button("UTF-8 Text (.txt)") { export(version, format: "txt") }
                            Button("JSON (.json)") { export(version, format: "json") }
                            Button("Subtitles (.srt)") { export(version, format: "srt") }
                        }
                    }
                    HStack {
                        Button("Summarize Locally", systemImage: "text.alignleft") { store.summarize(session.id, versionID: version.id) }.disabled(store.isBusy || store.recording)
                        Button("Correct Transcript…") { editingTranscript = true }.disabled(store.isBusy || store.recording)
                        Button("Copy AI Instructions") { store.copy(TranscriptExporter.externalInstructions) }
                    }
                    Text("Export includes every available segment and gap marker in this version. Summary generation is optional. Source labels do not identify individual speakers.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(version.orderedSegments) { segment in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(TranscriptExporter.timestamp(segment.start)).font(.caption.monospaced())
                                Text(segment.source.rawValue).font(.caption2).foregroundStyle(.secondary)
                                if session.audioRetained { Button { play(segment) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).help("Review retained source audio") }
                            }.frame(width: 92, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                if segment.uncertain { Label("Uncertain recognition — review audio", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange) }
                                Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.vertical, 4)
                    }
                    ForEach(version.coverage.filter { [.pending, .failed, .paused, .missing, .silence].contains($0.state) }) { interval in
                        Label("\(TranscriptExporter.timestamp(interval.start))–\(TranscriptExporter.timestamp(interval.end)) · \(interval.source.rawValue) · \(interval.state.rawValue): \(interval.note ?? "")", systemImage: "ellipsis.bubble").font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = session.summaries.last, let source = session.versions.first(where: { $0.id == summary.transcriptID }) {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Local summary").font(.title2.weight(.semibold))
                                Spacer()
                                if summary.transcriptID != session.latestTranscript?.id { Text("Based on an older transcript version").font(.caption).foregroundStyle(.orange) }
                            }
                            Text("\(summary.language) · \(summary.model) · \(summary.promptVersion)").font(.caption).foregroundStyle(.secondary)
                            if !source.accountedFor { Label("Summary covers a partial transcript", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            let content = summary.editedMarkdown ?? summary.content.markdown(transcript: source)
                            Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Copy Summary") { store.copy(content) }
                                Button("Export Summary") { do { try ExportPanel.save(Data(content.utf8), title: session.title + "-summary", extension: "md") } catch { store.message = error.localizedDescription } }
                                Button("Edit Summary…") { summaryEdit = content; editingSummary = true }
                            }
                        }
                    }
                } else { ContentUnavailableView("Audio saved locally", systemImage: "waveform", description: Text("Stop recording, then transcribe. Full transcript export and local summary become independent actions after transcription.")) }
            }.padding(28)
        }
        .alert("Delete this session and its files?", isPresented: $deleteConfirmation) { Button("Delete", role: .destructive) { store.deleteSession(session.id) }; Button("Cancel", role: .cancel) {} } message: { Text("This deletes retained audio, all transcript versions, and summaries. It cannot be undone in talkie.") }
        .sheet(isPresented: $editingDictation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review dictation output").font(.title2)
                Text("Confirm meaning, language, numbers and scope against the original. Saving does not insert or submit text.").foregroundStyle(.secondary)
                TextEditor(text: $dictationEdit)
                HStack { Button("Cancel") { editingDictation = false }; Spacer(); Button("Save Reviewed Text") { store.saveReviewedDictation(session.id, text: dictationEdit); editingDictation = false }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 650, height: 400)
        }
        .sheet(isPresented: $editingTranscript) { if let version { TranscriptCorrectionView(store: store, sessionID: session.id, source: version) } }
        .sheet(isPresented: $editingSummary) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit summary").font(.title2)
                TextEditor(text: $summaryEdit).font(.body)
                HStack { Button("Cancel") { editingSummary = false }; Spacer(); Button("Save") { if let summary = session.summaries.last { store.saveSummaryEdit(session.id, summaryID: summary.id, text: summaryEdit) }; editingSummary = false }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 700, height: 500)
        }.onDisappear { player?.stop() }
    }
    private func export(_ version: TranscriptVersion, format: String) {
        do {
            let data: Data
            if format == "json" { data = try TranscriptExporter.json(session: session, version: version) }
            else if format == "srt" { data = Data(TranscriptExporter.srt(version: version).utf8) }
            else { data = Data(TranscriptExporter.full(session: session, version: version).utf8) }
            try ExportPanel.save(data, title: session.title + "-transcript", extension: format)
        } catch { store.message = error.localizedDescription }
    }
    private func play(_ segment: TranscriptSegment) {
        guard let interval = session.coverage.first(where: { $0.id == segment.chunkID }), let file = interval.file, let repository = store.repository else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: repository.directory(session.id).appendingPathComponent(file)); player?.currentTime = max(0, segment.start - interval.start); player?.play() } catch { store.message = "Audio review failed: \(error.localizedDescription)" }
    }
}
