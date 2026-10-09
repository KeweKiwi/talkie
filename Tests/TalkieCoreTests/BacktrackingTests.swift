import XCTest
@testable import TalkieCore

final class BacktrackingTests: XCTestCase {
    func testSupportedCorrectionsPreserveFullUtterance() {
        let cases = [
            ("Meetingnya Senin, eh maksudku Selasa jam dua.", "Meetingnya Selasa jam dua."),
            ("Meetingnya Senin, bukan, yang Selasa jam dua.", "Meetingnya Selasa jam dua."),
            ("Push ke production—bukan, yang staging aja.", "Push ke staging aja."),
            ("Send it to Audrey—sorry, to Kevin.", "Send it to Kevin."),
            ("Send it to Audrey—sorry, I meant Kevin.", "Send it to Kevin."),
            ("Push ke production eh maksudku staging aja.", "Push ke staging aja."),
            ("Push ke production—bukan, ke staging aja.", "Push ke staging aja."),
            ("Let's meet at four—actually, at five.", "Let's meet at five."),
            ("Let's meet at four—scratch that, at five.", "Let's meet at five."),
            ("Budgetnya 5 juta, eh maksudku 500 ribu.", "Budgetnya 500 ribu."),
            ("Jangan deploy ke production—eh maksudku jangan deploy ke staging.", "jangan deploy ke staging."),
            ("Jangan deploy ke staging—sorry, I meant deploy ke staging.", "deploy ke staging."),
            ("Selesaikan QA dulu. Simpan report 16 MB. Meetingnya Senin, eh maksudku Selasa jam dua.", "Selesaikan QA dulu. Simpan report 16 MB. Meetingnya Selasa jam dua.")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(BacktrackingPolicy.reference(raw), expected, raw)
            XCTAssertTrue(EditingPolicy.concerns(original: raw, edited: expected).isEmpty, raw)
        }
    }
    func testNegativeControlsRemainContentAndUnexplainedChangesFail() {
        for raw in [
            "I actually prefer the first option.",
            "Ini bukan, yang kamu maksud berbeda.",
            "Bukan lima juta, tapi lima ratus ribu.",
            "Jangan deploy ke production. Push ke staging aja.",
            "Kalau QA lolos, mungkin Jumat bisa release.",
            "Type the words \"sorry, I meant\" in the document.",
            "He said \"Let's meet at four—actually, at five.\" Keep the quotation.",
            "Send it to Audrey and confirm QA—sorry, to Kevin."
        ] { XCTAssertEqual(BacktrackingPolicy.reference(raw), raw); XCTAssertTrue(EditingPolicy.concerns(original: raw, edited: raw).isEmpty) }
        XCTAssertFalse(EditingPolicy.concerns(original: "Bukan lima juta, tapi lima ratus ribu.", edited: "Lima ratus ribu.").isEmpty)
        XCTAssertFalse(EditingPolicy.concerns(original: "Simpan 16 MB. Meetingnya Senin, eh maksudku Selasa jam dua.", edited: "Simpan 60 MB. Meetingnya Selasa jam dua.").isEmpty)
        XCTAssertFalse(EditingPolicy.concerns(original: "Jangan deploy ke production. Push ke staging aja.", edited: "Push ke staging aja.").isEmpty)
        XCTAssertFalse(EditingPolicy.concerns(original: "Send it to Audrey—sorry, to Kevin.", edited: "Send it to Bob.").isEmpty)
    }
    func testRecoveryIsOneBoundedExpiringConsumableResult() {
        let now = Date(timeIntervalSince1970: 100)
        var recovery = TransientRecovery()
        XCTAssertTrue(recovery.replace("first", now: now)); let stale = recovery.id!
        XCTAssertTrue(recovery.replace("second", now: now)); let current = recovery.id!
        XCTAssertNil(recovery.take(id: stale, now: now))
        XCTAssertEqual(recovery.take(id: current, now: now), "second"); XCTAssertNil(recovery.text)
        XCTAssertTrue(recovery.replace("expires", now: now))
        XCTAssertNil(recovery.take(id: recovery.id!, now: now.addingTimeInterval(61)))
        XCTAssertFalse(recovery.replace(String(repeating: "日", count: 65536), now: now)); XCTAssertNil(recovery.text)
        XCTAssertTrue(recovery.replace("dismiss", now: now)); recovery.clear(); XCTAssertNil(recovery.text)
    }
}
