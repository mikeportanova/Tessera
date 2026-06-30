import Foundation
import Carbon

/// The selectable system-wide shortcuts for "Tile Now". Kept to a small set of conflict-free combos
/// rather than a full key recorder (which would need a third-party dependency).
public enum TileShortcut: String, CaseIterable, Codable, Sendable {
    case ctrlOptCmdT      // ⌃⌥⌘T  — default; "T" for Tile, the rarely-used hyper-ish combo
    case optCmdT          // ⌥⌘T
    case ctrlOptCmdSpace  // ⌃⌥⌘Space
    case hyperReturn      // ⌃⌥⌘↩
    case disabled         // no global shortcut

    public var displayName: String {
        switch self {
        case .ctrlOptCmdT:     return "⌃⌥⌘T"
        case .optCmdT:         return "⌥⌘T"
        case .ctrlOptCmdSpace: return "⌃⌥⌘Space"
        case .hyperReturn:     return "⌃⌥⌘↩"
        case .disabled:        return "Off"
        }
    }

    /// Carbon virtual key code, or nil when disabled.
    var keyCode: UInt32? {
        switch self {
        case .ctrlOptCmdT, .optCmdT: return UInt32(kVK_ANSI_T)
        case .ctrlOptCmdSpace:       return UInt32(kVK_Space)
        case .hyperReturn:           return UInt32(kVK_Return)
        case .disabled:              return nil
        }
    }

    /// Carbon modifier mask.
    var carbonModifiers: UInt32 {
        switch self {
        case .ctrlOptCmdT, .ctrlOptCmdSpace, .hyperReturn:
            return UInt32(controlKey | optionKey | cmdKey)
        case .optCmdT:
            return UInt32(optionKey | cmdKey)
        case .disabled:
            return 0
        }
    }
}

/// Registers a single global hotkey via Carbon and invokes `onPressed` when it fires. Carbon hotkeys
/// work system-wide and — unlike event taps — need no Accessibility permission. The handler is
/// delivered on the main run loop.
@MainActor
public final class HotKeyManager {
    public var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public init() {}

    /// Register (or, for `.disabled`, clear) the given shortcut. Safe to call repeatedly.
    public func apply(_ shortcut: TileShortcut) {
        unregister()
        guard let keyCode = shortcut.keyCode else { return }
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: 1)
        RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    fileprivate func fire() { onPressed?() }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec, context, &handlerRef)
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// Four-char-code signature 'TESS' identifying our hotkey.
    static let signature: OSType = {
        "TESS".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()
}

/// C callback for the Carbon hotkey event. Fires on the main run loop, so main-actor isolation holds.
private func hotKeyEventCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.fire() }
    return noErr
}
