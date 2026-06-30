import Foundation
import Combine

/// Which Claude model to use for planning.
public enum PlannerModel: String, Codable, CaseIterable, Sendable {
    case sonnet = "claude-sonnet-4-6"
    case opus = "claude-opus-4-8"

    public var displayName: String {
        switch self {
        case .sonnet: return "Sonnet (fast, default)"
        case .opus: return "Opus (best quality)"
        }
    }
}

/// User preferences, backed by `UserDefaults`. The API key itself lives in the Keychain, not here.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published public var model: PlannerModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }

    /// Auto-rearrange when new windows/apps appear.
    @Published public var autoArrange: Bool {
        didSet { defaults.set(autoArrange, forKey: Keys.autoArrange) }
    }

    /// Attach a screenshot so the model can arrange by on-screen content (needs Screen Recording).
    @Published public var contentAware: Bool {
        didSet { defaults.set(contentAware, forKey: Keys.contentAware) }
    }

    /// Gap, in points, between tiles and around the screen edge.
    @Published public var gap: Double {
        didSet { defaults.set(gap, forKey: Keys.gap) }
    }

    /// Hard cap on AI layout calls per hour; exceeding requires explicit user approval.
    @Published public var maxAICallsPerHour: Int {
        didSet { defaults.set(maxAICallsPerHour, forKey: Keys.maxAICallsPerHour) }
    }

    /// Direct-manipulation gestures: drag a window onto another tile to swap, and reflow neighbors
    /// when a tile is resized. No AI involved.
    @Published public var snapEnabled: Bool {
        didSet { defaults.set(snapEnabled, forKey: Keys.snapEnabled) }
    }

    /// Global hotkey that triggers a tiling pass ("Tile Now") from anywhere.
    @Published public var tileShortcut: TileShortcut {
        didSet { defaults.set(tileShortcut.rawValue, forKey: Keys.tileShortcut) }
    }

    /// Whether an API key is present (mirrors Keychain; published for UI binding).
    @Published public var hasAPIKey: Bool

    public init() {
        self.model = PlannerModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .sonnet
        // Default OFF: never move the user's windows unprompted on first run. They opt in.
        self.autoArrange = defaults.object(forKey: Keys.autoArrange) as? Bool ?? false
        self.contentAware = defaults.object(forKey: Keys.contentAware) as? Bool ?? false
        self.gap = defaults.object(forKey: Keys.gap) as? Double ?? 8
        self.maxAICallsPerHour = defaults.object(forKey: Keys.maxAICallsPerHour) as? Int ?? 20
        self.snapEnabled = defaults.object(forKey: Keys.snapEnabled) as? Bool ?? true
        self.tileShortcut = TileShortcut(rawValue: defaults.string(forKey: Keys.tileShortcut) ?? "") ?? .ctrlOptCmdT
        self.hasAPIKey = Keychain.hasAPIKey
    }

    public func updateAPIKey(_ key: String) {
        Keychain.setAPIKey(key)
        hasAPIKey = Keychain.hasAPIKey
    }

    private enum Keys {
        static let model = "model"
        static let autoArrange = "autoArrange"
        static let contentAware = "contentAware"
        static let gap = "gap"
        static let maxAICallsPerHour = "maxAICallsPerHour"
        static let snapEnabled = "snapEnabled"
        static let tileShortcut = "tileShortcut"
    }
}
