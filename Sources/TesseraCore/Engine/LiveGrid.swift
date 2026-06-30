import Foundation
import CoreGraphics

/// One placed tile in the *live* grid the engine maintains after a tiling pass. Unlike `Tile`
/// (which is keyed by a per-enumeration UUID), a `GridTile` holds the live `AXWindowHandle`, so it
/// stays valid across re-enumerations and is what swap/resize interactions operate on.
public struct GridTile: Sendable {
    public let handle: AXWindowHandle
    public let bundleId: String?
    public let categoryId: String
    public let appName: String
    /// The frame Tessera last assigned this window, in CG (top-left) coordinates.
    public var target: CGRect

    public init(handle: AXWindowHandle, bundleId: String?, categoryId: String, appName: String, target: CGRect) {
        self.handle = handle
        self.bundleId = bundleId
        self.categoryId = categoryId
        self.appName = appName
        self.target = target
    }
}

/// Pure geometry for the two direct-manipulation gestures. No AX, no I/O — easy to reason about and
/// to check in `TesseraChecks`.
public enum Reflow {

    /// Edge-adjacency tolerance, in points: two edges this close (accounting for the gap) count as
    /// neighbors that should move together.
    public static let tolerance: CGFloat = 6

    /// Swap the target frames of the tiles at `i` and `j`.
    public static func swapped(_ tiles: [GridTile], _ i: Int, _ j: Int) -> [GridTile] {
        guard tiles.indices.contains(i), tiles.indices.contains(j), i != j else { return tiles }
        var out = tiles
        let tmp = out[i].target
        out[i].target = out[j].target
        out[j].target = tmp
        return out
    }

    /// Given a window resized from `oldFrame` to `newFrame`, adjust the direct neighbors that shared
    /// the moved edge so the layout stays gapless and non-overlapping. Returns updated targets
    /// (including the resized tile, now `newFrame`). Only direct neighbors are touched.
    public static func afterResize(
        tiles: [GridTile],
        resizedIndex: Int,
        oldFrame: CGRect,
        newFrame: CGRect,
        gap: CGFloat,
        minSize: CGSize = AXWindow.minTileableSize
    ) -> [GridTile] {
        guard tiles.indices.contains(resizedIndex) else { return tiles }
        var out = tiles
        out[resizedIndex].target = newFrame

        let dRight = newFrame.maxX - oldFrame.maxX
        let dLeft = newFrame.minX - oldFrame.minX
        let dBottom = newFrame.maxY - oldFrame.maxY
        let dTop = newFrame.minY - oldFrame.minY

        for k in out.indices where k != resizedIndex {
            var f = out[k].target

            // Neighbor immediately to the RIGHT of the resized window: its left edge tracked the
            // resized window's right edge. Move its left edge, keep its right edge fixed.
            if abs(dRight) > 0.5,
               approxEqual(f.minX, oldFrame.maxX + gap),
               verticallyOverlapping(f, oldFrame) {
                let newMinX = newFrame.maxX + gap
                f = CGRect(x: newMinX, y: f.minY, width: max(minSize.width, f.maxX - newMinX), height: f.height)
            }
            // Neighbor to the LEFT: keep its left edge, move its right edge to the resized left edge.
            if abs(dLeft) > 0.5,
               approxEqual(f.maxX, oldFrame.minX - gap),
               verticallyOverlapping(f, oldFrame) {
                let newMaxX = newFrame.minX - gap
                f = CGRect(x: f.minX, y: f.minY, width: max(minSize.width, newMaxX - f.minX), height: f.height)
            }
            // Neighbor BELOW: move its top edge, keep its bottom edge.
            if abs(dBottom) > 0.5,
               approxEqual(f.minY, oldFrame.maxY + gap),
               horizontallyOverlapping(f, oldFrame) {
                let newMinY = newFrame.maxY + gap
                f = CGRect(x: f.minX, y: newMinY, width: f.width, height: max(minSize.height, f.maxY - newMinY))
            }
            // Neighbor ABOVE: keep its top edge, move its bottom edge.
            if abs(dTop) > 0.5,
               approxEqual(f.maxY, oldFrame.minY - gap),
               horizontallyOverlapping(f, oldFrame) {
                let newMaxY = newFrame.minY - gap
                f = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(minSize.height, newMaxY - f.minY))
            }

            out[k].target = f
        }
        return out
    }

    /// Index of the tile whose target frame contains `point`, if any.
    public static func indexOfTile(containing point: CGPoint, in tiles: [GridTile]) -> Int? {
        tiles.firstIndex { $0.target.contains(point) }
    }

    // MARK: - Helpers

    private static func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }

    private static func verticallyOverlapping(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY < b.maxY - tolerance && a.maxY > b.minY + tolerance
    }
    private static func horizontallyOverlapping(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - tolerance && a.maxX > b.minX + tolerance
    }
}
