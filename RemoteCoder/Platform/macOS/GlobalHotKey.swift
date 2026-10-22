#if os(macOS)
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "macOS refused the shortcut (error \(status))." }
    }

    private static let signature: OSType = 0x5243_5145
    private static var lastID: UInt32 = 0

    private let identifier: EventHotKeyID
    private let onPress: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, onPress: @escaping @MainActor () -> Void) throws(RegistrationError) {
        Self.lastID += 1
        identifier = EventHotKeyID(signature: Self.signature, id: Self.lastID)
        self.onPress = onPress
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), dispatchHotKeyEvent, 1, &pressed,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw RegistrationError(status: installed) }
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), identifier,
                                             GetApplicationEventTarget(), 0, &registration)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw RegistrationError(status: registered)
        }
    }

    isolated deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }

    fileprivate func receive(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == identifier.signature, pressed.id == identifier.id else {
            return OSStatus(eventNotHandledErr)
        }
        onPress()
        return noErr
    }
}

private func dispatchHotKeyEvent(_: EventHandlerCallRef?, event: EventRef?, owner: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let owner else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                 nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    guard read == noErr else { return read }
    let received = pressed
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(owner).takeUnretainedValue()
    return MainActor.assumeIsolated { hotKey.receive(received) }
}
#endif
