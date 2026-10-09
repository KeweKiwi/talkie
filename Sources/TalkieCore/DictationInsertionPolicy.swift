import Foundation

public enum DictationInsertionPolicy {
    /// AX ranges are UTF-16 offsets. Reject malformed ranges rather than risking
    /// whole-field replacement or splitting a Unicode scalar.
    public static func replacing(value: String, location: Int, length: Int, text: String) -> String? {
        let units = Array(value.utf16)
        guard location >= 0, length >= 0, location <= units.count,
              length <= units.count - location else { return nil }
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
        }
        guard boundary(location), boundary(location + length) else { return nil }
        return (value as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: text)
    }

    public static func equivalent(_ observed: String, _ expected: String) -> Bool {
        func canonical(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n") }
        return canonical(observed) == canonical(expected)
    }
    public static func cleanupCanInsert(original: String, edited: String, needsReview: Bool, model: String) -> Bool {
        !needsReview && !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && EditingPolicy.concerns(original: original, edited: edited).isEmpty
    }
}
