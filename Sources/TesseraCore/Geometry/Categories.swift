import Foundation
import CoreGraphics

/// An editable, persistable description of how a kind of app should be sized and which apps belong
/// to it. Built-in categories ship with sensible defaults; users can edit those numbers and add
/// their own categories (see `CategoryStore`).
public struct CategoryProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String            // stable key; also stored on each window
    public var name: String          // display name
    public var preferredWidthFraction: Double
    public var minWidth: CGFloat
    public var maxWidth: CGFloat
    public var minHeight: CGFloat
    public var maxHeight: CGFloat
    public var bundleIds: [String]   // apps that map here (example apps for custom categories)
    public var keywords: [String]    // app-name keywords that map here
    public var isBuiltIn: Bool

    public init(
        id: String, name: String, preferredWidthFraction: Double,
        minWidth: CGFloat, maxWidth: CGFloat, minHeight: CGFloat, maxHeight: CGFloat,
        bundleIds: [String] = [], keywords: [String] = [], isBuiltIn: Bool = false
    ) {
        self.id = id; self.name = name; self.preferredWidthFraction = preferredWidthFraction
        self.minWidth = minWidth; self.maxWidth = maxWidth
        self.minHeight = minHeight; self.maxHeight = maxHeight
        self.bundleIds = bundleIds; self.keywords = keywords; self.isBuiltIn = isBuiltIn
    }
}

/// An immutable, `Sendable` snapshot of all categories, safe to hand to the (off-main) planner. It
/// classifies windows and computes effective sizing limits, folding in any learned per-app/per-
/// category preferences.
public struct CategoryCatalog: Sendable {
    public static let fallbackId = "other"

    public let profiles: [CategoryProfile]
    private let byId: [String: CategoryProfile]

    public init(profiles: [CategoryProfile]) {
        self.profiles = profiles
        self.byId = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func profile(id: String) -> CategoryProfile {
        byId[id] ?? byId[Self.fallbackId] ?? CategoryProfile(
            id: Self.fallbackId, name: "Other", preferredWidthFraction: 0.4,
            minWidth: 320, maxWidth: 1400, minHeight: 220, maxHeight: 1500, isBuiltIn: true
        )
    }

    public func displayName(id: String) -> String { profile(id: id).name }

    /// Classify a window to a category id: exact bundle-id match first, then a name-keyword match,
    /// else the fallback "other".
    public func categoryId(bundleId: String?, appName: String) -> String {
        if let bundleId, let p = profiles.first(where: { $0.bundleIds.contains(bundleId) }) {
            return p.id
        }
        let lower = appName.lowercased()
        if let p = profiles.first(where: { p in p.keywords.contains(where: { lower.contains($0) }) }) {
            return p.id
        }
        return Self.fallbackId
    }

    // MARK: - Effective sizing (base profile, raised by a learned preference)

    public func widthPrior(id: String, bundleId: String?, learned: LearnedDimensions) -> Double {
        learned.dims(bundleId: bundleId, categoryId: id)?.widthFraction ?? profile(id: id).preferredWidthFraction
    }

    public func maxWidth(id: String, bundleId: String?, usableWidth: CGFloat, learned: LearnedDimensions) -> CGFloat {
        let base = profile(id: id).maxWidth
        if let dims = learned.dims(bundleId: bundleId, categoryId: id) {
            return max(base, CGFloat(dims.widthFraction) * usableWidth * 1.05)
        }
        return min(base, usableWidth)
    }

    public func maxHeight(id: String, bundleId: String?, usableHeight: CGFloat, learned: LearnedDimensions) -> CGFloat {
        let base = profile(id: id).maxHeight
        if let dims = learned.dims(bundleId: bundleId, categoryId: id) {
            return max(base, CGFloat(dims.heightFraction) * usableHeight * 1.05)
        }
        return min(base, usableHeight)
    }
}
