import Foundation
import CoreGraphics

/// A deterministic, offline tiler used when no API key is set or the LLM call fails. It is
/// intentionally simple — a column-based split that respects each app's width prior — so the app is
/// always useful even without Claude.
public enum FallbackTiler {

    public static func plan(
        display: DisplayInfo,
        windows: [ManagedWindow],
        gap: Double,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty
    ) -> LayoutPlan {
        let area = display.visibleFrame
        let g = CGFloat(gap)
        guard !windows.isEmpty else {
            return LayoutPlan(displaySignature: display.signature, tiles: [])
        }

        // Order widest-preference first (using learned priors when present) for a stable,
        // sensible left-to-right arrangement.
        func prior(_ w: ManagedWindow) -> Double { catalog.widthPrior(id: w.categoryId, bundleId: w.bundleId, learned: learned) }
        let ordered = windows.sorted { prior($0) > prior($1) }

        func group(into cols: Int) -> [[ManagedWindow]] {
            let rpc = Int(ceil(Double(ordered.count) / Double(cols)))
            var out: [[ManagedWindow]] = []
            var i = 0
            while i < ordered.count { out.append(Array(ordered[i..<min(ordered.count, i + rpc)])); i += rpc }
            return out
        }
        // A column must be at least the widest minimum among its windows, and at most the narrowest
        // maximum — so e.g. a chat window with a sidebar keeps its minimum even on a small display.
        func columnMin(_ ws: [ManagedWindow]) -> CGFloat {
            ws.map { catalog.profile(id: $0.categoryId).minWidth }.max() ?? 0
        }
        func columnMax(_ ws: [ManagedWindow]) -> CGFloat {
            ws.map { catalog.maxWidth(id: $0.categoryId, bundleId: $0.bundleId, usableWidth: area.width, learned: learned) }.min() ?? area.width
        }

        // Pick the most columns (up to the preference) whose minimum widths actually fit the usable
        // width — fewer columns on a narrow display rather than squeezing windows below their min.
        let desired = max(1, min(ordered.count, columnCount(for: ordered.count)))
        var columnWindows = group(into: 1)
        var c = desired
        while c >= 1 {
            let candidate = group(into: c)
            let totalMin = candidate.map(columnMin).reduce(0, +) + g * CGFloat(candidate.count + 1)
            if c == 1 || totalMin <= area.width { columnWindows = candidate; break }
            c -= 1
        }
        let nCols = columnWindows.count

        // Start every column at its minimum, then distribute the leftover width up to each column's
        // max. Anything still left over stays as empty desktop on the right (we never over-stretch).
        let inner = area.width - g * CGFloat(nCols + 1)
        let maxes = columnWindows.map(columnMax)
        var colWidths = columnWindows.enumerated().map { min(columnMin($0.element), maxes[$0.offset], inner) }
        var remaining = inner - colWidths.reduce(0, +)
        var headroom = colWidths.indices.map { Swift.max(0, maxes[$0] - colWidths[$0]) }
        while remaining > 0.5, headroom.contains(where: { $0 > 0.5 }) {
            let active = colWidths.indices.filter { headroom[$0] > 0.5 }
            let share = remaining / CGFloat(active.count)
            for i in active {
                let add = Swift.min(share, headroom[i])
                colWidths[i] += add; headroom[i] -= add; remaining -= add
            }
        }

        // Pack tiles from the left edge toward the right; any unused width is left as empty desktop
        // on the right side (we do NOT center the block).
        var tiles: [Tile] = []
        var xCursor = area.minX + g
        for (c, ws) in columnWindows.enumerated() {
            let cw = colWidths[c]
            let rows = ws.count
            let rowHeight = (area.height - g * CGFloat(rows + 1)) / CGFloat(rows)
            for (r, window) in ws.enumerated() {
                let y = area.minY + g + CGFloat(r) * (rowHeight + g)
                // Cap height to the window's max so a tall display doesn't over-stretch it; the tile
                // stays anchored at the top of its row slot, leaving any extra as empty desktop.
                let maxH = catalog.maxHeight(id: window.categoryId, bundleId: window.bundleId, usableHeight: area.height, learned: learned)
                let h = min(rowHeight, maxH)
                tiles.append(Tile(windowId: window.id, frame: CGRect(x: xCursor, y: y, width: cw, height: h)))
            }
            xCursor += cw + g
        }
        return LayoutPlan(displaySignature: display.signature, tiles: tiles)
    }

    private static func columnCount(for n: Int) -> Int {
        switch n {
        case 1: return 1
        case 2: return 2
        case 3, 4: return 2
        default: return Int(ceil(sqrt(Double(n))))
        }
    }
}
