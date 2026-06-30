import Foundation
import Combine

/// Keeps per-model token prices fresh by fetching Anthropic's public models/pricing page about once
/// a week, parsing the per-million-token figures, and feeding them into `ModelPricing.overrides`.
/// Falls back to the built-in defaults if a fetch or parse fails, so cost figures are always sane.
@MainActor
public final class PricingStore: ObservableObject {

    public struct Price: Codable, Sendable, Equatable {
        public var input: Double
        public var output: Double
    }

    private struct Persisted: Codable {
        var prices: [String: Price]
        var lastFetched: Date?
    }

    @Published public private(set) var prices: [String: Price] = [:]
    @Published public private(set) var lastFetched: Date?
    @Published public private(set) var isRefreshing = false

    /// Models we display/refresh pricing for.
    public static let trackedModels = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]

    private let fileURL: URL
    private let refreshInterval: TimeInterval = 7 * 24 * 3600

    public init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("pricing.json")
        load()
        applyToModelPricing()
    }

    /// Price actually in effect for a model (fetched if present, else built-in default).
    public func effectivePrice(for model: String) -> Price {
        if let p = prices[model] { return p }
        let d = ModelPricing.defaults(for: model)
        return Price(input: d.input, output: d.output)
    }

    /// Refresh if we've never fetched or the last fetch is older than a week.
    public func refreshIfStale() {
        if let last = lastFetched, Date().timeIntervalSince(last) < refreshInterval { return }
        Task { await refresh() }
    }

    /// Force a fetch now (used by the "Update now" button).
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetched = await fetchPricing(models: Self.trackedModels)
        guard !fetched.isEmpty else {
            // Even a failed fetch updates the timestamp so we don't hammer the endpoint.
            lastFetched = Date(); save(); return
        }
        for (model, price) in fetched { prices[model] = price }
        lastFetched = Date()
        applyToModelPricing()
        save()
    }

    // MARK: - Persistence

    private func applyToModelPricing() {
        var o: [String: (input: Double, output: Double)] = [:]
        for (model, p) in prices { o[model] = (p.input, p.output) }
        ModelPricing.overrides = o
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        prices = decoded.prices
        lastFetched = decoded.lastFetched
    }

    private func save() {
        let p = Persisted(prices: prices, lastFetched: lastFetched)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Nonisolated network + parse. Fetches Anthropic's public models overview (Markdown) and extracts
/// the input/output $/MTok for each requested model id from its table row. Best-effort: returns only
/// the models it could confidently parse.
private func fetchPricing(models: [String]) async -> [String: PricingStore.Price] {
    let url = URL(string: "https://platform.claude.com/docs/en/about-claude/models/overview.md")!
    guard let (data, response) = try? await URLSession.shared.data(from: url),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let text = String(data: data, encoding: .utf8) else { return [:] }

    var result: [String: PricingStore.Price] = [:]
    // Each model has a table row containing its id and two dollar figures: input then output.
    // We scan each line that mentions the id and pull the first two $-amounts in order.
    for line in text.split(whereSeparator: \.isNewline) {
        guard let model = models.first(where: { line.contains($0) }) else { continue }
        let amounts = dollarAmounts(in: String(line))
        if amounts.count >= 2, amounts[0] > 0, amounts[1] > 0 {
            result[model] = PricingStore.Price(input: amounts[0], output: amounts[1])
        }
    }
    return result
}

/// Extract dollar amounts like `$5.00` / `$25` from a string, in order.
private func dollarAmounts(in s: String) -> [Double] {
    var out: [Double] = []
    var idx = s.startIndex
    while let dollar = s[idx...].firstIndex(of: "$") {
        var j = s.index(after: dollar)
        var num = ""
        while j < s.endIndex, s[j].isNumber || s[j] == "." || s[j] == "," {
            if s[j] != "," { num.append(s[j]) }
            j = s.index(after: j)
        }
        if let v = Double(num) { out.append(v) }
        idx = j
        if idx >= s.endIndex { break }
    }
    return out
}
