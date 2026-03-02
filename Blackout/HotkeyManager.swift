import Cocoa
import Carbon.HIToolbox

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var escapeTimestamps: [Date] = []

    var onHotkeyPressed: (() -> Void)?
    var onEscapeTriplePress: (() -> Void)?

    // Stored hotkey config
    private(set) var keyCode: UInt32 = 0
    private(set) var modifiers: UInt32 = 0
    private(set) var isConfigured: Bool = false

    private static let keyCodeKey = "hotkeyKeyCode"
    private static let modifiersKey = "hotkeyModifiers"
    private static let configuredKey = "hotkeyConfigured"

    init() {
        loadFromDefaults()
        if isConfigured {
            registerHotkey()
        }
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        isConfigured = defaults.bool(forKey: Self.configuredKey)
        if isConfigured {
            keyCode = UInt32(defaults.integer(forKey: Self.keyCodeKey))
            modifiers = UInt32(defaults.integer(forKey: Self.modifiersKey))
        }
    }

    private func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.configuredKey)
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
    }

    // MARK: - Configuration

    func configure(keyCode: UInt32, modifiers: UInt32) {
        unregisterHotkey()
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isConfigured = true
        saveToDefaults()
        registerHotkey()
    }

    // MARK: - Registration via Carbon API

    private func registerHotkey() {
        guard isConfigured else { return }

        let hotkeyID = EventHotKeyID(signature: OSType(0x424C4B4F), id: 1) // "BLKO"

        // Install handler if not already installed
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let handlerBlock: EventHandlerUPP = { _, event, userData -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onHotkeyPressed?()
                return noErr
            }
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetEventDispatcherTarget(), handlerBlock, 1, &eventType, selfPtr, &eventHandler)
        }

        var carbonModifiers: UInt32 = 0
        if modifiers & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { carbonModifiers |= UInt32(cmdKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { carbonModifiers |= UInt32(optionKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { carbonModifiers |= UInt32(controlKey) }
        if modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { carbonModifiers |= UInt32(shiftKey) }

        let id = hotkeyID
        RegisterEventHotKey(keyCode, carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Triple-Escape Detection

    /// Call this from the overlay window's keyDown handler.
    /// No Accessibility permissions needed — the overlay window is key and receives events directly.
    func recordEscapePress() {
        let now = Date()
        escapeTimestamps.append(now)
        escapeTimestamps = escapeTimestamps.filter { now.timeIntervalSince($0) < 1.5 }

        if escapeTimestamps.count >= 3 {
            escapeTimestamps.removeAll()
            onEscapeTriplePress?()
        }
    }

    // MARK: - Display Helpers

    func hotkeyDisplayString() -> String {
        guard isConfigured else { return "Not set" }
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if mods.contains(.control) { parts.append("^") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }

        let keyString = keyStringFromCode(keyCode)
        parts.append(keyString)
        return parts.joined()
    }

    private func keyStringFromCode(_ code: UInt32) -> String {
        let mapping: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
            118: "F4", 120: "F2", 122: "F1",
            123: "Left", 124: "Right", 125: "Down", 126: "Up",
        ]
        return mapping[code] ?? "Key\(code)"
    }

    // MARK: - Enable / Disable

    func disable() {
        unregisterHotkey()
    }

    func enable() {
        guard isConfigured, hotKeyRef == nil else { return }
        registerHotkey()
    }

    deinit {
        unregisterHotkey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
}
