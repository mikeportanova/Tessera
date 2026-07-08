import Foundation
import Combine
import CoreGraphics

/// Owns the editable list of `CategoryProfile`s: seeds the built-ins, persists user edits and custom
/// categories, classifies windows, and can generate a brand-new category from example apps via the
/// LLM. The dimensions here (min/max width & height, preferred width) are what the user sees and
/// tweaks in Preferences.
@MainActor
public final class CategoryStore: ObservableObject {
    @Published public private(set) var profiles: [CategoryProfile]

    /// Set by the app so category generation can record its token usage. Optional to keep the store
    /// independently testable.
    public weak var usageTracker: UsageTracker?

    private let fileURL: URL

    /// Versioned on-disk shape. Legacy files were a bare `[CategoryProfile]` (treated as version 1).
    private struct Persisted: Codable {
        var seedVersion: Int
        var profiles: [CategoryProfile]
    }

    /// `directory` is a testing seam: checks point it at a temp dir so they never touch the user's
    /// real categories.json. The default (nil) preserves the production path.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tessera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("categories.json")

        let builtIns = CategoryStore.builtInProfiles()
        let data = try? Data(contentsOf: fileURL)

        if let data, let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.profiles = CategoryStore.reconcile(saved: p.profiles, savedVersion: p.seedVersion, builtIns: builtIns)
            if p.seedVersion < CategoryStore.builtInSeedVersion { save() }
        } else if let data, let legacy = try? JSONDecoder().decode([CategoryProfile].self, from: data) {
            // Legacy unversioned file → version 1: refresh built-ins to current defaults.
            self.profiles = CategoryStore.reconcile(saved: legacy, savedVersion: 1, builtIns: builtIns)
            save()
        } else {
            // A file that exists but won't decode is set aside, so the next save can't destroy it.
            if data != nil { quarantineCorruptFile(at: fileURL) }
            self.profiles = builtIns
        }
    }

    /// Merge a saved profile list with the current built-ins. Custom categories are always kept. If
    /// the saved file predates the current seed version, built-ins are refreshed to current defaults
    /// (so improved defaults like chat min-width propagate); otherwise the user's built-ins are kept
    /// and only newly-introduced built-ins are appended.
    nonisolated private static func reconcile(saved: [CategoryProfile], savedVersion: Int, builtIns: [CategoryProfile]) -> [CategoryProfile] {
        let customs = saved.filter { !$0.isBuiltIn }
        if savedVersion < builtInSeedVersion {
            return builtIns + customs
        }
        let savedIds = Set(saved.map(\.id))
        return saved + builtIns.filter { !savedIds.contains($0.id) }
    }

    public func snapshot() -> CategoryCatalog { CategoryCatalog(profiles: profiles) }

    public func categoryId(bundleId: String?, appName: String) -> String {
        snapshot().categoryId(bundleId: bundleId, appName: appName)
    }

    // MARK: - Editing

    public func update(_ profile: CategoryProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        scheduleSave()   // sliders/steppers fire rapidly — coalesce the disk writes
    }

    public func delete(id: String) {
        guard let p = profiles.first(where: { $0.id == id }), !p.isBuiltIn else { return }
        profiles.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Restore a built-in category to its shipped defaults (no effect on custom categories).
    public func resetToDefault(id: String) {
        guard let def = CategoryStore.builtInProfiles().first(where: { $0.id == id }),
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx] = def
        scheduleSave()
    }

    /// Generate a new custom category from a name + example apps, using the LLM to infer sensible
    /// sizing. Falls back to medium defaults if no API key / the call fails. The example apps become
    /// the category's matching keywords so those apps map to it immediately.
    /// `hasAPIKey` is a testing seam: checks pass `false` to force the offline heuristic path
    /// deterministically (never spending tokens); the default preserves production behavior.
    public func generateCategory(name: String, exampleApps: [String], hasAPIKey: Bool = Keychain.hasAPIKey) async -> CategoryProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let id = uniqueId(for: trimmedName)
        let keywords = exampleApps
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The network call lives in a nonisolated free function so the (non-Sendable) tool schema
        // never crosses the actor boundary. Only Sendable values are passed in.
        let (profile, usage) = await generateCategoryProfile(
            id: id, name: trimmedName.isEmpty ? id : trimmedName,
            exampleApps: exampleApps, baseKeywords: keywords, hasAPIKey: hasAPIKey
        )
        usageTracker?.record(usage, model: PlannerModel.sonnet.rawValue, kind: .category)
        return profile
    }

    // MARK: - Persistence

    private var saveTask: Task<Void, Never>?

    /// Write any pending debounced changes immediately (call on app termination).
    public func flush() { saveTask?.cancel(); save() }

    /// Coalesce rapid edits (slider/stepper drags) into a single write ~0.4s after they settle.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(seedVersion: CategoryStore.builtInSeedVersion, profiles: profiles)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func uniqueId(for name: String) -> String {
        let slugBase = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let slug = slugBase.isEmpty ? "category" : slugBase
        var candidate = slug
        var n = 2
        let existing = Set(profiles.map(\.id))
        while existing.contains(candidate) { candidate = "\(slug)-\(n)"; n += 1 }
        return candidate
    }

    // MARK: - Built-in seed

    nonisolated public static func builtInProfiles() -> [CategoryProfile] {
        AppCategory.allCases.map { c in
            let (minW, minH) = seedMins(c)
            return CategoryProfile(
                id: c.rawValue, name: seedName(c),
                preferredWidthFraction: c.preferredWidthFraction,
                minWidth: minW, maxWidth: c.maxReasonableWidth,
                minHeight: minH, maxHeight: c.maxReasonableHeight,
                bundleIds: seedBundleIds(c), keywords: seedKeywords(c), isBuiltIn: true
            )
        }
    }

    nonisolated private static func seedName(_ c: AppCategory) -> String {
        switch c {
        case .reference: return "Reference / PDF"
        default: return c.rawValue.prefix(1).uppercased() + c.rawValue.dropFirst()
        }
    }

    nonisolated private static func seedMins(_ c: AppCategory) -> (CGFloat, CGFloat) {
        switch c {
        // Chat apps (Messages, Slack) have a sidebar/conversation rail plus the message thread, so
        // they need real width or content gets clipped — don't let them go narrow.
        case .chat: return (640, 480)
        case .music: return (300, 420)
        default: return (340, 240)
        }
    }

    /// Bumped whenever the built-in seed values change, so updates reach installed copies. On load,
    /// a persisted file with an older version has its **built-in** profiles refreshed to these
    /// defaults (custom categories are always preserved).
    nonisolated static let builtInSeedVersion = 2

    nonisolated private static func seedBundleIds(_ c: AppCategory) -> [String] {
        switch c {
        case .browser: return ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser"]
        case .editor: return ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.sublimetext.4", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92"]
        case .terminal: return ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
        case .chat: return ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.apple.MobileSMS"]
        case .email: return ["com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook"]
        case .notes: return ["com.apple.Notes", "notion.id", "md.obsidian"]
        case .music: return ["com.apple.Music", "com.spotify.client"]
        case .design: return ["com.figma.Desktop", "com.bohemiancoding.sketch3"]
        case .reference: return ["com.apple.Preview", "com.adobe.Reader"]
        case .other: return []
        }
    }

    nonisolated private static func seedKeywords(_ c: AppCategory) -> [String] {
        switch c {
        case .browser: return ["browser", "chrome", "safari", "firefox", "edge", "arc"]
        case .editor: return ["code", "xcode", "studio", "editor"]
        case .terminal: return ["terminal", "iterm", "warp", "ghostty"]
        case .chat: return ["slack", "discord", "telegram", "messages"]
        case .email: return ["mail", "outlook"]
        case .notes: return ["notes", "notion", "obsidian"]
        case .music: return ["music", "spotify"]
        case .design: return ["figma", "sketch"]
        case .reference: return ["preview", "acrobat", "reader"]
        case .other: return []
        }
    }

}

/// Move a persisted file that exists but no longer decodes aside as `<name>.corrupt` (best-effort,
/// replacing any previous quarantine) before falling back to defaults — the next save would
/// otherwise overwrite it, and the original stays recoverable for the user.
func quarantineCorruptFile(at url: URL) {
    let backup = url.appendingPathExtension("corrupt")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
}

/// Nonisolated LLM call to infer sizing for a new category. Builds its tool schema locally so no
/// non-Sendable value crosses an actor boundary, and returns a heuristic default when offline.
private func generateCategoryProfile(
    id: String, name: String, exampleApps: [String], baseKeywords: [String], hasAPIKey: Bool
) async -> (CategoryProfile, TokenUsage) {
    var profile = CategoryProfile(
        id: id, name: name, preferredWidthFraction: 0.4,
        minWidth: 340, maxWidth: 1300, minHeight: 240, maxHeight: 1400,
        bundleIds: [], keywords: baseKeywords, isBuiltIn: false
    )
    guard hasAPIKey, !exampleApps.isEmpty else { return (profile, .zero) }

    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "preferredWidthFraction": ["type": "number", "description": "0.1–0.7 of usable width"],
            "minWidth": ["type": "number"], "maxWidth": ["type": "number"],
            "minHeight": ["type": "number"], "maxHeight": ["type": "number"],
            "keywords": ["type": "array", "items": ["type": "string"], "description": "lowercased app-name substrings"],
            "bundleIds": ["type": "array", "items": ["type": "string"], "description": "macOS bundle ids if known"],
        ],
        "required": ["preferredWidthFraction", "minWidth", "maxWidth", "minHeight", "maxHeight"],
        "additionalProperties": false,
    ]

    do {
        let result = try await ClaudeClient().requestLayout(
            model: PlannerModel.sonnet.rawValue,
            system: """
            You define window-sizing profiles for a macOS tiler. Given a category name and example \
            apps, infer comfortable sizing in points for a large display. Consider what the apps \
            show: dense/wide content (IDEs, design, browsers) wants a large maxWidth; chat/music/\
            utility apps want narrow widths; reference/reading apps are medium. Heights should be \
            capped so the app never needs the whole height of a very tall monitor. Reply ONLY via \
            the emit_category tool.
            """,
            userText: "Category name: \"\(name)\". Example apps: \(exampleApps.joined(separator: ", ")).",
            toolName: "emit_category",
            toolSchema: schema
        )
        let input = result.toolInput
        // Clamp every model-supplied dimension to a sane positive range, and keep min ≤ max, so a
        // hallucinated value (0, negative, or absurd) can't produce an unusable category.
        func sane(_ v: Double) -> CGFloat { CGFloat(min(5000, max(100, v))) }
        if let f = (input["preferredWidthFraction"] as? NSNumber)?.doubleValue { profile.preferredWidthFraction = min(0.7, max(0.1, f)) }
        if let v = (input["minWidth"] as? NSNumber)?.doubleValue { profile.minWidth = sane(v) }
        if let v = (input["maxWidth"] as? NSNumber)?.doubleValue { profile.maxWidth = sane(v) }
        if let v = (input["minHeight"] as? NSNumber)?.doubleValue { profile.minHeight = sane(v) }
        if let v = (input["maxHeight"] as? NSNumber)?.doubleValue { profile.maxHeight = sane(v) }
        if profile.minWidth > profile.maxWidth { profile.minWidth = profile.maxWidth }
        if profile.minHeight > profile.maxHeight { profile.minHeight = profile.maxHeight }
        if let kws = input["keywords"] as? [String] { profile.keywords = Array(Set(baseKeywords + kws.map { $0.lowercased() })) }
        if let bids = input["bundleIds"] as? [String] { profile.bundleIds = bids }
        return (profile, result.usage)
    } catch {
        NSLog("[Tessera] category generation failed, using defaults: \(error.localizedDescription)")
        return (profile, .zero)
    }
}
