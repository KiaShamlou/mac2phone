import Foundation
import Carbon.HIToolbox

/// System-wide hotkeys, so the Mac can be driven without seeing its screen.
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false
    private var nextID: UInt32 = 1

    private init() {}

    /// `keyCode` is a virtual key code, `modifiers` a Carbon modifier mask.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D32_5048), id: id) // 'M2PH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)

        guard status == noErr else {
            handlers.removeValue(forKey: id)
            return false
        }
        refs.append(ref)
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.handlers[hotKeyID.id]?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    enum Mod {
        static let command = UInt32(cmdKey)
        static let option  = UInt32(optionKey)
        static let control = UInt32(controlKey)
        static let shift   = UInt32(shiftKey)
    }
}
