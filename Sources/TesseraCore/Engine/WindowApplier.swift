import Foundation
import CoreGraphics

/// Applies a `LayoutPlan` to live windows via the Accessibility API.
public struct WindowApplier {

    /// Apply the plan, looking each window up by id in `windows`. Returns the number of windows
    /// successfully moved. When `clampTo` is given, each window is nudged back fully on-screen after
    /// placement — macOS refuses to shrink a window below its own minimum size, so a window that
    /// can't become as small as its tile would otherwise spill off the edge.
    @discardableResult
    public func apply(plan: LayoutPlan, to windows: [ManagedWindow], clampTo area: CGRect? = nil) -> Int {
        let byId = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var moved = 0
        for tile in plan.tiles {
            guard let window = byId[tile.windowId] else { continue }
            if applyFrame(tile.frame, to: AXWindow(window.axHandle.element), clampTo: area) { moved += 1 }
        }
        return moved
    }

    /// Apply grid tiles directly via their live AX handles (used by swap and resize-reflow).
    @discardableResult
    public func applyGrid(_ tiles: [GridTile], clampTo area: CGRect? = nil) -> Int {
        var moved = 0
        for tile in tiles {
            if applyFrame(tile.target, to: AXWindow(tile.handle.element), clampTo: area) { moved += 1 }
        }
        return moved
    }

    private func applyFrame(_ frame: CGRect, to window: AXWindow, clampTo area: CGRect?) -> Bool {
        let ok = window.setFrame(frame)
        // If the window couldn't shrink to the requested size, its real frame may now extend past
        // the usable area — re-read it and pull it back on-screen.
        if let area, let actual = window.frame,
           let corrected = WindowApplier.onScreenOrigin(for: actual, in: area),
           corrected != actual.origin {
            window.setPosition(corrected)
        }
        return ok
    }

    /// Origin that keeps `frame` fully within `area` when possible (aligns to the min edge if the
    /// window is larger than the area). Returns nil if no move is needed.
    public static func onScreenOrigin(for frame: CGRect, in area: CGRect) -> CGPoint? {
        var x = frame.minX, y = frame.minY
        if frame.maxX > area.maxX { x = area.maxX - frame.width }
        if frame.maxY > area.maxY { y = area.maxY - frame.height }
        if x < area.minX { x = area.minX }
        if y < area.minY { y = area.minY }
        let origin = CGPoint(x: x, y: y)
        return origin == frame.origin ? nil : origin
    }
}
