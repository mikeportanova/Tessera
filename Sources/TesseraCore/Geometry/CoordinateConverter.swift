import Foundation
import CoreGraphics
import AppKit

/// THE single source of truth for converting between the two macOS coordinate systems.
///
/// - **AppKit** (`NSScreen`, `NSWindow`): origin **bottom-left**, Y increases **upward**.
/// - **CoreGraphics / Accessibility** (`CGWindowList`, `kAXPositionAttribute`,
///   `CGDirectDisplay…`): origin **top-left**, Y increases **downward**.
///
/// The flip pivots on the *primary* display's full height, because the global CG coordinate
/// space is anchored to the primary (menu-bar) display's top-left. Every geometry value that
/// crosses the AppKit↔AX boundary must go through here — do not hand-roll the flip elsewhere.
public enum CoordinateConverter {

    /// Full height of the primary display in points. CG's global origin sits at the top-left of
    /// this display, so it is the pivot for every Y flip.
    ///
    /// `NSScreen.screens.first` is, by Apple's contract, the display containing the menu bar,
    /// i.e. the primary/origin display. Falls back to `main` then to a sane default.
    public static func primaryDisplayHeight(
        screens: [NSScreen] = NSScreen.screens
    ) -> CGFloat {
        (screens.first ?? NSScreen.main)?.frame.height ?? 0
    }

    // MARK: - Point conversion

    /// Convert a point from AppKit (bottom-left) space to CG/AX (top-left) space.
    /// The conversion is an involution given a fixed pivot height — applying it twice returns the
    /// original (see `cgToAppKit`).
    public static func appKitToCG(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Convert a point from CG/AX (top-left) space to AppKit (bottom-left) space.
    public static func cgToAppKit(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: - Rect conversion

    /// Convert a rect from AppKit (bottom-left) space to CG/AX (top-left) space.
    ///
    /// In AppKit the rect's origin is its **bottom-left** corner; in CG it's the **top-left**
    /// corner. So we flip the bottom-left corner's Y and then subtract the height to land on the
    /// top edge: `cgY = primaryHeight - appKitY - height`.
    public static func appKitToCG(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Convert a rect from CG/AX (top-left) space to AppKit (bottom-left) space.
    /// This is the exact inverse of `appKitToCG(rect:)` — `cgY = primaryHeight - topLeftY - height`
    /// rearranges to the same formula, so the operation is its own inverse.
    public static func cgToAppKit(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
