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

    /// Targets refreshed from the windows' live frames: any tile whose window drifted (was moved or
    /// resized outside the engine) adopts its live frame, so a stale target neither shadows space
    /// the user has vacated nor claims the window still sits where Tessera last put it.
    /// `liveFrames[i]` pairs with `tiles[i]`; nil (window unreadable) leaves that tile untouched.
    public static func synced(_ tiles: [GridTile], liveFrames: [CGRect?]) -> [GridTile] {
        var out = tiles
        for i in out.indices {
            guard i < liveFrames.count, let live = liveFrames[i] else { continue }
            let drift = abs(live.minX - out[i].target.minX) + abs(live.minY - out[i].target.minY)
                      + abs(live.width - out[i].target.width) + abs(live.height - out[i].target.height)
            if drift > tolerance { out[i].target = live }
        }
        return out
    }

    /// Given a window resized from `oldFrame` to `newFrame`, adjust its neighbors so the layout stays
    /// gapless and non-overlapping. Returns the updated targets (including the resized tile, now at
    /// `newFrame`).
    ///
    /// Each moved edge of the resized window is treated as a **divider**, and every tile whose own
    /// edge lines up with that divider tracks it — both the tile on the *opposite* side (its facing
    /// edge sits one gap away) and any tile on the *same* side (its matching edge coincides, e.g. a
    /// tile stacked in the same column). Because a tile can border two moved dividers at once, this
    /// also resizes the **diagonal** tile in a grid — dragging a window's corner keeps the whole grid
    /// clean rather than leaving the diagonal behind. Alignment alone isn't membership, though: a
    /// tile must also be **connected** to the resized window along the divider line (see
    /// `connectedAlongDivider`), so an unrelated divider elsewhere on screen that merely happens to
    /// share the coordinate stays put.
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

        let dRight  = newFrame.maxX - oldFrame.maxX
        let dLeft   = newFrame.minX - oldFrame.minX
        let dBottom = newFrame.maxY - oldFrame.maxY
        let dTop    = newFrame.minY - oldFrame.minY

        // Resolve each moved divider's membership up front. A tile joins only if its edge lies on
        // the divider line AND its span chains back to the resized window along that line.
        let xSpan = (lo: oldFrame.minX, hi: oldFrame.maxX)
        let ySpan = (lo: oldFrame.minY, hi: oldFrame.maxY)
        let onRight: Set<Int> = abs(dRight) <= 0.5 ? [] : connectedAlongDivider(
            tiles: tiles, resizedIndex: resizedIndex, seed: ySpan, gap: gap,
            onDivider: { approxEqual($0.minX, oldFrame.maxX + gap) || approxEqual($0.maxX, oldFrame.maxX) },
            span: { ($0.minY, $0.maxY) })
        let onLeft: Set<Int> = abs(dLeft) <= 0.5 ? [] : connectedAlongDivider(
            tiles: tiles, resizedIndex: resizedIndex, seed: ySpan, gap: gap,
            onDivider: { approxEqual($0.maxX, oldFrame.minX - gap) || approxEqual($0.minX, oldFrame.minX) },
            span: { ($0.minY, $0.maxY) })
        let onBottom: Set<Int> = abs(dBottom) <= 0.5 ? [] : connectedAlongDivider(
            tiles: tiles, resizedIndex: resizedIndex, seed: xSpan, gap: gap,
            onDivider: { approxEqual($0.minY, oldFrame.maxY + gap) || approxEqual($0.maxY, oldFrame.maxY) },
            span: { ($0.minX, $0.maxX) })
        let onTop: Set<Int> = abs(dTop) <= 0.5 ? [] : connectedAlongDivider(
            tiles: tiles, resizedIndex: resizedIndex, seed: xSpan, gap: gap,
            onDivider: { approxEqual($0.maxY, oldFrame.minY - gap) || approxEqual($0.minY, oldFrame.minY) },
            span: { ($0.minX, $0.maxX) })

        for k in out.indices where k != resizedIndex {
            var f = out[k].target

            // When honoring the moved divider would shrink a tile below `minSize`, the tile pins at
            // min size with its FAR edge held in place (the divider stops short for it), rather than
            // letting the far edge follow the origin past its old bound — that would shove it
            // over the next column/row or off-screen. The bounded overlap remains with the
            // resized window itself, which the user is actively dragging.

            // Vertical divider at the resized window's RIGHT edge.
            if onRight.contains(k) {
                if approxEqual(f.minX, oldFrame.maxX + gap) { // tile to the right → move left edge
                    let newMinX = min(newFrame.maxX + gap, f.maxX - minSize.width)
                    f = CGRect(x: newMinX, y: f.minY, width: f.maxX - newMinX, height: f.height)
                } else if approxEqual(f.maxX, oldFrame.maxX) { // tile sharing the right edge → move right edge
                    f = CGRect(x: f.minX, y: f.minY, width: max(minSize.width, newFrame.maxX - f.minX), height: f.height)
                }
            }
            // Vertical divider at the resized window's LEFT edge.
            if onLeft.contains(k) {
                if approxEqual(f.maxX, oldFrame.minX - gap) { // tile to the left → move right edge
                    let newMaxX = newFrame.minX - gap
                    f = CGRect(x: f.minX, y: f.minY, width: max(minSize.width, newMaxX - f.minX), height: f.height)
                } else if approxEqual(f.minX, oldFrame.minX) { // tile sharing the left edge → move left edge
                    let newMinX = min(newFrame.minX, f.maxX - minSize.width)
                    f = CGRect(x: newMinX, y: f.minY, width: f.maxX - newMinX, height: f.height)
                }
            }
            // Horizontal divider at the resized window's BOTTOM edge.
            if onBottom.contains(k) {
                if approxEqual(f.minY, oldFrame.maxY + gap) { // tile below → move top edge
                    let newMinY = min(newFrame.maxY + gap, f.maxY - minSize.height)
                    f = CGRect(x: f.minX, y: newMinY, width: f.width, height: f.maxY - newMinY)
                } else if approxEqual(f.maxY, oldFrame.maxY) { // tile sharing the bottom edge → move bottom edge
                    f = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(minSize.height, newFrame.maxY - f.minY))
                }
            }
            // Horizontal divider at the resized window's TOP edge.
            if onTop.contains(k) {
                if approxEqual(f.maxY, oldFrame.minY - gap) { // tile above → move bottom edge
                    let newMaxY = newFrame.minY - gap
                    f = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(minSize.height, newMaxY - f.minY))
                } else if approxEqual(f.minY, oldFrame.minY) { // tile sharing the top edge → move top edge
                    let newMinY = min(newFrame.minY, f.maxY - minSize.height)
                    f = CGRect(x: f.minX, y: newMinY, width: f.width, height: f.maxY - newMinY)
                }
            }

            out[k].target = f
        }
        return out
    }

    /// Tiles that belong to a moved divider. Edge alignment alone can't decide this: two
    /// independent dividers on opposite sides of the screen may share a coordinate by coincidence,
    /// and moving one must not move the other. Starting from the resized window's own extent along
    /// the divider (`seed`), spans grow through candidate tiles whose intervals touch the
    /// accumulated set (within gap + tolerance, so tiles meeting only at a gapped corner still
    /// chain — the diagonal tile in a 2×2 grid depends on this). Candidates whose span never
    /// connects back to the resized window are left out.
    private static func connectedAlongDivider(
        tiles: [GridTile],
        resizedIndex: Int,
        seed: (lo: CGFloat, hi: CGFloat),
        gap: CGFloat,
        onDivider: (CGRect) -> Bool,
        span: (CGRect) -> (lo: CGFloat, hi: CGFloat)
    ) -> Set<Int> {
        let slack = gap + tolerance
        var candidates: [(index: Int, span: (lo: CGFloat, hi: CGFloat))] = []
        for k in tiles.indices where k != resizedIndex && onDivider(tiles[k].target) {
            candidates.append((k, span(tiles[k].target)))
        }

        var spans = [seed]
        var included = Set<Int>()
        var grew = true
        while grew {
            grew = false
            for c in candidates where !included.contains(c.index) {
                if spans.contains(where: { c.span.lo <= $0.hi + slack && $0.lo <= c.span.hi + slack }) {
                    included.insert(c.index)
                    spans.append(c.span)
                    grew = true
                }
            }
        }
        return included
    }

    /// Index of the tile whose target frame contains `point`, if any.
    public static func indexOfTile(containing point: CGPoint, in tiles: [GridTile]) -> Int? {
        tiles.firstIndex { $0.target.contains(point) }
    }

    /// Height (points) of the title-bar grab strip at the top of a tile. You move a macOS window by
    /// its title bar, so a drag that *starts* here is a window move; a drag starting below it is
    /// content (e.g. dragging a file out of the window) and must not trigger a swap.
    public static let titleBarGrabHeight: CGFloat = 30

    /// Width of the invisible resize-handle band along a window's edges. A mouse-down this close to
    /// an edge is (or may be) a RESIZE grab, not a move — it must never arm swap/snap.
    public static let resizeHandleMargin: CGFloat = 10

    /// Whether a mouse-down at `point` (CG top-left coords) on a window with `frame` is a **move**
    /// grab: inside the title-bar strip but clear of the resize handles on the top/left/right edges.
    public static func isMoveGrab(point: CGPoint, frame: CGRect) -> Bool {
        let bar = CGRect(
            x: frame.minX + resizeHandleMargin,
            y: frame.minY + resizeHandleMargin / 2,                      // top resize band is thinner
            width: frame.width - 2 * resizeHandleMargin,
            height: titleBarGrabHeight - resizeHandleMargin / 2
        )
        return bar.contains(point)
    }

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
