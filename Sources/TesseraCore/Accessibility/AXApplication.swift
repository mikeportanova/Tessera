import Foundation
import ApplicationServices
import AppKit

/// Wrapper over an application-level `AXUIElement` (created from a pid). Provides the app's
/// tileable windows.
public struct AXApplication {
    public let pid: pid_t
    public let element: AXUIElement

    public init(pid: pid_t) {
        self.pid = pid
        self.element = AXUIElementCreateApplication(pid)
        // Cap how long a synchronous AX request to this app may block. Without this, querying a
        // hung or busy app would stall our (main-thread) enumeration indefinitely. Window elements
        // copied from this app inherit the app element's timeout.
        AXUIElementSetMessagingTimeout(element, 1.0)
    }

    /// All standard, tileable windows for this app, in AX order.
    public func windows() -> [AXWindow] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement]
        else { return [] }

        return array
            .map { AXWindow($0) }
            .filter { $0.isTileable && !$0.isMinimized }
    }
}
