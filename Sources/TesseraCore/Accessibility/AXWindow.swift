import Foundation
import ApplicationServices
import CoreGraphics

/// Thin wrapper over a single window's `AXUIElement`, exposing typed reads/writes of its
/// position and size. All geometry here is in CG/AX (top-left) coordinates — the native space
/// of `kAXPositionAttribute`.
public struct AXWindow: @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    /// The standard window element under a CG (top-left) screen point, if any — used to find the
    /// window being dragged. Walks from the hit element up to its containing window.
    public static func window(atCG point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        // Most elements expose their containing window via kAXWindowAttribute.
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &win) == .success, let win {
            return AXWindow(win as! AXUIElement)
        }
        return AXWindow(element)
    }

    /// The owning process id, if available.
    public var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(element, &p) == .success ? p : nil
    }

    /// Whether the underlying element is still a live, readable window. A window whose app has closed
    /// it returns an error for any attribute read — use this to prune stale grid entries.
    public var isAlive: Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success
    }

    // MARK: - Reads

    public var title: String {
        copyString(kAXTitleAttribute) ?? ""
    }

    public var isMinimized: Bool {
        copyBool(kAXMinimizedAttribute) ?? false
    }

    /// Smallest window we'll bother tiling. Below this it's almost certainly a transient panel,
    /// HUD, or tool palette that should be left to float.
    public static let minTileableSize = CGSize(width: 240, height: 160)

    /// Whether this window should participate in tiling. We only manage real, movable, resizable
    /// document/app windows — everything transient (alerts, modal sheets, preference panes,
    /// floating panels, popovers, tool palettes) is left alone to overlay.
    ///
    /// The filter is layered because no single attribute is sufficient:
    ///   • role/subrole must be a standard window (excludes dialogs, sheets, floating panels);
    ///   • position *and* size must be settable (a fixed-size preferences window reports size as
    ///     non-settable, which is exactly the signal we want);
    ///   • it must not be a modal window;
    ///   • it must be at least `minTileableSize` (filters tiny HUDs/palettes that slip through).
    public var isTileable: Bool {
        guard role() == kAXWindowRole as String else { return false }
        guard subrole() == kAXStandardWindowSubrole as String else { return false }
        guard isSettable(kAXPositionAttribute), isSettable(kAXSizeAttribute) else { return false }
        if isModal { return false }
        if let s = size, s.width < Self.minTileableSize.width || s.height < Self.minTileableSize.height {
            return false
        }
        return true
    }

    /// Modal windows (e.g. an app's modal dialog presented as a window) should overlay, not tile.
    public var isModal: Bool {
        copyBool(kAXModalAttribute) ?? false
    }

    public var position: CGPoint? {
        copyValue(kAXPositionAttribute, type: .cgPoint)
    }

    public var size: CGSize? {
        copyValue(kAXSizeAttribute, type: .cgSize)
    }

    /// Current frame in CG (top-left) coordinates.
    public var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: - Writes

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    /// Apply a full frame using the **size → position → size** dance. macOS clamps a window's size
    /// to its *current* display before the move lands, so a single set-size can be silently shrunk
    /// when moving across displays. Setting size, then position, then size again works around it —
    /// this is the same workaround Rectangle uses in `AccessibilityElement.swift`.
    @discardableResult
    public func setFrame(_ frame: CGRect) -> Bool {
        let size = frame.size
        let origin = frame.origin
        let s1 = setSize(size)
        let p = setPosition(origin)
        let s2 = setSize(size)
        return s1 && p && s2
    }

    // MARK: - Private attribute helpers

    private func role() -> String? {
        copyString(kAXRoleAttribute)
    }

    private func subrole() -> String? {
        copyString(kAXSubroleAttribute)
    }

    private func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    private func copyString(_ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func copyBool(_ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? Bool)
    }

    private func copyValue<T>(_ attribute: String, type: AXValueType) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let axValue = ref, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }

        let value = axValue as! AXValue
        if type == .cgPoint {
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
            return point as? T
        } else if type == .cgSize {
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else { return nil }
            return size as? T
        }
        return nil
    }
}
