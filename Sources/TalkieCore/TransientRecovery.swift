import Foundation

/// A single bounded result, never a history or Codable restoration record.
public struct TransientRecovery: Sendable {
    public static let maximumBytes = 64 * 1024
    public private(set) var id: UUID?
    public private(set) var text: String?
    private var expiresAt: Date?
    public init() {}
    @discardableResult public mutating func replace(_ text: String, now: Date = Date(), lifetime: TimeInterval = 60) -> Bool {
        clear()
        guard !text.isEmpty, text.utf8.count <= Self.maximumBytes else { return false }
        self.id = UUID(); self.text = text; expiresAt = now.addingTimeInterval(lifetime); return true
    }
    public mutating func take(id: UUID, now: Date = Date()) -> String? {
        expire(now: now); guard self.id == id else { return nil }
        let result = text; clear(); return result
    }
    public mutating func expire(now: Date = Date()) { if let expiresAt, now >= expiresAt { clear() } }
    public mutating func clear() { text = nil; id = nil; expiresAt = nil }
}
