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

/// Registers Tessera's global hotkeys via Carbon and routes each press to `onAction`. Carbon hotkeys
/// work system-wide and — unlike event taps — need no Accessibility permission. Handlers are
/// delivered on the main run loop.
@MainActor
public final class HotKeyManager {

    /// Everything a global shortcut can trigger. Raw value doubles as the Carbon hotkey id.
    public enum Action: UInt32, CaseIterable, Sendable {
        case tile = 1
        case leftHalf = 2      // ⌃⌥←
        case rightHalf = 3     // ⌃⌥→
        case maximize = 4      // ⌃⌥↩
        case undo = 5          // ⌃⌥⌘Z
    }

    public var onAction: ((Action) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    public init() {}

    /// (Re-)register the full shortcut set: the user's tile shortcut, the Magnet-style quick-snap
    /// keys when enabled, and undo (always on). Safe to call repeatedly.
    public func apply(tileShortcut: TileShortcut, quickSnapEnabled: Bool) {
        unregisterAll()
        installHandlerIfNeeded()

        if let keyCode = tileShortcut.keyCode {
            register(.tile, keyCode: keyCode, modifiers: tileShortcut.carbonModifiers)
        }
        if quickSnapEnabled {
            let ctrlOpt = UInt32(controlKey | optionKey)
            register(.leftHalf, keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt)
            register(.rightHalf, keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt)
            register(.maximize, keyCode: UInt32(kVK_Return), modifiers: ctrlOpt)
        }
        register(.undo, keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    fileprivate func fire(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        onAction?(action)
    }

    private func register(_ action: Action, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: action.rawValue)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { hotKeyRefs[action.rawValue] = ref }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec, context, &handlerRef)
    }

    private func unregisterAll() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    /// Four-char-code signature 'TESS' identifying our hotkeys.
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
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated { manager.fire(id: id) }
    return noErr
}
