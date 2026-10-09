import XCTest
import AppKit
@testable import Talkie

final class BackgroundDictationTests: XCTestCase {
    @MainActor func testLegacyPreferencesMigrateWithoutLosingCleanupAndNewSettingsPersist() throws {
        let defaults = UserDefaults(suiteName: "talkie-tests-\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        preferences.cleanupEnabled = true
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "preferences-v1"))) as? [String: Any])
        legacy.removeValue(forKey: "autoInsert"); legacy.removeValue(forKey: "systemWideEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "preferences-v1")
        let migrated = AppPreferences(defaults: defaults)
        XCTAssertTrue(migrated.cleanupEnabled); XCTAssertTrue(migrated.autoInsert); XCTAssertTrue(migrated.systemWideEnabled)
        let snapshot = migrated.snapshot
        migrated.autoInsert = false; migrated.systemWideEnabled = false
        XCTAssertEqual(snapshot.autoInsert, true)
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.autoInsert); XCTAssertFalse(reloaded.systemWideEnabled)
    }
    @MainActor func testDeniedAccessibilityPreservesPreviewAndDoesNotRetry() async {
        let insertion = TextInsertionService(permissionCheck: { false })
        insertion.capture()
        let first = await insertion.insert("Jangan deploy.")
        XCTAssertFalse(first.inserted); XCTAssertTrue(first.message.contains("Accessibility"))
        let duplicate = await insertion.insert("Jangan deploy.")
        XCTAssertFalse(duplicate.inserted); XCTAssertTrue(duplicate.message.contains("no retry"))
    }
    @MainActor func testClipboardLeaseRestoresMultipleRepresentationsOnlyWhileOwned() {
        let board = NSPasteboard(name: .init("talkie-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("previous", forType: .string)
        let html = Data("<b>previous</b>".utf8); item.setData(html, forType: .html)
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        let lease = ClipboardPasteLease(pasteboard: board)
        XCTAssertTrue(lease.prepare("café 日本語")); XCTAssertTrue(lease.hasRestorableBackup)
        XCTAssertFalse(lease.prepare("second paste"))
        XCTAssertTrue(lease.restoreIfOwned())
        XCTAssertEqual(board.string(forType: .string), "previous"); XCTAssertEqual(board.data(forType: .html), html)
        XCTAssertTrue(lease.prepare("dictation"))
        board.clearContents(); board.setString("newer user clipboard", forType: .string)
        XCTAssertFalse(lease.restoreIfOwned())
        XCTAssertEqual(board.string(forType: .string), "newer user clipboard")
    }
}
