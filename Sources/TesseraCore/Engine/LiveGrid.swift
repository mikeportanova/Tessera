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

    /// Given a window resized from `oldFrame` to `newFrame`, adjust its neighbors so the layout stays
    /// gapless and non-overlapping. Returns updated targets (including the resized tile, now
    /// `newFrame`).
    ///
    /// Each moved edge of the resized window is treated as a **divider**, and every tile whose own
    /// edge lines up with that divider tracks it — both the tile on the *opposite* side (its facing
    /// edge sits one gap away) and any tile on the *same* side (its matching edge coincides, e.g. a
    /// tile stacked in the same column). Because a tile can border two moved dividers at once, this
    /// also resizes the **diagonal** tile in a grid — dragging a window's corner keeps the whole grid
    /// clean rather than leaving the diagonal behind. Alignment is the guard: only tiles whose edges
    /// actually coincide with a moved divider are touched, so unrelated tiles stay put.
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

            // Vertical divider at the resized window's RIGHT edge.
            if abs(dRight) > 0.5 {
                if approxEqual(f.minX, oldFrame.maxX + gap) {          // tile to the right → move its left edge
                    let newMinX = newFrame.maxX + gap
                    f = CGRect(x: newMinX, y: f.minY, width: max(minSize.width, f.maxX - newMinX), height: f.height)
                } else if approxEqual(f.maxX, oldFrame.maxX) {         // tile sharing that right edge → move its right edge
                    f = CGRect(x: f.minX, y: f.minY, width: max(minSize.width, newFrame.maxX - f.minX), height: f.height)
                }
            }
            // Vertical divider at the resized window's LEFT edge.
            if abs(dLeft) > 0.5 {
                if approxEqual(f.maxX, oldFrame.minX - gap) {          // tile to the left → move its right edge
                    let newMaxX = newFrame.minX - gap
                    f = CGRect(x: f.minX, y: f.minY, width: max(minSize.width, newMaxX - f.minX), height: f.height)
                } else if approxEqual(f.minX, oldFrame.minX) {         // tile sharing that left edge → move its left edge
                    let newMinX = newFrame.minX
                    f = CGRect(x: newMinX, y: f.minY, width: max(minSize.width, f.maxX - newMinX), height: f.height)
                }
            }
            // Horizontal divider at the resized window's BOTTOM edge.
            if abs(dBottom) > 0.5 {
                if approxEqual(f.minY, oldFrame.maxY + gap) {          // tile below → move its top edge
                    let newMinY = newFrame.maxY + gap
                    f = CGRect(x: f.minX, y: newMinY, width: f.width, height: max(minSize.height, f.maxY - newMinY))
                } else if approxEqual(f.maxY, oldFrame.maxY) {         // tile sharing that bottom edge → move its bottom edge
                    f = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(minSize.height, newFrame.maxY - f.minY))
                }
            }
            // Horizontal divider at the resized window's TOP edge.
            if abs(dTop) > 0.5 {
                if approxEqual(f.maxY, oldFrame.minY - gap) {          // tile above → move its bottom edge
                    let newMaxY = newFrame.minY - gap
                    f = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(minSize.height, newMaxY - f.minY))
                } else if approxEqual(f.minY, oldFrame.minY) {         // tile sharing that top edge → move its top edge
                    let newMinY = newFrame.minY
                    f = CGRect(x: f.minX, y: newMinY, width: f.width, height: max(minSize.height, f.maxY - newMinY))
                }
            }

            out[k].target = f
        }
        return out
    }

    /// Index of the tile whose target frame contains `point`, if any.
    public static func indexOfTile(containing point: CGPoint, in tiles: [GridTile]) -> Int? {
        tiles.firstIndex { $0.target.contains(point) }
    }

    /// Height (points) of the title-bar grab strip at the top of a tile. You move a macOS window by
    /// its title bar, so a drag that *starts* here is a window move; a drag starting below it is
    /// content (e.g. dragging a file out of the window) and must not trigger a swap.
    public static let titleBarGrabHeight: CGFloat = 30

    /// Index of the tile whose **title-bar strip** contains `point` (CG top-left coords), if any.
    public static func indexOfTile(titleBarContaining point: CGPoint, in tiles: [GridTile]) -> Int? {
        tiles.firstIndex { tile in
            let h = Swift.min(titleBarGrabHeight, tile.target.height)
            let bar = CGRect(x: tile.target.minX, y: tile.target.minY, width: tile.target.width, height: h)
            return bar.contains(point)
        }
    }

    // MARK: - Helpers

    private static func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
}

/// Pure geometry for Magnet-style drag-to-snap: the empty rectangle a window would fill at a point,
/// and the edge-biased half/quarter of it.
public enum Snap {
    /// Largest empty axis-aligned rectangle containing `point`, within `area`, avoiding `occupied`.
    /// Returns nil if the point is inside an occupied rect (caller should treat that as a swap, not
    /// a snap).
    ///
    /// The optimal rectangle's edges always line up with either the work-area edge or an obstacle
    /// edge, so we enumerate those candidate edges on each axis and search every
    /// (left,right) × (bottom,top) combination that brackets the point, keeping the largest one whose
    /// interior touches no obstacle. Candidates are tried widest-first so the cheap area check prunes
    /// the rest before the obstacle test runs. Unlike a greedy shrink, this always finds the true
    /// maximum even when several windows border the open region (the L-shaped gaps real desktops
    /// produce). Window counts are small, so the full search is inexpensive.
    public static func largestEmptyRect(containing point: CGPoint, in area: CGRect, avoiding occupied: [CGRect]) -> CGRect? {
        guard area.contains(point) else { return nil }

        // Clip obstacles to the work area; a pointer sitting inside one means "swap", not "snap".
        var obstacles: [CGRect] = []
        for o in occupied {
            let c = o.intersection(area)
            if c.isNull || c.isEmpty { continue }
            if c.contains(point) { return nil }
            obstacles.append(c)
        }

        // Candidate edges: work-area bounds plus every obstacle edge.
        var xSet = Set<CGFloat>([area.minX, area.maxX])
        var ySet = Set<CGFloat>([area.minY, area.maxY])
        for o in obstacles {
            xSet.insert(o.minX); xSet.insert(o.maxX)
            ySet.insert(o.minY); ySet.insert(o.maxY)
        }
        // Order so the widest/tallest spans come first → the area prune below stays effective.
        let lefts   = xSet.filter { $0 <= point.x }.sorted()          // smaller x first → wider
        let rights  = xSet.filter { $0 >= point.x }.sorted(by: >)     // larger x first  → wider
        let bottoms = ySet.filter { $0 <= point.y }.sorted()
        let tops    = ySet.filter { $0 >= point.y }.sorted(by: >)

        func hitsObstacle(_ r: CGRect) -> Bool {
            for o in obstacles {
                let i = o.intersection(r)
                if !i.isNull && i.width > 0.5 && i.height > 0.5 { return true }
            }
            return false
        }

        var best: CGRect?
        var bestArea: CGFloat = 0
        for l in lefts {
            for r in rights where r - l > 1 {
                let width = r - l
                for b in bottoms {
                    for t in tops where t - b > 1 {
                        let a = width * (t - b)
                        if a <= bestArea { continue }            // cheap prune before the obstacle test
                        let cand = CGRect(x: l, y: b, width: width, height: t - b)
                        if hitsObstacle(cand) { continue }
                        bestArea = a; best = cand
                    }
                }
            }
        }
        return best
    }

    /// Bias an empty rect toward the cursor: near a left/right edge → that half; near top/bottom →
    /// that half; a corner → that quarter; the middle → the whole rect. `edgeZone` is the fraction
    /// of each side that counts as "near."
    public static func biased(_ empty: CGRect, toward cursor: CGPoint, edgeZone: CGFloat = 0.33) -> CGRect {
        var r = empty
        if cursor.x < empty.minX + empty.width * edgeZone {
            r = CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        } else if cursor.x > empty.maxX - empty.width * edgeZone {
            r = CGRect(x: empty.midX, y: r.minY, width: r.width / 2, height: r.height)
        }
        if cursor.y < empty.minY + empty.height * edgeZone {
            r = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        } else if cursor.y > empty.maxY - empty.height * edgeZone {
            r = CGRect(x: r.minX, y: r.minY + r.height / 2, width: r.width, height: r.height / 2)
        }
        return r
    }

    /// A snap zone wider than this ratio (width ÷ height) is an absurd short-and-wide sliver, so we
    /// don't propose it. Tall-and-narrow is intentionally left alone — thin columns (chat, terminals)
    /// are legitimate window shapes.
    public static let maxWidthToHeightRatio: CGFloat = 3.0

    /// Whether a proposed snap rect has a sensible width-to-height ratio (not a super-wide sliver).
    public static func isReasonablyShaped(_ rect: CGRect) -> Bool {
        rect.height > 0 && rect.width / rect.height <= maxWidthToHeightRatio
    }

    /// Whether a snap zone is worth proposing within `area`.
    ///
    /// Two filters: the zone must be at least as big as the smallest window Tessera manages (no point
    /// offering a slot no tileable window fits), and a *short* super-wide sliver is rejected — but a
    /// full-height wide zone (e.g. maximizing on a genuine ultrawide display) always passes, so the
    /// aspect guard only applies to zones that are also short (well under the display's height).
    public static func isProposable(_ rect: CGRect, in area: CGRect, minSize: CGSize = AXWindow.minTileableSize) -> Bool {
        guard rect.width >= minSize.width, rect.height >= minSize.height else { return false }
        let isShort = rect.height < area.height * 0.6
        return !isShort || isReasonablyShaped(rect)
    }

    /// Frame for the left or right half of a work area, honoring the gap (Magnet-style quick snap).
    public static func half(left: Bool, of area: CGRect, gap: CGFloat) -> CGRect {
        let w = (area.width - 3 * gap) / 2
        let x = left ? area.minX + gap : area.minX + 2 * gap + w
        return CGRect(x: x, y: area.minY + gap, width: w, height: area.height - 2 * gap)
    }

    /// Frame filling the work area, honoring the gap (Magnet-style maximize; not macOS full screen).
    public static func maximized(of area: CGRect, gap: CGFloat) -> CGRect {
        area.insetBy(dx: gap, dy: gap)
    }

    /// Cap a proposed snap rect's width to at most `maxFraction` of the display, unless it's a genuine
    /// full-screen suggestion (full width *and* full height). A rect that spans the whole width but
    /// only part of the height looks absurd on a wide display, so we trim it to the half the cursor is
    /// in. Height is never capped — a full-height column is a perfectly good tile.
    public static func capWidth(_ rect: CGRect, in area: CGRect, toward cursor: CGPoint, maxFraction: CGFloat = 0.5) -> CGRect {
        let fullWidth = rect.width >= area.width - 1
        let fullHeight = rect.height >= area.height - 1
        if fullWidth && fullHeight { return rect }          // real full-screen → leave it
        let cap = area.width * maxFraction
        guard rect.width > cap + 1 else { return rect }
        // Keep the capped rect on the side of its midline the cursor sits on.
        let minX = cursor.x <= rect.midX ? rect.minX : rect.maxX - cap
        return CGRect(x: minX, y: rect.minY, width: cap, height: rect.height)
    }
}
