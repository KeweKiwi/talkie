import AppKit
import SwiftUI
import Observation

@Observable @MainActor private final class InputMeter { var level: Float = 0 }

@MainActor final class RecordingOverlay {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    var anchor: CGRect?
    private let meter = InputMeter()
    var inputLevel: Float { get { meter.level } set { meter.level = min(1, max(0, newValue)) } }
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
        let width: CGFloat = preview == nil ? 238 : 340
        let height: CGFloat = preview == nil ? 44 : 190
        let meter = self.meter
        panel?.setContentSize(NSSize(width: width, height: height))
        panel?.contentView = NSHostingView(rootView: Group {
            if let preview {
                VStack(alignment: .leading, spacing: 10) {
                    Label(title, systemImage: "waveform").font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text(preview).font(.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    HStack { ForEach(actions.indices, id: \.self) { index in Button(actions[index].title, action: actions[index].handler) } }.buttonStyle(.bordered).controlSize(.small)
                }.padding(14)
            } else {
                HStack(spacing: 10) {
                    if ["Starting", "Transcribing", "Cleaning"].contains(title) { ProgressView().controlSize(.small).scaleEffect(0.8) }
                    else if title == "Recording" {
                        HStack(spacing: 2) {
                            ForEach([0.65, 1.0, 0.8], id: \.self) { scale in
                                Capsule().fill(.orange).frame(width: 3, height: 5 + CGFloat(meter.level) * 18 * scale)
                            }
                        }.frame(width: 17, height: 24).accessibilityLabel("Microphone input level")
                    } else { Image(systemName: "waveform").foregroundStyle(.orange) }
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    ForEach(actions.indices, id: \.self) { index in
                        let action = actions[index]
                        Button(action: action.handler) {
                            Image(systemName: action.title == "Stop" ? "stop.fill" : "xmark")
                                .font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                                .background(.primary.opacity(0.08), in: Circle())
                        }.buttonStyle(.plain).help(action.title).accessibilityLabel(action.title)
                    }
                }.padding(.horizontal, 12).help("talkie · \(title). \(detail)").accessibilityLabel("talkie · \(title). \(detail)")
            }
        }.frame(width: width, height: height).background(.regularMaterial, in: RoundedRectangle(cornerRadius: preview == nil ? 12 : 16)))
        panel?.setFrame(DictationOverlayPlacement.frame(size: CGSize(width: width, height: height), anchor: anchor, visibleScreens: NSScreen.screens.map(\.visibleFrame)), display: true)
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
