import Foundation
import AVFoundation
import WhisperKit
import TalkieCore

/// The OSS default tokenizer loader has a network fallback. This subclass replaces
/// that hook with strict local loading, so corrupt/missing files fail offline.
private final class OfflineWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let folder = tokenizerFolder, let logits = textDecoder.logitsSize else { throw TalkieError.message("Local tokenizer is missing.") }
        let wrapper = try await AutoTokenizerWrapper.from(modelFolder: folder)
        textDecoder.isModelMultilingual = logits != 51864
        tokenizer = try LocalWhisperTokenizer(wrapper)
    }
}
struct ChunkRecognition { var segments: [TranscriptSegment]; var detectedSilence: Bool }
actor RecognitionService {
    private var engine: WhisperKit?
    static let identity = "large-v3-v20240930_626MB@0f63a7800b00dd0226abd051b906c246e1907482"
    func prepare() async throws {
        guard engine == nil else { return }
        let folder = AppPaths.modelFolder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("installed.json").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer/tokenizer.json").path) else {
            throw TalkieError.message("Download the pinned multilingual speech model in Settings first. Saved audio can be transcribed afterward.")
        }
        let config = WhisperKitConfig(model: AppPaths.asrModel, modelFolder: folder.path, tokenizerFolder: folder.appendingPathComponent("tokenizer"), verbose: false, prewarm: true, load: true, download: false)
        engine = try await OfflineWhisperKit(config)
    }
    func unload() async { await engine?.unloadModels(); engine = nil }
    func transcribe(file: URL, interval: CaptureInterval, language: RecognitionLanguage, dictionary: String) async throws -> ChunkRecognition {
        try Task.checkCancellation()
        if try isDigitalSilence(file) { return ChunkRecognition(segments: [], detectedSilence: true) }
        try await prepare()
        guard let engine else { throw TalkieError.message("Speech engine unavailable.") }
        // Recognition hints only: no post-ASR replacement, even with cleanup OFF.
        let terms = dictionary.split(separator: "\n").prefix(48).map(String.init).joined(separator: ", ")
        let promptTokens = terms.isEmpty ? nil : engine.tokenizer?.encode(text: terms)
        let options = DecodingOptions(task: .transcribe, language: language.code, temperature: 0, temperatureFallbackCount: 2, detectLanguage: language == .auto, skipSpecialTokens: true, wordTimestamps: false, promptTokens: promptTokens, concurrentWorkerCount: 1)
        let results = try await engine.transcribe(audioPath: file.path, decodeOptions: options)
        try Task.checkCancellation()
        let segments: [TranscriptSegment] = results.flatMap(\.segments).enumerated().compactMap { index, segment in
            if segment.noSpeechProb > 0.8 && segment.avgLogprob < -0.5 { return nil }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptSegment(id: "\(interval.id.uuidString)-\(index)", chunkID: interval.id, source: interval.source, start: interval.start + Double(segment.start), end: min(interval.end, interval.start + Double(segment.end)), text: segment.text, uncertain: segment.avgLogprob < -0.7 || segment.noSpeechProb > 0.5)
        }
        return ChunkRecognition(segments: segments, detectedSilence: false)
    }
    private func isDigitalSilence(_ file: URL) throws -> Bool {
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { return false }
        while audio.framePosition < audio.length {
            try Task.checkCancellation(); try audio.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) where abs(data[channel][frame]) >= 0.0001 { return false }
            }
        }
        return true
    }
}
