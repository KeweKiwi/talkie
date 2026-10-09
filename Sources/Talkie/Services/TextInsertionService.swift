import AppKit
import ApplicationServices

@MainActor final class TextInsertionService {
    struct Target {
        let pid: pid_t
        let element: AXUIElement
        let range: CFRange
        let value: String
        let appName: String
    }
    private(set) var target: Target?
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var changed = false
    private var rejection = "No verified editable target."
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    func capture() {
        clear()
        guard Self.trusted else { rejection = "Accessibility permission is unavailable."; return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { rejection = "Dictation started in talkie; choose an external editor for insertion."; return }
        rejection = "The focused field in \(app.localizedName ?? "the editor") does not expose a supported text role, value, and selection."
        let deny = ["terminal", "iterm", "warp", "alacritty", "kitty", "hyper", "wezterm"]
        guard !deny.contains(where: { (app.bundleIdentifier ?? "").lowercased().contains($0) }) else { rejection = "Terminal targets require manual Copy."; return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = focusedElement(application),
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              !((attribute(element, kAXSubroleAttribute) as? String)?.lowercased().contains("secure") ?? false),
              !ambiguousField(element),
              let value = attribute(element, kAXValueAttribute) as? String,
              let range = selectedRange(element), range.location >= 0, range.length >= 0,
              range.location + range.length <= (value as NSString).length else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { rejection = "The editor does not support selected-text replacement."; return }
        target = Target(pid: app.processIdentifier, element: element, range: range, value: value, appName: app.localizedName ?? "Editor")
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.changed = true; self?.rejection = "The active application changed during dictation." } }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let service = Unmanaged<TextInsertionService>.fromOpaque(context).takeUnretainedValue()
            let reason = notification as String == kAXSelectedTextChangedNotification ? "The editor selection changed during dictation." : "The focused editor field changed during dictation."
            Task { @MainActor in service.changed = true; service.rejection = reason }
        }
        if AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let focusStatus = AXObserverAddNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString, context)
            let selectionStatus = AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, context)
            if focusStatus != .success || selectionStatus != .success { changed = true; rejection = "The editor cannot observe focus/selection safely (AX \(focusStatus.rawValue)/\(selectionStatus.rawValue))." }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            axObserver = observer
        } else { changed = true; rejection = "The editor's Accessibility observer is unavailable." }
    }
    func insert(_ text: String) -> String {
        defer { clear() }
        guard target != nil, !changed else { return "Preview ready — \(rejection) Copy to your intended field." }
        guard let target, !changed, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = focusedElement(AXUIElementCreateApplication(target.pid)),
              CFEqual(current, target.element), let range = selectedRange(current),
              range.location == target.range.location, range.length == target.range.length,
              attribute(current, kAXValueAttribute) as? String == target.value else {
            return "Preview ready — target or selection could not be verified. Copy to your intended field."
        }
        let expected = (target.value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        let result = AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, text as CFString)
        guard result == .success else { return "Editor declined insertion. Preview retained; no automatic retry." }
        guard attribute(current, kAXValueAttribute) as? String == expected else { return "Insertion could not be confirmed. Check the editor before copying; no retry was attempted." }
        return "Inserted into \(target.appName)."
    }
    func clear() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        activationObserver = nil; axObserver = nil; target = nil; changed = false
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }; return result
    }
    private func ambiguousField(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        let blocked = ["terminal", "console", "shell", "command input", "command palette", "password", "secure"]
        for _ in 0..<5 {
            guard let node = current else { break }
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { attribute(node, $0) as? String }.joined(separator: " ").lowercased()
            if blocked.contains(where: labels.contains) { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return false
    }
    private func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement)
    }
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(); guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }; return range
    }
}
