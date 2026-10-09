import Foundation

public final class SessionRepository: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ session: RecordingSession) throws {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(session.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let file = folder.appendingPathComponent("session.json")
        try encoder.encode(session).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
    }
    public func load() throws -> [RecordingSession] {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { folder in
            let file = folder.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decoder.decode(RecordingSession.self, from: Data(contentsOf: file))
        }.sorted { $0.startedAt > $1.startedAt }
    }
    public func deleteAudio(_ session: inout RecordingSession) throws {
        lock.lock(); defer { lock.unlock() }
        for file in try FileManager.default.contentsOfDirectory(at: directory(session.id), includingPropertiesForKeys: nil) where file.pathExtension == "wav" { try FileManager.default.removeItem(at: file) }
        session.audioRetained = false; try save(session)
    }
    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.removeItem(at: directory(id))
    }
}
