import AppKit
import SwiftUI

@MainActor final class RecordingOverlay {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    struct Action {
        let title: String
        let handler: () -> Void
    }
    func show(_ title: String, detail: String, actions: [Action] = [], preview: String? = nil, dismissAfter: Bool = false) {
        dismissTask?.cancel(); dismissTask = nil
        if panel == nil {
            let p = NonactivatingDictationPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = true; p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = true; panel = p
        }
        let width: CGFloat = preview == nil ? 380 : 440
        let height: CGFloat = preview == nil ? 120 : 270
        panel?.setContentSize(NSSize(width: width, height: height))
        panel?.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(.orange).font(.title2)
                Text("talkie · \(title)").font(.headline)
                Spacer()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(preview == nil ? 2 : 4)
            if let preview { Text(preview).font(.body).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading) }
            if !actions.isEmpty {
                HStack { ForEach(actions.indices, id: \.self) { index in Button(actions[index].title, action: actions[index].handler) } }.buttonStyle(.bordered).controlSize(.small)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(width: width, height: height).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
        if let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 36))
        }
        panel?.orderFrontRegardless()
        if dismissAfter {
            dismissTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)); self?.hide() } catch {}
            }
        }
    }
    func hide() { dismissTask?.cancel(); dismissTask = nil; panel?.orderOut(nil); panel?.contentView = nil }
}

private final class NonactivatingDictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
