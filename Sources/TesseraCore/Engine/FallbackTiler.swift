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

        // Choose a column count and group windows into columns.
        let columns = max(1, min(ordered.count, columnCount(for: ordered.count)))
        let rowsPerColumn = Int(ceil(Double(ordered.count) / Double(columns)))
        var columnWindows: [[ManagedWindow]] = []
        for c in 0..<columns {
            let start = c * rowsPerColumn
            let end = min(ordered.count, start + rowsPerColumn)
            if start < end { columnWindows.append(Array(ordered[start..<end])) }
        }
        let nCols = columnWindows.count

        // Equal split is the upper bound for a column; cap each column to the narrowest max width
        // among its windows so nothing is over-stretched.
        let equalColWidth = (area.width - g * CGFloat(nCols + 1)) / CGFloat(nCols)
        func columnMax(_ ws: [ManagedWindow]) -> CGFloat {
            ws.map { catalog.maxWidth(id: $0.categoryId, bundleId: $0.bundleId, usableWidth: area.width, learned: learned) }.min() ?? equalColWidth
        }
        let colWidths = columnWindows.map { min(equalColWidth, columnMax($0)) }

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
