import Foundation
import Combine
import CoreGraphics

/// A learned width/height preference for an app or app category, as a fraction of the display's
/// usable area. `samples` lets us keep a running average that "gets added to" over time.
public struct LearnedDims: Codable, Sendable {
    public var widthFraction: Double
    public var heightFraction: Double
    public var samples: Int

    public init(widthFraction: Double, heightFraction: Double, samples: Int) {
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.samples = samples
    }

    /// Fold a new observation into the running average (cap the weight so old habits keep adapting).
    func adding(width: Double, height: Double) -> LearnedDims {
        let n = min(samples, 20)
        let w = (widthFraction * Double(n) + width) / Double(n + 1)
        let h = (heightFraction * Double(n) + height) / Double(n + 1)
        return LearnedDims(widthFraction: w, heightFraction: h, samples: samples + 1)
    }
}

/// An immutable, `Sendable` snapshot of everything we've learned, safe to hand to the (off-main)
/// planner. Per-app preferences win over per-category ones.
public struct LearnedDimensions: Sendable {
    public let byBundle: [String: LearnedDims]
    public let byCategory: [String: LearnedDims]   // AppCategory.rawValue -> dims

    public init(byBundle: [String: LearnedDims], byCategory: [String: LearnedDims]) {
        self.byBundle = byBundle
        self.byCategory = byCategory
    }

    public static let empty = LearnedDimensions(byBundle: [:], byCategory: [:])

    /// The best learned dims for a window, or nil if we've never seen anything relevant. Per-app
    /// learning wins over per-category. (Base defaults & ceilings live in `CategoryCatalog`, which
    /// folds these learned values in.)
    public func dims(bundleId: String?, categoryId: String) -> LearnedDims? {
        if let bundleId, let d = byBundle[bundleId] { return d }
        return byCategory[categoryId]
    }
}

/// Persisted, continually-updated memory of how the user likes their apps sized. Records a sample
/// every time a tile is manually resized, and feeds the accumulated priors back into future layouts.
@MainActor
public final class DimensionMemory: ObservableObject {

    private struct Store: Codable {
        var byBundle: [String: LearnedDims] = [:]
        var byCategory: [String: LearnedDims] = [:]
    }

    @Published public private(set) var sampleCount: Int = 0

    private var store = Store()
    private let fileURL: URL

    public init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("dimensions.json")
        load()
    }

    /// Record an observed sizing for an app. `widthFraction`/`heightFraction` are relative to the
    /// usable area (0...1). Updates both the per-app and per-category running averages.
    public func record(bundleId: String?, categoryId: String, widthFraction: Double, heightFraction: Double) {
        let w = widthFraction.clamped(to: 0.05...1.0)
        let h = heightFraction.clamped(to: 0.05...1.0)

        if let bundleId {
            store.byBundle[bundleId] = (store.byBundle[bundleId] ?? LearnedDims(widthFraction: w, heightFraction: h, samples: 0))
                .adding(width: w, height: h)
        }
        store.byCategory[categoryId] = (store.byCategory[categoryId] ?? LearnedDims(widthFraction: w, heightFraction: h, samples: 0))
            .adding(width: w, height: h)

        sampleCount = store.byBundle.values.reduce(0) { $0 + $1.samples }
        save()
    }

    public func snapshot() -> LearnedDimensions {
        LearnedDimensions(byBundle: store.byBundle, byCategory: store.byCategory)
    }

    public func reset() {
        store = Store()
        sampleCount = 0
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = decoded
        sampleCount = store.byBundle.values.reduce(0) { $0 + $1.samples }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
