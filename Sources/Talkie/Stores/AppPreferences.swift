import Foundation
import Observation
import TalkieCore
import Carbon

@Observable @MainActor final class AppPreferences {
    var cleanupEnabled = false { didSet { save() } }
    var language: RecognitionLanguage = .auto { didSet { save() } }
    var summaryLanguage = "Bahasa Indonesia" { didSet { save() } }
    var cleanupModel = "gemma4:e4b-it-qat" { didSet { save() } }
    var summaryModel = "gemma4:e4b-it-qat" { didSet { save() } }
    var cleanupDigest = "" { didSet { save() } }
    var summaryDigest = "" { didSet { save() } }
    var dictionary = "" { didSet { save() } }
    var pushToTalk = false { didSet { save() } }
    var shortcutKey: UInt32 = UInt32(kVK_Space) { didSet { save() } }
    var shortcutModifiers: UInt32 = UInt32(controlKey | optionKey) { didSet { save() } }
    var microphoneID = "" { didSet { save() } }
    private var loading = true
    private let defaults: UserDefaults
    var shortcutTitle: String {
        let keys: [UInt32: String] = [UInt32(kVK_Space): "Space", UInt32(kVK_F6): "F6", UInt32(kVK_F8): "F8", UInt32(kVK_ANSI_D): "D"]
        let modifiers = [(UInt32(controlKey), "Control"), (UInt32(optionKey), "Option"), (UInt32(cmdKey), "Command"), (UInt32(shiftKey), "Shift")]
        return (modifiers.filter { shortcutModifiers & $0.0 != 0 }.map { $0.1 } + [keys[shortcutKey] ?? "Key"]).joined(separator: " + ")
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "preferences-v1"), let p = try? JSONDecoder().decode(Snapshot.self, from: data) {
            cleanupEnabled = p.cleanupEnabled; language = p.language; summaryLanguage = p.summaryLanguage
            cleanupModel = p.cleanupModel; summaryModel = p.summaryModel; dictionary = p.dictionary
            pushToTalk = p.pushToTalk; shortcutKey = p.shortcutKey; shortcutModifiers = p.shortcutModifiers
            microphoneID = p.microphoneID; cleanupDigest = p.cleanupDigest; summaryDigest = p.summaryDigest
        }
        loading = false
    }
    struct Snapshot: Codable {
        var cleanupEnabled: Bool; var language: RecognitionLanguage; var summaryLanguage: String
        var cleanupModel: String; var summaryModel: String; var dictionary: String
        var pushToTalk: Bool; var shortcutKey: UInt32; var shortcutModifiers: UInt32; var microphoneID: String
        var cleanupDigest: String; var summaryDigest: String
    }
    var snapshot: Snapshot { Snapshot(cleanupEnabled: cleanupEnabled, language: language, summaryLanguage: summaryLanguage, cleanupModel: cleanupModel, summaryModel: summaryModel, dictionary: dictionary, pushToTalk: pushToTalk, shortcutKey: shortcutKey, shortcutModifiers: shortcutModifiers, microphoneID: microphoneID, cleanupDigest: cleanupDigest, summaryDigest: summaryDigest) }
    private func save() { if !loading, let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: "preferences-v1") } }
}
