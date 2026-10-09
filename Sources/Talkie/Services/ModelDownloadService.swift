import Foundation
import CryptoKit
import TalkieCore

struct ASRManifest: Codable {
    struct File: Codable { var path: String; var url: String; var size: Int64; var sha256: String? }
    var model: String; var revision: String; var tokenizerRevision: String; var files: [File]
    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "asr-manifest", withExtension: "json") else { throw TalkieError.message("ASR download manifest is missing from the app bundle.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
actor ModelDownloadService {
    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let manifest = try ASRManifest.bundled()
        let root = AppPaths.modelFolder
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            guard !entry.path.contains(".."), let url = URL(string: entry.url), url.scheme == "https", url.host == "huggingface.co" else { throw TalkieError.message("Invalid model manifest URL.") }
            let target = root.appendingPathComponent(entry.path)
            progress(Double(index) / Double(manifest.files.count), entry.path)
            if FileManager.default.fileExists(atPath: target.path), try verify(target, entry: entry) { continue }
            let (temporary, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, try verify(temporary, entry: entry) else { throw TalkieError.message("Model download failed checksum or size verification. Retry is safe.") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("installed.json"), options: .atomic)
        progress(1, "Installed \(manifest.model)")
    }
    private func verify(_ url: URL, entry: ASRManifest.File) throws -> Bool {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        if entry.size > 0 && size != entry.size { return false }
        guard let expected = entry.sha256 else { return size > 0 }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
