import Foundation
import AppKit
import CoreGraphics

/// Enumerates the connected displays as `DisplayInfo` in CG (top-left) coordinates.
public enum DisplayProvider {

    /// All active displays, sorted with the primary first.
    public static func displays() -> [DisplayInfo] {
        let primaryHeight = CoordinateConverter.primaryDisplayHeight()
        let screens = NSScreen.screens

        return screens.map { screen in
            let displayID = screen.displayID
            // NSScreen frames are AppKit (bottom-left); convert to CG (top-left) for our model.
            let cgFrame = CoordinateConverter.appKitToCG(rect: screen.frame, primaryHeight: primaryHeight)
            let cgVisible = CoordinateConverter.appKitToCG(rect: screen.visibleFrame, primaryHeight: primaryHeight)
            let isPrimary = screen == screens.first
            return DisplayInfo(
                id: displayID,
                frame: cgFrame,
                visibleFrame: cgVisible,
                backingScale: screen.backingScaleFactor,
                isPrimary: isPrimary
            )
        }
    }

    /// The display whose visibleFrame contains the most of the given CG rect, defaulting to primary.
    public static func display(containing cgRect: CGRect) -> DisplayInfo? {
        let all = displays()
        return all.max { lhs, rhs in
            cgRect.intersection(lhs.visibleFrame).area < cgRect.intersection(rhs.visibleFrame).area
        } ?? all.first
    }
}

private extension NSScreen {
    /// The CGDirectDisplayID backing this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGRect {
    /// Area, treating a null/empty intersection as zero.
    var area: CGFloat { isNull ? 0 : width * height }

    /// Area of the overlap between this rect and `other` (zero if they don't intersect).
    func intersectionArea(_ other: CGRect) -> CGFloat { intersection(other).area }
}
