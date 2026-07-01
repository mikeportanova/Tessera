import Foundation
import Combine

/// Lightweight update check against GitHub Releases — no framework, no daemon. Checks weekly (and on
/// demand) whether the repo has a release tagged newer than the running version, and surfaces a link.
/// Fails silently when offline or when the repo has no public releases.
@MainActor
public final class UpdateChecker: ObservableObject {

    @Published public private(set) var availableVersion: String?
    @Published public private(set) var releaseURL: URL?
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var isChecking = false

    private let repo: String
    private let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"

    public init(repo: String = "mikeportanova/Tessera") {
        self.repo = repo
        self.lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Check at most once a week.
    public func checkIfStale() {
        let week: TimeInterval = 7 * 24 * 3600
        if let last = lastChecked, Date().timeIntervalSince(last) < week { return }
        Task { await checkNow() }
    }

    public func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return }

        let latest = Self.normalize(tag)
        if Self.isVersion(latest, newerThan: Self.currentVersion) {
            availableVersion = latest
            releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        } else {
            availableVersion = nil
            releaseURL = nil
        }
    }

    // MARK: - Version comparison (pure, testable)

    /// Strip a leading "v" ("v0.2.0" → "0.2.0").
    public nonisolated static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric dotted-version comparison: "0.2.0" > "0.1.10" > "0.1.9".
    public nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = normalize(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
