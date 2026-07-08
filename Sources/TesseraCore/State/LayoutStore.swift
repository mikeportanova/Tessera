import Foundation

/// Persists and restores window arrangements to JSON under
/// `~/Library/Application Support/Tessera/layouts.json`.
///
/// AX handles don't survive relaunch (or even app restarts of the target), so a `SavedLayout`
/// records each window by bundle id + a title hint and matches them back heuristically on restore.
public final class LayoutStore {

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `directory` is a testing seam: checks point it at a temp dir so they never touch the user's
    /// real saved layouts. The default (nil) preserves the production path.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("layouts.json")
    }

    // MARK: - Persistence

    public func allLayouts() -> [SavedLayout] {
        guard let data = try? Data(contentsOf: fileURL),
              let layouts = try? decoder.decode([SavedLayout].self, from: data)
        else { return [] }
        return layouts
    }

    /// Save (or overwrite by name) a layout built from the current windows.
    public func save(name: String, windows: [ManagedWindow], displaySignature: String) {
        let entries = windows.map { window in
            SavedLayout.Entry(
                bundleId: window.bundleId,
                appName: window.appName,
                titleHint: window.title,
                frame: window.frame
            )
        }
        let layout = SavedLayout(
            name: name,
            displaySignature: displaySignature,
            entries: entries,
            savedAt: Date()
        )
        var layouts = allLayouts().filter { $0.name != name }
        layouts.append(layout)
        write(layouts)
    }

    public func delete(name: String) {
        write(allLayouts().filter { $0.name != name })
    }

    public func layout(named name: String) -> SavedLayout? {
        allLayouts().first { $0.name == name }
    }

    // MARK: - Restore matching

    /// Match a saved layout's entries to currently-open windows and return concrete tiles.
    /// Each entry is matched to a window by bundle id, preferring the closest title; each open
    /// window is consumed at most once.
    public func resolveTiles(for layout: SavedLayout, windows: [ManagedWindow]) -> [Tile] {
        resolveTiles(for: layout, windows: windows, displays: [])
    }

    /// Display-aware variant: each restored frame is clamped into the visible frame of the display
    /// it overlaps most (falling back to the first display), so a layout saved on a different
    /// monitor arrangement can't restore a window off-screen. An empty `displays` skips clamping.
    public func resolveTiles(for layout: SavedLayout, windows: [ManagedWindow], displays: [DisplayInfo]) -> [Tile] {
        var available = windows
        var tiles: [Tile] = []

        for entry in layout.entries {
            guard let matchIndex = bestMatchIndex(for: entry, in: available) else { continue }
            let window = available.remove(at: matchIndex)
            tiles.append(Tile(windowId: window.id, frame: clamped(entry.frame, displays: displays)))
        }
        return tiles
    }

    /// Shrink a frame to fit its best-overlap display's visible frame, then pin the origin inside
    /// the bounds (same math as `TileParsing.clamp`). No displays → return the frame unchanged.
    private func clamped(_ frame: CGRect, displays: [DisplayInfo]) -> CGRect {
        guard !displays.isEmpty else { return frame }
        let display = displays.max {
            frame.intersectionArea($0.visibleFrame) < frame.intersectionArea($1.visibleFrame)
        } ?? displays[0]
        let bounds = display.visibleFrame
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = min(max(frame.origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func bestMatchIndex(for entry: SavedLayout.Entry, in windows: [ManagedWindow]) -> Int? {
        // First narrow to same bundle id (or same app name when bundle id is missing).
        let candidates = windows.enumerated().filter { _, w in
            if let b = entry.bundleId, let wb = w.bundleId { return b == wb }
            return w.appName == entry.appName
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer exact title, then a title prefix overlap, else the first candidate.
        if let exact = candidates.first(where: { $0.element.title == entry.titleHint }) {
            return exact.offset
        }
        return candidates.first?.offset
    }

    private func write(_ layouts: [SavedLayout]) {
        guard let data = try? encoder.encode(layouts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
