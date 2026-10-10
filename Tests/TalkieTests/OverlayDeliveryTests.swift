import XCTest
import AppKit
@testable import Talkie

final class OverlayDeliveryTests: XCTestCase {
    func testCaretAnchoringStaysOutsideTextAndOnTheCorrectDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let axCaret = CGRect(x: -500, y: 400, width: 0, height: 20)
        let caret = DictationOverlayPlacement.appKitRect(axCaret, primaryScreen: primary)
        XCTAssertEqual(caret, CGRect(x: -500, y: 480, width: 0, height: 20))
        let size = CGSize(width: 238, height: 44)
        let frame = DictationOverlayPlacement.frame(size: size, anchor: caret, visibleScreens: [primary, left, above])
        XCTAssertTrue(left.contains(frame)); XCTAssertLessThan(frame.maxY, caret.minY)
        let highCaret = DictationOverlayPlacement.appKitRect(CGRect(x: 400, y: -500, width: 0, height: 20), primaryScreen: primary)
        XCTAssertTrue(above.contains(DictationOverlayPlacement.frame(size: size, anchor: highCaret, visibleScreens: [primary, left, above])))
        let bottomCaret = CGRect(x: 1425, y: 10, width: 1, height: 20)
        let bottomFrame = DictationOverlayPlacement.frame(size: size, anchor: bottomCaret, visibleScreens: [primary])
        XCTAssertGreaterThan(bottomFrame.minY, bottomCaret.maxY)
        XCTAssertTrue(primary.contains(bottomFrame))
        let fallback = DictationOverlayPlacement.frame(size: size, anchor: nil, visibleScreens: [primary])
        XCTAssertTrue(primary.contains(fallback))
    }
    @MainActor func testDeliveryAcceptsEntireOriginalFieldWhenValueIsStale() async {
        var reads = 0
        let expected = "BEGIN café 日本語 END"
        let confirmed = await TextInsertionService.confirmDelivery(expected: expected, isCurrent: { true }, readValue: { "BEGIN [replace me] END" }, readFullText: {
            reads += 1
            return reads < 3 ? "BEGIN [replace me] END" : "BEGIN cafe\u{301} 日本語 END"
        }, pause: {})
        XCTAssertTrue(confirmed); XCTAssertEqual(reads, 3)
        let wrongScope = await TextInsertionService.confirmDelivery(expected: expected, isCurrent: { true }, readValue: { nil }, readFullText: { "café 日本語" }, pause: {})
        XCTAssertFalse(wrongScope)
        let extraContent = await TextInsertionService.confirmDelivery(expected: expected, isCurrent: { true }, readValue: { expected + "\n" }, readFullText: { nil }, pause: {})
        XCTAssertFalse(extraContent)
    }
    @MainActor func testDeliveryStopsReadingWhenOperationIsInvalidated() async {
        var current = true, reads = 0
        let confirmed = await TextInsertionService.confirmDelivery(expected: "fixture", isCurrent: { current }, readValue: {
            reads += 1; return reads == 1 ? "" : "fixture"
        }, readFullText: { nil }, pause: { current = false })
        XCTAssertFalse(confirmed); XCTAssertEqual(reads, 1)
    }
}
