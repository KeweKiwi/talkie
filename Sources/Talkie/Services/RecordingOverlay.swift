import AppKit
import SwiftUI

@MainActor final class RecordingOverlay {
    private var panel: NSPanel?
    func show(_ title: String, detail: String) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = true; p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; panel = p
        }
        panel?.contentView = NSHostingView(rootView: HStack(spacing: 14) {
            Image(systemName: "waveform").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) { Text("talkie · \(title)").font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }.padding(16).frame(width: 320, height: 70).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.minY + 36))
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
}
