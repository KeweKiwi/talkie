import Foundation

struct AppPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["TALKIE_DATA_ROOT"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("talkie", isDirectory: true)
    }
    static var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    static var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    static let asrModel = "openai_whisper-large-v3-v20240930_626MB"
    static var modelFolder: URL { models.appendingPathComponent(asrModel, isDirectory: true) }
}
