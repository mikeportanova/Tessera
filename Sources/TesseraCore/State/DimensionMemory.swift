import Foundation
import Combine
import CoreGraphics

/// A learned width/height preference for an app or app category, as a fraction of the display's
/// usable area. `samples` lets us keep a running average that "gets added to" over time.
public struct LearnedDims: Codable, Sendable {
    public var widthFraction: Double
    public var heightFraction: Double
    /// Learned horizontal *position*: the window center's x as a fraction of usable width (0 = far
    /// left, 1 = far right). Recorded when the user swaps, snaps, or resizes — so "terminal goes on
    /// the right" sticks. Optional so files saved before this field existed still decode.
    public var xFraction: Double?
    public var samples: Int

    public init(widthFraction: Double, heightFraction: Double, xFraction: Double? = nil, samples: Int) {
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.xFraction = xFraction
        self.samples = samples
    }

    /// Fold a new observation into the running average (cap the weight so old habits keep adapting).
    func adding(width: Double, height: Double, x: Double?) -> LearnedDims {
        let n = min(samples, 20)
        let w = (widthFraction * Double(n) + width) / Double(n + 1)
        let h = (heightFraction * Double(n) + height) / Double(n + 1)
        var newX = xFraction
        if let x { newX = ((xFraction ?? x) * Double(n) + x) / Double(n + 1) }
        return LearnedDims(widthFraction: w, heightFraction: h, xFraction: newX, samples: samples + 1)
    }

    /// A coarse side preference derived from the learned position, or nil when it's central/unknown.
    public var sidePreference: String? {
        guard let x = xFraction, samples >= 2 else { return nil }
        if x < 0.35 { return "left" }
        if x > 0.65 { return "right" }
        return nil
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

    /// Record an observed sizing (and optionally horizontal position) for an app.
    /// `widthFraction`/`heightFraction`/`xFraction` are relative to the usable area (0...1).
    /// Updates both the per-app and per-category running averages.
    public func record(bundleId: String?, categoryId: String, widthFraction: Double, heightFraction: Double, xFraction: Double? = nil) {
        let w = widthFraction.clamped(to: 0.05...1.0)
        let h = heightFraction.clamped(to: 0.05...1.0)
        let x = xFraction.map { $0.clamped(to: 0.0...1.0) }

        if let bundleId {
            store.byBundle[bundleId] = (store.byBundle[bundleId] ?? LearnedDims(widthFraction: w, heightFraction: h, samples: 0))
                .adding(width: w, height: h, x: x)
        }
        store.byCategory[categoryId] = (store.byCategory[categoryId] ?? LearnedDims(widthFraction: w, heightFraction: h, samples: 0))
            .adding(width: w, height: h, x: x)

        sampleCount = store.byBundle.values.reduce(0) { $0 + $1.samples }
        scheduleSave()   // a resize-drag records repeatedly — coalesce the writes
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

    private var saveTask: Task<Void, Never>?

    /// Write any pending debounced changes immediately (call on app termination).
    public func flush() { saveTask?.cancel(); save() }

    /// Coalesce rapid records (a single resize drag fires several) into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
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
