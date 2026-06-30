import Foundation
import Combine

/// Token usage from a single Claude API call.
public struct TokenUsage: Sendable, Codable, Equatable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public static let zero = TokenUsage(input: 0, output: 0)
    public var total: Int { input + output }
    public var isZero: Bool { input == 0 && output == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output)
    }
}

/// Per-million-token prices (USD). Ships with built-in defaults (Anthropic pricing, cached 2026-06)
/// and can be overridden at runtime by `PricingStore`, which refreshes from Anthropic weekly.
public enum ModelPricing {
    /// Runtime overrides keyed by model id. Written only on the main actor (by `PricingStore`);
    /// read wherever cost is computed (also main-actor in this app).
    nonisolated(unsafe) public static var overrides: [String: (input: Double, output: Double)] = [:]

    public static func defaults(for model: String) -> (input: Double, output: Double) {
        switch model {
        case "claude-opus-4-8":   return (5, 25)
        case "claude-sonnet-4-6": return (3, 15)
        case "claude-haiku-4-5":  return (1, 5)
        default:                  return (3, 15)   // assume Sonnet-tier if unknown
        }
    }

    public static func usdPerMillion(for model: String) -> (input: Double, output: Double) {
        overrides[model] ?? defaults(for: model)
    }

    /// Dollar cost of a usage amount on a given model.
    public static func cost(_ usage: TokenUsage, model: String) -> Double {
        let p = usdPerMillion(for: model)
        return Double(usage.input) / 1_000_000 * p.input + Double(usage.output) / 1_000_000 * p.output
    }
}

/// Records every AI call's token usage with a timestamp, persists a rolling window, and exposes
/// rolling summaries: total usage in the last 24 hours and the average cost per tiling pass.
@MainActor
public final class UsageTracker: ObservableObject {

    public enum Kind: String, Codable, Sendable { case tiling, category }

    public struct Event: Codable, Sendable {
        public let date: Date
        public let input: Int
        public let output: Int
        public let model: String
        public let kind: Kind
    }

    /// Published so the UI refreshes when a new call is recorded.
    @Published public private(set) var events: [Event] = []

    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 3600   // keep a week; summaries window to 24h

    public init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("usage.json")
        load()
    }

    public func record(_ usage: TokenUsage, model: String, kind: Kind) {
        guard !usage.isZero else { return }
        prune()
        events.append(Event(date: Date(), input: usage.input, output: usage.output, model: model, kind: kind))
        save()
    }

    public func reset() {
        events = []
        save()
    }

    // MARK: - Rolling summaries (trailing 24h)

    private var last24h: [Event] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return events.filter { $0.date >= cutoff }
    }

    public var usageLast24h: TokenUsage {
        last24h.reduce(.zero) { $0 + TokenUsage(input: $1.input, output: $1.output) }
    }

    public var costLast24h: Double {
        last24h.reduce(0) { $0 + ModelPricing.cost(TokenUsage(input: $1.input, output: $1.output), model: $1.model) }
    }

    /// Number of tiling passes recorded in the trailing 24h.
    public var tilingCountLast24h: Int {
        last24h.filter { $0.kind == .tiling }.count
    }

    /// Average tokens per tiling pass over the trailing 24h (falls back to all-time if none today).
    public var avgTokensPerTiling: Int {
        let pool = last24h.filter { $0.kind == .tiling }
        let sample = pool.isEmpty ? events.filter { $0.kind == .tiling } : pool
        guard !sample.isEmpty else { return 0 }
        let total = sample.reduce(0) { $0 + $1.input + $1.output }
        return total / sample.count
    }

    /// Average dollar cost per tiling pass over the trailing 24h (falls back to all-time if none today).
    public var avgCostPerTiling: Double {
        let pool = last24h.filter { $0.kind == .tiling }
        let sample = pool.isEmpty ? events.filter { $0.kind == .tiling } : pool
        guard !sample.isEmpty else { return 0 }
        let total = sample.reduce(0.0) { $0 + ModelPricing.cost(TokenUsage(input: $1.input, output: $1.output), model: $1.model) }
        return total / Double(sample.count)
    }

    // MARK: - Persistence

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        events.removeAll { $0.date < cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Event].self, from: data) else { return }
        events = decoded
        prune()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
