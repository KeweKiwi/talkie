import Foundation
import WhisperKit
import TalkieCore

/// Strict local adapter for WhisperKit's public tokenizer protocol.
final class LocalWhisperTokenizer: WhisperTokenizer {
    private let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(_ base: TokenizerWrapper) throws {
        self.base = base
        func token(_ name: String) throws -> Int {
            guard let id = base.convertTokenToId(name) else { throw TalkieError.message("Local tokenizer lacks \(name); reinstall the pinned model.") }; return id
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"), noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"), specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"), startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"), transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"), whitespaceToken: base.encode(text: " ", addSpecialTokens: false).first ?? 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { base.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { base.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for id in tokenIds {
            pending.append(id); let text = decode(tokens: pending)
            if text.contains("\u{FFFD}") { continue }
            if text.hasPrefix(" ") || id >= specialTokens.specialTokenBegin || words.isEmpty {
                words.append(text); groups.append(pending)
            } else { words[words.count - 1] += text; groups[groups.count - 1] += pending }
            pending = []
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
