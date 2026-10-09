import Foundation

/// A conservative reference for validating the existing cleanup pass, never a
/// hidden correction pass when cleanup is OFF. Ambiguous spans stay verbatim.
public enum BacktrackingPolicy {
    public static func reference(_ original: String) -> String {
        var text = original
        let cues = try! NSRegularExpression(pattern: #"(?i)(?:[,—–-]\s*|\s+)(eh\s+maksud(?:ku|\s+saya)|sorry(?:,?\s+I\s+meant)?|actually|scratch\s+that|bukan(?=\s*,))\s*[,—–-]?\s*"#)
        for _ in 0..<8 {
            let source = text as NSString
            let quotes = try! NSRegularExpression(pattern: #"\"[^\"]*\"|“[^”]*”|'[^']*'"#)
            let quoted = quotes.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
            var replacement: String?
            for cue in cues.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                guard !quoted.contains(where: { NSIntersectionRange($0, cue.range).length > 0 }) else { continue }
                let left = source.substring(to: cue.range.location).trimmingCharacters(in: .whitespaces)
                let spokenRight = source.substring(from: NSMaxRange(cue.range))
                let cueName = source.substring(with: cue.range(at: 1)).lowercased()
                let whichCorrection = cueName == "bukan" && spokenRight.lowercased().hasPrefix("yang ")
                let right = whichCorrection ? String(spokenRight.dropFirst(5)) : spokenRight
                guard !left.isEmpty, !right.isEmpty else { continue }
                let lhs = left as NSString
                // A repeated preposition identifies only the superseded phrase.
                let prep = try! NSRegularExpression(pattern: #"(?i)\b(to|at|on|ke|pada|jam)\s+([\p{L}\p{N}_./'-]+(?:\s+[\p{L}\p{N}_./'-]+){0,3})$"#)
                if let match = prep.firstMatch(in: left, range: NSRange(location: 0, length: lhs.length)) {
                    let preposition = lhs.substring(with: match.range(at: 1)).lowercased()
                    let spanWords = lhs.substring(with: match.range).lowercased().split(separator: " ").map(String.init)
                    let blockers = Set(["and", "dan", "then", "lalu", "after", "before", "sebelum", "setelah", "with", "dengan", "if", "kalau", "maybe", "mungkin", "jangan", "not", "never"])
                    if right.lowercased().hasPrefix(preposition + " "), blockers.isDisjoint(with: Set(spanWords)) {
                        replacement = lhs.substring(to: match.range.location) + right; break
                    }
                    let oldValue = lhs.substring(with: match.range(at: 2))
                    let oldWord = oldValue.split(separator: " ").first.map(String.init) ?? ""
                    let newWord = right.split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
                    let quantities = Set(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan", "sepuluh"])
                    let environments = Set(["production", "staging", "development", "testing"])
                    let valuesAgree = (oldWord.first?.isNumber == true && (newWord.first?.isNumber == true || quantities.contains(newWord.lowercased())))
                        || (quantities.contains(oldWord.lowercased()) && (quantities.contains(newWord.lowercased()) || newWord.first?.isNumber == true))
                        || (oldWord.first?.isUppercase == true && newWord.first?.isUppercase == true)
                        || (environments.contains(oldWord.lowercased()) && environments.contains(newWord.lowercased()))
                    if (cueName.contains("meant") || cueName.contains("maksud") || whichCorrection), valuesAgree, blockers.isDisjoint(with: Set(spanWords)) {
                        replacement = lhs.substring(to: match.range(at: 2).location) + right; break
                    }
                }
                // Clear Indonesian schedule/quantity restatement: the subject
                // survives, and both values must belong to the same category.
                let subject = try! NSRegularExpression(pattern: #"(?i)\b(meetingnya|jadwalnya|budgetnya|anggarannya|harganya|biayanya|deadlinenya|jumlahnya)\s+([\p{L}\p{N}_./-]+(?:\s+[\p{L}\p{N}_./-]+){0,2})$"#)
                if let match = subject.firstMatch(in: left, range: NSRange(location: 0, length: lhs.length)) {
                    let old = lhs.substring(with: match.range(at: 2)).lowercased().split(separator: " ").first.map(String.init) ?? ""
                    let new = right.lowercased().split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
                    let days = Set(["senin", "selasa", "rabu", "kamis", "jumat", "sabtu", "minggu"])
                    func number(_ value: String) -> Bool { value.first?.isNumber == true || ["satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan", "sepuluh"].contains(value) }
                    let oldSpan = lhs.substring(with: match.range(at: 2)).lowercased().split(separator: " ")
                    if !oldSpan.contains("dan"), !oldSpan.contains("and"), (days.contains(old) && days.contains(new)) || (number(old) && number(new)) {
                        replacement = lhs.substring(to: match.range(at: 2).location) + right; break
                    }
                }
                // Whole-clause restatements require a repeated action prefix.
                // This permits an explicitly corrected negation, not silent loss.
                let boundary = left.lastIndex(where: { ".!?;\n".contains($0) })
                let start = boundary.map { left.index(after: $0) } ?? left.startIndex
                let clause = String(left[start...]).trimmingCharacters(in: .whitespaces)
                func actionWords(_ value: String) -> [String] {
                    var value = value.lowercased().replacingOccurrences(of: "’", with: "'")
                    for prefix in ["do not ", "don't ", "jangan ", "tidak ", "never "] where value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)); break }
                    return value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                }
                let a = actionWords(clause), b = actionWords(right)
                let shared = zip(a, b).prefix(while: { $0.0 == $0.1 }).count
                let protected = Set(["and", "dan", "then", "lalu", "if", "kalau", "maybe", "mungkin", "after", "before"])
                if shared >= 2, a.count - shared <= 1, protected.isDisjoint(with: Set(a)), clause.count <= 160 {
                    let prefix = String(left[..<start]); replacement = prefix + (prefix.isEmpty ? "" : " ") + right; break
                }
            }
            guard let replacement, replacement != text else { break }; text = replacement
        }
        return text
    }
    public static func fidelityTokens(_ value: String) -> [String] {
        let normalized = value.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+(?:[.'/-][\p{L}\p{N}_]+)*"#)
        let source = normalized as NSString
        let aliases = ["aja": "saja", "gak": "tidak", "nggak": "tidak"]
        return regex.matches(in: normalized, range: NSRange(location: 0, length: source.length)).compactMap {
            let token = source.substring(with: $0.range)
            return ["um", "uh", "erm", "eee"].contains(token) ? nil : aliases[token] ?? token
        }
    }
}
