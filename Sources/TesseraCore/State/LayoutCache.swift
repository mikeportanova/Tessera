import Foundation
import CoreGraphics
import Combine

/// Remembers the last AI-produced layout for each *window set* so re-tiling the same working set is
/// instant and free: same apps on the same displays → re-apply the cached frames with zero tokens and
/// zero latency; only a genuinely new situation goes to the LLM. Manual corrections (swaps, resizes,
/// snaps) update the cached entry, so the cache converges on how the user actually likes that set.
public struct CachedLayout: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// Bundle id, or the app name when the bundle id is unknown — matched against live windows.
        public var appKey: String
        /// Target frame in global CG (top-left) coordinates.
        public var frame: CGRect

        public init(appKey: String, frame: CGRect) {
            self.appKey = appKey
            self.frame = frame
        }
    }

    public var entries: [Entry]
    public var savedAt: Date

    public init(entries: [Entry], savedAt: Date) {
        self.entries = entries
        self.savedAt = savedAt
    }
}

@MainActor
public final class LayoutCache: ObservableObject {

    /// Keep the most recent N window-set layouts; beyond that, evict least-recently used.
    static let capacity = 24

    private var layouts: [String: CachedLayout] = [:]
    private var lruOrder: [String] = []   // most recent last
    private let fileURL: URL

    public init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("layout-cache.json")
        load()
    }

    // MARK: - Signature

    /// The matching key a window belongs under: bundle id, or app name when the id is unknown.
    public nonisolated static func appKey(bundleId: String?, appName: String) -> String {
        bundleId ?? appName
    }

    /// A stable key for "this exact set of windows on these displays": per-app window counts
    /// (order-independent) plus the display arrangement signature. Any change — an app opened or
    /// closed, a second window of an app, a monitor plugged in — produces a different signature.
    public nonisolated static func signature(appKeys: [String], displaySignatures: [String]) -> String {
        var counts: [String: Int] = [:]
        for key in appKeys { counts[key, default: 0] += 1 }
        let apps = counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ",")
        let displays = displaySignatures.sorted().joined(separator: "+")
        return displays + "|" + apps
    }

    public nonisolated static func signature(windows: [ManagedWindow], displays: [DisplayInfo]) -> String {
        signature(appKeys: windows.map { appKey(bundleId: $0.bundleId, appName: $0.appName) },
                  displaySignatures: displays.map(\.signature))
    }

    // MARK: - Lookup / store

    public func layout(for signature: String) -> CachedLayout? {
        guard let cached = layouts[signature] else { return nil }
        touch(signature)
        return cached
    }

    public func store(signature: String, entries: [CachedLayout.Entry]) {
        layouts[signature] = CachedLayout(entries: entries, savedAt: Date())
        touch(signature)
        evictIfNeeded()
        save()
    }

    /// Update an entry only if it already exists — manual gestures refine a cached AI layout, but a
    /// hand-arranged window set that was never AI-tiled shouldn't silently become "the layout".
    public func updateIfPresent(signature: String, entries: [CachedLayout.Entry]) {
        guard layouts[signature] != nil else { return }
        store(signature: signature, entries: entries)
    }

    public func clear() {
        layouts = [:]
        lruOrder = []
        save()
    }

    public var count: Int { layouts.count }

    // MARK: - Resolution

    /// Match a cached layout back to live windows. Every entry must find a window and every window
    /// must be consumed — anything else means the set drifted and the caller should re-plan.
    public nonisolated static func resolve(_ cached: CachedLayout, windows: [ManagedWindow]) -> [(window: ManagedWindow, frame: CGRect)]? {
        var available = windows
        var out: [(ManagedWindow, CGRect)] = []
        for entry in cached.entries {
            guard let idx = available.firstIndex(where: {
                appKey(bundleId: $0.bundleId, appName: $0.appName) == entry.appKey
            }) else { return nil }
            out.append((available.remove(at: idx), entry.frame))
        }
        guard available.isEmpty else { return nil }
        return out
    }

    // MARK: - Private

    private func touch(_ signature: String) {
        lruOrder.removeAll { $0 == signature }
        lruOrder.append(signature)
    }

    private func evictIfNeeded() {
        while lruOrder.count > Self.capacity {
            let evicted = lruOrder.removeFirst()
            layouts.removeValue(forKey: evicted)
        }
    }

    private struct Persisted: Codable {
        var layouts: [String: CachedLayout]
        var lruOrder: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        layouts = decoded.layouts
        lruOrder = decoded.lruOrder
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(layouts: layouts, lruOrder: lruOrder)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
