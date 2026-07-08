import Foundation
import AppKit
import Combine

/// Update check + one-click self-update against GitHub Releases — no framework, no daemon.
///
/// Checking: weekly (and on demand), compares the latest release tag to the running version.
/// Updating: downloads the release's DMG, mounts it, swaps the running app bundle for the new one,
/// and relaunches. The new bundle is signed with the same Developer ID, so Accessibility/TCC grants
/// survive the swap. Fails gracefully (with a browser-download fallback) when anything goes wrong.
@MainActor
public final class UpdateChecker: ObservableObject {

    public enum UpdatePhase: Equatable {
        case idle
        case downloading
        case installing
        case relaunching
        case failed(String)
    }

    @Published public private(set) var availableVersion: String?
    @Published public private(set) var releaseURL: URL?
    /// Direct download URL of the release's `.dmg` asset, when it has one — enables Update Now.
    @Published public private(set) var dmgURL: URL?
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var isChecking = false
    @Published public private(set) var phase: UpdatePhase = .idle

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
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return }

        // Only a successful check is stamped, so a failed one (offline, rate-limited) doesn't
        // suppress retries for a whole week — checkIfStale will simply try again.
        lastChecked = Date()
        defaults.set(lastChecked, forKey: Self.lastCheckKey)

        let latest = Self.normalize(tag)
        if Self.isVersion(latest, newerThan: Self.currentVersion) {
            availableVersion = latest
            releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmgAsset = assets.first { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }
            dmgURL = (dmgAsset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        } else {
            availableVersion = nil
            releaseURL = nil
            dmgURL = nil
        }
    }

    // MARK: - Self-update

    /// Download the release DMG, swap the running app bundle for the new one, and relaunch.
    public func updateNow() async {
        guard phase != .downloading, phase != .installing, phase != .relaunching else { return }
        guard let dmgURL else {
            phase = .failed("This release has no downloadable app — use the release page instead.")
            return
        }
        phase = .downloading
        do {
            let (tempFile, response) = try await URLSession.shared.download(from: dmgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            // hdiutil wants the .dmg extension; the download lands with a random temp name.
            let dmgFile = tempFile.deletingLastPathComponent().appendingPathComponent("Tessera-update.dmg")
            try? FileManager.default.removeItem(at: dmgFile)
            try FileManager.default.moveItem(at: tempFile, to: dmgFile)

            phase = .installing
            let appURL = Bundle.main.bundleURL
            // The blocking hdiutil/ditto work runs off the main actor so the UI stays live.
            try await Task.detached(priority: .userInitiated) {
                try UpdateChecker.install(dmgAt: dmgFile, over: appURL)
            }.value

            phase = .relaunching
            Self.relaunch(appAt: appURL)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Mount the DMG, stage its .app, swap it into place over `appURL`, and unmount. Blocking —
    /// call off the main actor. Throws with a readable message on any step's failure.
    nonisolated static func install(dmgAt dmgFile: URL, over appURL: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("tessera-update-\(UUID().uuidString)")
        let mountPoint = workDir.appendingPathComponent("mount")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try run("/usr/bin/hdiutil", ["attach", dmgFile.path, "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mountPoint.path],
                failure: "Couldn't open the downloaded update")
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], failure: "") }

        guard let appName = try fm.contentsOfDirectory(atPath: mountPoint.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The update image doesn't contain an app")
        }
        let newApp = mountPoint.appendingPathComponent(appName)

        // Stage a copy outside the mount (ditto preserves the code signature), then swap:
        // rename the running bundle aside, copy the new one into its place, delete the old.
        // A same-directory rename keeps everything on one volume, so the swap is atomic-ish.
        let staged = workDir.appendingPathComponent("staged.app")
        try run("/usr/bin/ditto", [newApp.path, staged.path], failure: "Couldn't copy the new version")

        let parent = appURL.deletingLastPathComponent()
        let old = parent.appendingPathComponent(".tessera-old-\(UUID().uuidString).app")
        do {
            try fm.moveItem(at: appURL, to: old)
        } catch {
            throw UpdateError("Couldn't replace the app at \(parent.path) — try updating from the release page. (\(error.localizedDescription))")
        }
        do {
            try run("/usr/bin/ditto", [staged.path, appURL.path], failure: "Couldn't install the new version")
        } catch {
            try? fm.moveItem(at: old, to: appURL)   // roll back so the user still has a working app
            throw error
        }
        try? fm.removeItem(at: old)
        // Belt-and-suspenders: the app is notarized, but strip quarantine if a policy added it.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path], failure: "")
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String], failure: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        // Drain the pipe BEFORE waiting: a child that writes >64KB would fill the pipe buffer and
        // block, deadlocking waitUntilExit.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError(failure.isEmpty ? output : failure)
        }
        return output
    }

    /// Reopen the (replaced) app after this process exits.
    private static func relaunch(appAt appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Single-quote the path (escaping any embedded single quote as '\'') so a space or shell
        // metacharacter in the install path can't break — or inject into — the command.
        let quotedPath = "'" + appURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \(quotedPath)"]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Version comparison (pure, testable)

    /// Strip a leading "v" ("v0.2.0" → "0.2.0").
    public nonisolated static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric dotted-version comparison: "0.2.0" > "0.1.10" > "0.1.9". Anything after a "-"
    /// (pre-release/hotfix suffix, e.g. "0.2.0-beta.1") is ignored: only the numeric dotted parts
    /// are compared, and equal numerics are NOT newer — so a suffixed tag can never cause an
    /// update/downgrade loop against the same numeric version.
    public nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func numericParts(_ version: String) -> [Int] {
            let dotted = normalize(version).split(separator: "-").first ?? ""
            return dotted.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = numericParts(candidate)
        let b = numericParts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
