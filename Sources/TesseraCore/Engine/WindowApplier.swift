import Foundation
import CoreGraphics

/// Applies a `LayoutPlan` to live windows via the Accessibility API.
public struct WindowApplier {

    /// Apply the plan, looking each window up by id in `windows`. Returns the number of windows
    /// successfully moved.
    @discardableResult
    public func apply(plan: LayoutPlan, to windows: [ManagedWindow]) -> Int {
        let byId = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var moved = 0
        for tile in plan.tiles {
            guard let window = byId[tile.windowId] else { continue }
            let axWindow = AXWindow(window.axHandle.element)
            if axWindow.setFrame(tile.frame) {
                moved += 1
            }
        }
        return moved
    }

    /// Apply grid tiles directly via their live AX handles (used by swap and resize-reflow).
    @discardableResult
    public func applyGrid(_ tiles: [GridTile]) -> Int {
        var moved = 0
        for tile in tiles {
            if AXWindow(tile.handle.element).setFrame(tile.target) { moved += 1 }
        }
        return moved
    }
}
