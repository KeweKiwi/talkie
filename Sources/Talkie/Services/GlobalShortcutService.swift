import Carbon
import Foundation

@MainActor final class GlobalShortcutService {
    private var hotkey: EventHotKeyRef?
    private var escape: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let enabled: Bool
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    init(enabled: Bool = true) {
        self.enabled = enabled
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let service = Unmanaged<GlobalShortcutService>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in
                if id.id == 2 { if pressed { service.onCancel?() } }
                else if pressed { service.onPress?() } else { service.onRelease?() }
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let escape { UnregisterEventHotKey(escape) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(key: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        guard enabled else { return false }
        return RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x74616C6B, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
    }
    func setCancellation(_ active: Bool) {
        if let escape { UnregisterEventHotKey(escape) }; escape = nil
        if active && enabled { RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x74616C6B, id: 2), GetApplicationEventTarget(), 0, &escape) }
    }
}
