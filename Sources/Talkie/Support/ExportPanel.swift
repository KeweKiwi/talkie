import AppKit
import UniformTypeIdentifiers
import TalkieCore

@MainActor enum ExportPanel {
    static func save(_ data: Data, title: String, extension ext: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + "." + ext
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }
}
