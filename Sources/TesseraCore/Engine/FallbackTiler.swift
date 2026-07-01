import Foundation
import CoreGraphics

/// A deterministic, offline tiler used when no API key is set, when the user is in offline mode, or
/// when the LLM call fails. Windows arrive in recency order (front-most first).
///
/// When everything fits, it lays the windows out in a min-aware grid. When there are more windows
/// than can each get a comfortable tile, it tiles the most-recently-used windows properly and
/// demotes the older overflow to a small cascaded stack in the corner — rather than squeezing every
/// window down to an unusable (and off-screen-prone) sliver.
public enum FallbackTiler {

    /// A "real" tile should be at least this big; used to decide how many windows fit before the
    /// rest are demoted. Most apps refuse to shrink much below this anyway.
    public static let comfortableCell = CGSize(width: 460, height: 320)

    public static func plan(
        display: DisplayInfo,
        windows: [ManagedWindow],
        gap: Double,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty,
        intent: LayoutIntent = .automatic,
        rules: AppRules = .empty
    ) -> LayoutPlan {
        let area = display.visibleFrame
        let g = CGFloat(gap)
        guard !windows.isEmpty else {
            return LayoutPlan(displaySignature: display.signature, tiles: [])
        }

        // How many windows can each get a comfortable tile on this display?
        let maxCols = Swift.max(1, Int((area.width + g) / (comfortableCell.width + g)))
        let maxRows = Swift.max(1, Int((area.height + g) / (comfortableCell.height + g)))
        let capacity = maxCols * maxRows

        // `windows` arrive in recency order (front-most first). Under an intent, category priority
        // outranks recency, so e.g. "coding" keeps the editor in a proper tile even if chat is newer;
        // recency still breaks ties within a priority band.
        let ranked = windows.enumerated()
            .sorted { (intent.priority(categoryId: $0.element.categoryId), $0.offset)
                    < (intent.priority(categoryId: $1.element.categoryId), $1.offset) }
            .map(\.element)
        let primary = Array(ranked.prefix(min(ranked.count, capacity)))
        let overflow = Array(ranked.dropFirst(primary.count))

        var tiles = gridTiles(area: area, windows: primary, g: g, catalog: catalog, learned: learned, rules: rules)
        tiles.append(contentsOf: cascadeTiles(area: area, windows: overflow, g: g))
        return LayoutPlan(displaySignature: display.signature, tiles: tiles)
    }

    /// Lay windows out in a min-aware grid filling `area`, anchored top-left.
    private static func gridTiles(
        area: CGRect, windows: [ManagedWindow], g: CGFloat,
        catalog: CategoryCatalog, learned: LearnedDimensions, rules: AppRules = .empty
    ) -> [Tile] {
        guard !windows.isEmpty else { return [] }

        // Left-to-right ordering: hard pins first/last, then the user's learned side habit, then
        // widest-preference first for a stable layout. Columns are filled in this order, so a
        // pinned-left app lands in the leftmost column and a learned "right" habit drifts rightward.
        func prior(_ w: ManagedWindow) -> Double { catalog.widthPrior(id: w.categoryId, bundleId: w.bundleId, learned: learned) }
        func pinRank(_ w: ManagedWindow) -> Int {
            switch rules.rule(for: w.bundleId) {
            case .pinLeft: return 0
            case .pinRight: return 2
            default: return 1
            }
        }
        func xKey(_ w: ManagedWindow) -> Double {
            learned.dims(bundleId: w.bundleId, categoryId: w.categoryId)?.xFraction ?? 0.5
        }
        let ordered = windows.enumerated()
            .sorted { a, b in
                (pinRank(a.element), xKey(a.element), -prior(a.element), a.offset)
              < (pinRank(b.element), xKey(b.element), -prior(b.element), b.offset)
            }
            .map(\.element)

        func group(into cols: Int) -> [[ManagedWindow]] {
            let rpc = Int(ceil(Double(ordered.count) / Double(cols)))
            var out: [[ManagedWindow]] = []
            var i = 0
            while i < ordered.count { out.append(Array(ordered[i..<min(ordered.count, i + rpc)])); i += rpc }
            return out
        }
        func columnMin(_ ws: [ManagedWindow]) -> CGFloat {
            ws.map { catalog.profile(id: $0.categoryId).minWidth }.max() ?? 0
        }
        func columnMax(_ ws: [ManagedWindow]) -> CGFloat {
            ws.map { catalog.maxWidth(id: $0.categoryId, bundleId: $0.bundleId, usableWidth: area.width, learned: learned) }.min() ?? area.width
        }

        // Most columns whose minimum widths fit; fewer columns on a narrow display.
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

        // Start each column at its min, then distribute leftover width up to each column's max.
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

        var tiles: [Tile] = []
        var xCursor = area.minX + g
        for (c, ws) in columnWindows.enumerated() {
            let cw = colWidths[c]
            let rows = ws.count
            let rowHeight = (area.height - g * CGFloat(rows + 1)) / CGFloat(rows)
            for (r, window) in ws.enumerated() {
                let y = area.minY + g + CGFloat(r) * (rowHeight + g)
                let maxH = catalog.maxHeight(id: window.categoryId, bundleId: window.bundleId, usableHeight: area.height, learned: learned)
                let h = min(rowHeight, maxH)
                tiles.append(Tile(windowId: window.id, frame: CGRect(x: xCursor, y: y, width: cw, height: h)))
            }
            xCursor += cw + g
        }
        return tiles
    }

    /// Demote overflow windows to a small cascaded stack near the bottom-right, kept on-screen.
    private static func cascadeTiles(area: CGRect, windows: [ManagedWindow], g: CGFloat) -> [Tile] {
        guard !windows.isEmpty else { return [] }
        let w = Swift.min(comfortableCell.width, area.width - 2 * g)
        let h = Swift.min(comfortableCell.height, area.height - 2 * g)
        let step: CGFloat = 30
        return windows.enumerated().map { i, window in
            var x = area.maxX - g - w - CGFloat(i) * step
            var y = area.maxY - g - h - CGFloat(i) * step
            x = Swift.min(Swift.max(x, area.minX + g), area.maxX - g - w)
            y = Swift.min(Swift.max(y, area.minY + g), area.maxY - g - h)
            return Tile(windowId: window.id, frame: CGRect(x: x, y: y, width: w, height: h))
        }
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
