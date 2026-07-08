import Foundation
import Combine

/// Caps how often Tessera calls the LLM so a flurry of window events (or an over-eager auto-arrange)
/// can't run up cost or hit API limits. This is the *hard* hourly cap that sits on top of the
/// ~400ms event debounce in `AutoArrangeCoordinator`.
///
/// When the cap is reached, callers should surface an approval affordance; `grantOverride` raises
/// the ceiling for the remainder of the current hour only.
@MainActor
public final class RateLimiter: ObservableObject {

    /// Base calls allowed per trailing 60 minutes.
    @Published public var maxPerHour: Int

    /// Extra calls the user has explicitly approved this hour (decays as old calls age out).
    @Published public private(set) var grantedExtra: Int = 0

    /// Published for UI: how many AI calls happened in the trailing hour.
    @Published public private(set) var callsInLastHour: Int = 0

    private var timestamps: [Date] = []
    private var grantExpiry: Date?

    /// Injectable clock — a testing seam so checks can drive the hour window deterministically.
    /// The default preserves real behavior; production code never overrides it.
    public var now: () -> Date = { Date() }

    public init(maxPerHour: Int = 20) {
        self.maxPerHour = maxPerHour
    }

    /// True if another AI call is allowed right now without approval.
    public func canCall() -> Bool {
        currentCount() < maxPerHour + grantedExtra
    }

    /// Record that an AI call just happened.
    public func recordCall() {
        timestamps.append(now())
        refreshCount()
    }

    /// User approved exceeding the cap; allow `extra` more calls this hour.
    public func grantOverride(extra: Int = 5) {
        grantedExtra += extra
        grantExpiry = now().addingTimeInterval(3600)
    }

    /// Prune timestamps older than an hour and return the live count.
    @discardableResult
    private func currentCount() -> Int {
        let cutoff = now().addingTimeInterval(-3600)
        timestamps.removeAll { $0 < cutoff }
        // Grants last for the hour they were approved in (or lapse early once the burst fully
        // ages out) — steady usage must not keep a one-time approval alive forever.
        if grantedExtra > 0, timestamps.isEmpty || (grantExpiry.map { $0 <= now() } ?? true) {
            grantedExtra = 0
            grantExpiry = nil
        }
        // Keep the published count honest even on read paths (menu gauge, approval banner).
        if callsInLastHour != timestamps.count { callsInLastHour = timestamps.count }
        return timestamps.count
    }

    private func refreshCount() {
        callsInLastHour = currentCount()
    }
}
