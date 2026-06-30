import Foundation
import AppKit
import ApplicationServices
import Combine

/// Orchestrates tiling: snapshot windows → group by display → plan each display → apply, and
/// maintains the live grid that the direct-manipulation gestures (swap, resize-reflow) operate on.
/// Also enforces the per-hour AI cap and feeds manual resizes back into `DimensionMemory`.
@MainActor
public final class TilingEngine: ObservableObject {

    public enum Status: Equatable {
        case idle
        case planning
        case applied(movedWindows: Int)
        case failed(String)
        /// AI hourly cap reached; user must approve to continue.
        case needsApproval(used: Int, max: Int)
    }

    @Published public private(set) var status: Status = .idle

    private let enumerator = WindowEnumerator()
    private let planner = LayoutPlanner()
    private let applier = WindowApplier()
    private let store = LayoutStore()
    private let settings: AppSettings
    public let rateLimiter: RateLimiter
    public let dimensionMemory: DimensionMemory
    public let categoryStore: CategoryStore
    public let usageTracker: UsageTracker

    /// The frames Tessera last assigned, with live AX handles — survives re-enumeration.
    private var grid: [GridTile] = []

    /// Guard against overlapping planning passes.
    private var isPlanning = false
    /// Ignore geometry notifications until this instant — set after we apply frames ourselves, so
    /// our own moves don't masquerade as user resizes.
    private var suppressGeometryUntil = Date.distantPast

    public init(settings: AppSettings, rateLimiter: RateLimiter, dimensionMemory: DimensionMemory, categoryStore: CategoryStore, usageTracker: UsageTracker) {
        self.settings = settings
        self.rateLimiter = rateLimiter
        self.dimensionMemory = dimensionMemory
        self.categoryStore = categoryStore
        self.usageTracker = usageTracker
    }

    // MARK: - Tile now / re-tile

    /// - Parameter useAI: when false (e.g. an automatic re-tile on a new window), the offline tiler
    ///   is used and the LLM is never called — keeps frequent auto-arranges fast and free. Manual
    ///   "Tile Now" / the hotkey pass true.
    public func retile(useAI: Bool = true) async {
        guard !isPlanning else { return }
        isPlanning = true
        status = .planning
        defer { isPlanning = false }

        let catalog = categoryStore.snapshot()
        let windows = enumerator.managedWindows(catalog: catalog)
        guard !windows.isEmpty else { status = .applied(movedWindows: 0); grid = []; return }

        let usingAI = useAI && Keychain.hasAPIKey
        rateLimiter.maxPerHour = settings.maxAICallsPerHour
        let learned = dimensionMemory.snapshot()
        let displays = DisplayProvider.displays()

        var newGrid: [GridTile] = []
        var totalMoved = 0
        var passUsage = TokenUsage.zero
        var aiError: String?

        // Assign each window to the display its frame most overlaps — in one pass over the
        // already-fetched `displays`, rather than re-enumerating screens per window.
        var windowsByDisplay: [CGDirectDisplayID: [ManagedWindow]] = [:]
        for window in windows {
            let best = displays.max {
                window.frame.intersectionArea($0.visibleFrame) < window.frame.intersectionArea($1.visibleFrame)
            } ?? displays.first
            if let id = best?.id { windowsByDisplay[id, default: []].append(window) }
        }

        for display in displays {
            let group = windowsByDisplay[display.id] ?? []
            guard !group.isEmpty else { continue }

            let outcome: LayoutPlanner.Outcome
            if usingAI {
                // Enforce the hourly AI cap before each network-backed plan.
                if !rateLimiter.canCall() {
                    status = .needsApproval(used: rateLimiter.callsInLastHour, max: rateLimiter.maxPerHour)
                    return
                }
                let image = await screenshotIfEnabled(for: display)
                outcome = await planner.plan(
                    display: display, windows: group, gap: settings.gap, model: settings.model,
                    image: image, catalog: catalog, learned: learned
                )
                rateLimiter.recordCall()
            } else {
                // Offline: deterministic tiler, no network, no token spend.
                let plan = FallbackTiler.plan(display: display, windows: group, gap: settings.gap, catalog: catalog, learned: learned)
                outcome = LayoutPlanner.Outcome(plan: plan, usage: .zero, usedAI: false, error: nil)
            }
            passUsage = passUsage + outcome.usage
            if let e = outcome.error, aiError == nil { aiError = e }

            applyAndSuppress { totalMoved += applier.apply(plan: outcome.plan, to: group) }
            newGrid.append(contentsOf: gridTiles(from: outcome.plan, windows: group))
        }

        // Record the whole pass as one "tiling" usage event (sum across displays).
        usageTracker.record(passUsage, model: settings.model.rawValue, kind: .tiling)

        // If the AI was expected but failed, surface why (we still tiled via the fallback).
        if usingAI, let aiError {
            status = .failed("AI unavailable — used built-in tiler. \(aiError)")
            grid = newGrid
            return
        }

        grid = newGrid
        status = .applied(movedWindows: totalMoved)
    }

    /// User approved exceeding the hourly cap → grant headroom and try again.
    public func approveExtraAICalls() {
        rateLimiter.grantOverride(extra: 5)
        Task { await retile() }
    }

    // MARK: - Swap (drag one tile onto another)

    /// Swap the tiles under two CG (top-left) points. Returns true if a swap happened.
    ///
    /// The drag must *start on the source window's title bar* — that's how you grab a window to move
    /// it. A drag that starts in a window's content area (e.g. dragging a file out of it) is not a
    /// window move and must never trigger a swap, even if it ends over another tile.
    @discardableResult
    public func attemptSwap(fromCG: CGPoint, toCG: CGPoint) -> Bool {
        guard let i = Reflow.indexOfTile(titleBarContaining: fromCG, in: grid),
              let j = Reflow.indexOfTile(containing: toCG, in: grid),
              i != j else { return false }

        grid = Reflow.swapped(grid, i, j)
        applyAndSuppress {
            applier.applyGrid([grid[i], grid[j]])
        }
        status = .applied(movedWindows: 2)
        return true
    }

    // MARK: - Resize reflow + learning

    /// Called (debounced) when an existing window moved or resized. If exactly one tracked window
    /// changed *size*, reflow its neighbors and learn its new proportions. Never calls the LLM.
    public func handleGeometryChange() {
        guard Date() >= suppressGeometryUntil, !grid.isEmpty else { return }

        // Read current frames straight from the grid's live AX handles — no need to enumerate every
        // window of every app. Find the single tile whose size changed beyond the tolerance.
        var resizedIndex: Int?
        var newFrame: CGRect = .zero
        for (idx, tile) in grid.enumerated() {
            guard let liveFrame = AXWindow(tile.handle.element).frame else { continue }
            let sizeDelta = abs(liveFrame.width - tile.target.width) + abs(liveFrame.height - tile.target.height)
            if sizeDelta > Reflow.tolerance {
                // Only handle a single-window resize; multiple simultaneous changes mean it wasn't a
                // simple divider drag, so leave it for the next full tile.
                if resizedIndex != nil { return }
                resizedIndex = idx
                newFrame = liveFrame
            }
        }
        guard let resizedIndex else { return }

        let oldFrame = grid[resizedIndex].target
        grid = Reflow.afterResize(
            tiles: grid,
            resizedIndex: resizedIndex,
            oldFrame: oldFrame,
            newFrame: newFrame,
            gap: CGFloat(settings.gap)
        )

        // Apply the reflowed neighbors (not the resized window itself — the user already sized it).
        let neighbors = grid.enumerated().filter { $0.offset != resizedIndex }.map { $0.element }
        applyAndSuppress { applier.applyGrid(neighbors) }

        // Learn the new proportions relative to the display's usable area.
        if let display = DisplayProvider.display(containing: newFrame) {
            let vf = display.visibleFrame
            let resized = grid[resizedIndex]
            dimensionMemory.record(
                bundleId: resized.bundleId,
                categoryId: resized.categoryId,
                widthFraction: Double(newFrame.width / vf.width),
                heightFraction: Double(newFrame.height / vf.height)
            )
        }
        status = .applied(movedWindows: neighbors.count)
    }

    // MARK: - Save / Restore (no LLM)

    public func saveCurrentLayout(name: String) {
        let windows = enumerator.managedWindows(catalog: categoryStore.snapshot())
        let signature = (DisplayProvider.displays().first?.signature) ?? "default"
        store.save(name: name, windows: windows, displaySignature: signature)
    }

    public func savedLayoutNames() -> [String] {
        store.allLayouts().map(\.name).sorted()
    }

    public func restoreLayout(name: String) {
        guard let layout = store.layout(named: name) else {
            status = .failed("No saved layout named \(name)")
            return
        }
        let windows = enumerator.managedWindows(catalog: categoryStore.snapshot())
        let tiles = store.resolveTiles(for: layout, windows: windows)
        let plan = LayoutPlan(displaySignature: layout.displaySignature, tiles: tiles)
        applyAndSuppress { _ = applier.apply(plan: plan, to: windows) }
        grid = gridTiles(from: plan, windows: windows)
        status = .applied(movedWindows: tiles.count)
    }

    public func deleteLayout(name: String) {
        store.delete(name: name)
    }

    // MARK: - Helpers

    private func screenshotIfEnabled(for display: DisplayInfo) async -> ClaudeClient.ImageBlock? {
        guard settings.contentAware else { return nil }
        do {
            let base64 = try await ScreenCapture.captureDisplayAsBase64PNG(displayID: display.id)
            return ClaudeClient.ImageBlock(base64PNG: base64)
        } catch {
            NSLog("[Tessera] screenshot failed, continuing without it: \(error.localizedDescription)")
            return nil
        }
    }

    /// Run a block that moves windows, suppressing the geometry observer for a beat afterward so the
    /// resulting AX move/resize notifications aren't mistaken for user edits.
    private func applyAndSuppress(_ body: () -> Void) {
        body()
        // Long enough for the AX move/resize notifications our own applies generate to drain
        // (they arrive within tens of ms), short enough that the user's *next* resize is picked up
        // promptly rather than being swallowed.
        suppressGeometryUntil = Date().addingTimeInterval(0.35)
    }

    /// Build grid tiles by joining a plan (keyed by window UUID) back to its windows' AX handles.
    private func gridTiles(from plan: LayoutPlan, windows: [ManagedWindow]) -> [GridTile] {
        let byId = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        return plan.tiles.compactMap { tile in
            guard let w = byId[tile.windowId] else { return nil }
            return GridTile(handle: w.axHandle, bundleId: w.bundleId, categoryId: w.categoryId, appName: w.appName, target: tile.frame)
        }
    }
}
