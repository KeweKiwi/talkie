import Foundation
import Darwin
import TalkieCore

/// Only engine-required audio files live here. No session.json, text, destination,
/// or restoration state is written. Normal deletion is not secure erasure.
final class TransientDictationAudio {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("co.kewekiwi.talkie.voice-input", isDirectory: true) }
    let directory: URL
    init(root: URL = TransientDictationAudio.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw TalkieError.message("Temporary audio root must be a private directory.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        directory = root.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    static func removeOrphans(root: URL = root, includeCurrentProcess: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw TalkieError.message("Temporary audio root must be a private directory.") }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let parts = folder.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let owner = pid_t(parts[0]), owner > 0, UUID(uuidString: String(parts[1])) != nil else { continue }
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // Do not remove another running instance's temporary capture.
            if (includeCurrentProcess && owner == getpid()) || (kill(owner, 0) == -1 && errno == ESRCH) { try FileManager.default.removeItem(at: folder) }
        }
    }
}
