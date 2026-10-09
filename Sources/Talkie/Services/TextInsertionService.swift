import AppKit
import ApplicationServices
import TalkieCore

@MainActor final class TextInsertionService {
    struct Target {
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement?
        let range: CFRange
        let value: String
        let appName: String
        let directReplacement: Bool
    }
    struct Outcome {
        let inserted: Bool
        let message: String
        let uncertain: Bool
        static func preview(_ message: String, uncertain: Bool = false) -> Self { Self(inserted: false, message: message, uncertain: uncertain) }
    }
    private(set) var target: Target?
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var poll: Timer?
    private var changed = false
    private var writing = false
    private var attempted = false
    private var generation = UUID()
    private var operationID: UUID?
    private var rejection = "No verified editable target."
    private let permissionCheck: () -> Bool
    private let clipboard = ClipboardPasteLease()
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    init(permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.permissionCheck = permissionCheck }
    var canRestoreClipboard: Bool { clipboard.hasRestorableBackup }
    func restoreClipboard() -> Bool { clipboard.restoreIfOwned() }
    func reject(_ reason: String) { let id = operationID; clear(); operationID = id; rejection = reason }
    func capture(operationID: UUID = UUID()) {
        clear(); attempted = false; generation = UUID(); self.operationID = operationID
        guard permissionCheck() else { rejection = "Accessibility permission is unavailable."; return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { rejection = "Choose a text field in another app, then use the global shortcut."; return }
        rejection = "The field in \(app.localizedName ?? "the editor") does not expose verifiable text and selection."
        let deny = ["terminal", "iterm", "warp", "alacritty", "kitty", "hyper", "wezterm"]
        guard !deny.contains(where: { (app.bundleIdentifier ?? "").lowercased().contains($0) }) else { rejection = "Terminal targets require manual Copy."; return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = focusedElement(application), safeField(element),
              let value = attribute(element, kAXValueAttribute) as? String,
              let range = selectedRange(element),
              DictationInsertionPolicy.replacing(value: value, location: range.location, length: range.length, text: "") != nil else { return }
        var settable: DarwinBoolean = false
        let direct = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        target = Target(pid: app.processIdentifier, element: element, window: windowElement(element), range: range, value: value, appName: app.localizedName ?? "Editor", directReplacement: direct)
        let captureGeneration = generation
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, self.generation == captureGeneration, self.target != nil, pid != self.target?.pid else { return }
                self.changed = true; self.rejection = "The active application changed during dictation."
            }
        }
        // Web/Electron fields do not all support AX notifications. Observe what
        // is supported, latch observed changes by polling, then revalidate before
        // one write. Unsupported notifications no longer reject valid fields.
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let service = Unmanaged<TextInsertionService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.observeTarget() }
        }
        if AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            _ = AXObserverAddNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString, context)
            _ = AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, context)
            _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, context)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes); axObserver = observer
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.observeTarget() } }
    }
    func insert(_ text: String, operationID requestedID: UUID? = nil, forcePasteForDiagnostic: Bool = false) async -> Outcome {
        let deliveryID = operationID
        guard requestedID == nil || requestedID == deliveryID else { return .preview("Stale dictation cancelled; no insertion.") }
        guard !attempted else { return .preview("This result already attempted insertion. Check the editor; no retry.", uncertain: true) }
        attempted = true
        defer { if operationID == deliveryID { clear() } }
        guard !Task.isCancelled else { return .preview("Dictation cancelled; result retained.") }
        guard let target, !changed, valid(target) else { return .preview("\(rejection) Preview retained; Copy to your intended field.") }
        guard !text.isEmpty, let expected = DictationInsertionPolicy.replacing(value: target.value, location: target.range.location, length: target.range.length, text: text) else { return .preview("Empty text or invalid selection; preview retained.") }
        writing = true
        if target.directReplacement && !forcePasteForDiagnostic {
            let status = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
            if status == .success {
                if await verify(target, expected: expected, operationID: deliveryID) { return Outcome(inserted: true, message: "Inserted into \(target.appName).", uncertain: false) }
                return .preview("Insertion could not be confirmed. Check the editor before copying; no retry.", uncertain: true)
            }
            guard [.attributeUnsupported, .notImplemented].contains(status), valid(target) else { return .preview("Editor declined or could not confirm insertion. Preview retained; no retry.", uncertain: true) }
        }
        guard let paste = pasteMenuItem(AXUIElementCreateApplication(target.pid)), valid(target), clipboard.prepare(text) else { return .preview("The editor has no safe Paste action or the clipboard cannot be restored. Preview retained.") }
        guard valid(target), clipboard.ownsClipboard, !Task.isCancelled else { clipboard.restoreIfOwned(); return .preview("Target or clipboard changed before Paste. Preview retained.") }
        let status = AXUIElementPerformAction(paste, kAXPressAction as CFString)
        if status == .success, await verify(target, expected: expected, operationID: deliveryID) {
            clipboard.restoreIfOwned()
            return Outcome(inserted: true, message: "Inserted into \(target.appName) using Paste; clipboard ownership checked.", uncertain: false)
        }
        // Even failed AXPress can be ambiguous. Do not retry or restore while
        // delayed clipboard consumption is unconfirmed.
        return .preview("Paste could not be confirmed. Check the editor before copying. Previous clipboard is available via Restore Clipboard while talkie still owns it; no retry.", uncertain: true)
    }
    private func verify(_ target: Target, expected: String, operationID id: UUID?) async -> Bool {
        for _ in 0..<30 {
            guard operationID == id, !Task.isCancelled else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
               let focused = focusedElement(AXUIElementCreateApplication(target.pid)), CFEqual(focused, target.element), sameWindow(target.window, windowElement(focused)),
               let observed = attribute(target.element, kAXValueAttribute) as? String,
               DictationInsertionPolicy.equivalent(observed, expected) { return true }
            if Task.isCancelled { return false }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }
    private func observeTarget() {
        guard !writing, !changed, let target else { return }
        if !valid(target) { changed = true; rejection = "The app, field, selection, or text changed during dictation." }
    }
    private func valid(_ target: Target) -> Bool {
        guard permissionCheck(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = focusedElement(AXUIElementCreateApplication(target.pid)), CFEqual(current, target.element), safeField(current),
              sameWindow(target.window, windowElement(current)),
              let range = selectedRange(current), range.location == target.range.location, range.length == target.range.length,
              attribute(current, kAXValueAttribute) as? String == target.value else { return false }
        return true
    }
    func clear() {
        generation = UUID(); operationID = nil
        poll?.invalidate(); poll = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        activationObserver = nil; axObserver = nil; target = nil; changed = false; writing = false
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }; return result
    }
    private func safeField(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String, [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              attribute(element, kAXEnabledAttribute) as? Bool != false,
              attribute(element, "AXEditable") as? Bool != false else { return false }
        var current: AXUIElement? = element
        let blocked = ["terminal", "console", "shell", "command input", "command palette", "password", "secure"]
        for _ in 0..<6 {
            guard let node = current else { break }
            if (attribute(node, kAXSubroleAttribute) as? String)?.lowercased().contains("secure") == true
                || attribute(node, "AXProtectedContent") as? Bool == true { return false }
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { attribute(node, $0) as? String }.joined(separator: " ").lowercased()
            if blocked.contains(where: labels.contains) { return false }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return true
    }
    private func pasteMenuItem(_ application: AXUIElement) -> AXUIElement? {
        guard let bar = attribute(application, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var remaining = 250
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 6, remaining > 0 else { return nil }; remaining -= 1
            if attribute(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
               (attribute(element, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "v",
               (attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,
               attribute(element, kAXEnabledAttribute) as? Bool == true { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(bar as! AXUIElement, depth: 0)
    }
    private func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement)
    }
    private func windowElement(_ element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement)
    }
    private func sameWindow(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) { case (nil, nil): return true; case (let a?, let b?): return CFEqual(a, b); default: return false }
    }
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(); guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }; return range
    }
}
