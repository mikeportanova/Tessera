import Foundation
import Combine

/// A per-app tiling rule the user sets in Preferences → Apps.
public enum AppRule: String, Codable, CaseIterable, Sendable {
    /// Default: the app participates in tiling normally.
    case tile
    /// Never tile this app — its windows float above/outside every layout.
    case float
    /// Always place this app in the leftmost column.
    case pinLeft
    /// Always place this app in the rightmost column.
    case pinRight

    public var displayName: String {
        switch self {
        case .tile:     return "Tile"
        case .float:    return "Float (never tile)"
        case .pinLeft:  return "Pin left"
        case .pinRight: return "Pin right"
        }
    }
}

/// Immutable, `Sendable` snapshot of the user's per-app rules, safe to hand to planners.
public struct AppRules: Sendable {
    public let byBundleId: [String: AppRule]

    public static let empty = AppRules(byBundleId: [:])

    public init(byBundleId: [String: AppRule]) {
        self.byBundleId = byBundleId
    }

    public func rule(for bundleId: String?) -> AppRule {
        guard let bundleId else { return .tile }
        return byBundleId[bundleId] ?? .tile
    }
}

/// Persisted store of per-app rules (`~/Library/Application Support/Tessera/app-rules.json`).
@MainActor
public final class AppRulesStore: ObservableObject {
    @Published public private(set) var byBundleId: [String: AppRule] = [:]

    private let fileURL: URL

    public init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("app-rules.json")
        load()
    }

    public func rule(for bundleId: String?) -> AppRule {
        guard let bundleId else { return .tile }
        return byBundleId[bundleId] ?? .tile
    }

    public func set(_ rule: AppRule, for bundleId: String) {
        if rule == .tile { byBundleId.removeValue(forKey: bundleId) }   // .tile is the default — no entry needed
        else { byBundleId[bundleId] = rule }
        save()
    }

    public func snapshot() -> AppRules {
        AppRules(byBundleId: byBundleId)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: AppRule].self, from: data) else {
            quarantineCorruptFile(at: fileURL)   // keep the unreadable file; the next save would overwrite it
            return
        }
        byBundleId = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byBundleId) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
