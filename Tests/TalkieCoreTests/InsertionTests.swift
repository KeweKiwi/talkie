import XCTest
@testable import TalkieCore

final class InsertionTests: XCTestCase {
    func testCaretSelectionEmptyAndUnicodePreserveSurroundingText() {
        XCTAssertEqual(DictationInsertionPolicy.replacing(value: "BEGIN  END", location: 6, length: 0, text: "café 日本語"), "BEGIN café 日本語 END")
        XCTAssertEqual(DictationInsertionPolicy.replacing(value: "🙂 [replace] END", location: 3, length: 9, text: "café"), "🙂 café END")
        XCTAssertEqual(DictationInsertionPolicy.replacing(value: "", location: 0, length: 0, text: "Hello"), "Hello")
        XCTAssertNil(DictationInsertionPolicy.replacing(value: "🙂", location: 1, length: 0, text: "broken"))
        XCTAssertTrue(DictationInsertionPolicy.equivalent("cafe\u{301}\r\n日本語", "café\n日本語"))
        XCTAssertFalse(DictationInsertionPolicy.equivalent("BEGIN café", "café"))
        XCTAssertNil(DictationInsertionPolicy.replacing(value: "small", location: Int.max, length: 1, text: "broken"))
    }
    func testCleanupInsertionRequiresIndependentFidelityAndPreservedCriticalMeaning() {
        let raw = "Jangan deploy ke production. Push ke staging aja."
        XCTAssertTrue(DictationInsertionPolicy.cleanupCanInsert(original: raw, edited: raw, needsReview: false, model: "gemma4:e4b-it-qat"))
        XCTAssertFalse(DictationInsertionPolicy.cleanupCanInsert(original: raw, edited: "Deploy ke production.", needsReview: false, model: "gemma4:e4b-it-qat"))
        XCTAssertFalse(DictationInsertionPolicy.cleanupCanInsert(original: raw, edited: raw, needsReview: true, model: "gemma4:e4b-it-qat"))
        XCTAssertTrue(DictationInsertionPolicy.cleanupCanInsert(original: raw, edited: raw, needsReview: false, model: "qwen3.5:9b-q4_K_M"))
    }
}
