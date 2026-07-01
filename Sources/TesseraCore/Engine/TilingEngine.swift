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

    /// Whether a layout is currently applied (something has been tiled). Used to decide whether a
    /// live setting change like the gap should be re-applied.
    public var hasActiveLayout: Bool { !grid.isEmpty }

    /// Centered "Planning layout…" HUD, shown while an AI plan is in flight.
    private let progressOverlay = ProgressOverlay()

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
        defer { isPlanning = false; progressOverlay.hide() }

        let catalog = categoryStore.snapshot()
        let windows = enumerator.managedWindows(catalog: catalog)
        guard !windows.isEmpty else { status = .applied(movedWindows: 0); grid = []; return }

        let usingAI = useAI && Keychain.hasAPIKey
        // Only the AI path has a visible wait worth a HUD; the offline tiler is instant.
        if usingAI { progressOverlay.show(text: "Planning layout…") }
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

            let tiles = gridTiles(from: outcome.plan, windows: group)
            newGrid.append(contentsOf: tiles)
            suppressGeometry(for: WindowAnimator.duration)
            await WindowAnimator.animate(
                tiles.map { WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target) },
                clampTo: display.visibleFrame
            )
            totalMoved += tiles.count
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

    // MARK: - Drag-to-snap (Magnet-style) + swap

    private enum DragProposal { case snap(CGRect); case swap(targetIndex: Int) }
    private let snapOverlay = SnapOverlay()
    private var draggedWindow: AXWindow?
    private var draggedGridIndex: Int?
    private var dragProposal: DragProposal?

    /// A window drag started. We only engage when the grab is on the window's title bar (so a file
    /// drag from the content area doesn't move/snap the window).
    public func dragBegan(atCG point: CGPoint) {
        draggedWindow = nil; draggedGridIndex = nil; dragProposal = nil
        guard let win = AXWindow.window(atCG: point), let frame = win.frame else { return }
        guard point.y <= frame.minY + Reflow.titleBarGrabHeight else { return }   // title-bar grab only
        draggedWindow = win
        draggedGridIndex = grid.firstIndex { CFEqual($0.handle.element, win.element) }
    }

    /// The pointer moved mid-drag: preview where the window will land (swap target or snap rect).
    public func dragMoved(toCG point: CGPoint) {
        guard draggedWindow != nil else { return }
        guard let display = DisplayProvider.display(containing: CGRect(x: point.x, y: point.y, width: 1, height: 1)) else {
            snapOverlay.hide(); dragProposal = nil; return
        }

        // Dropping one tile onto another (both managed) swaps them.
        if draggedGridIndex != nil,
           let target = grid.firstIndex(where: { $0.target.contains(point) }), target != draggedGridIndex {
            dragProposal = .swap(targetIndex: target)
            snapOverlay.show(cgFrame: grid[target].target)
            return
        }

        // Otherwise snap into the open area: largest empty rect, biased toward the pointer, inset for the gap.
        let occupied = grid.enumerated().filter { $0.offset != draggedGridIndex }.map { $0.element.target }
        if let empty = Snap.largestEmptyRect(containing: point, in: display.visibleFrame, avoiding: occupied) {
            let biased = Snap.biased(empty, toward: point)
            let g = CGFloat(settings.gap)
            let inset = biased.insetBy(dx: g, dy: g)
            dragProposal = .snap(inset.width > 80 && inset.height > 80 ? inset : biased)
            if case let .snap(frame) = dragProposal { snapOverlay.show(cgFrame: frame) }
        } else {
            dragProposal = nil
            snapOverlay.hide()
        }
    }

    /// The drag ended: apply the previewed proposal.
    public func dragEnded(atCG point: CGPoint) {
        snapOverlay.hide()
        defer { draggedWindow = nil; draggedGridIndex = nil; dragProposal = nil }
        guard let proposal = dragProposal else { return }
        switch proposal {
        case .swap(let target):
            guard let from = draggedGridIndex, from != target else { return }
            grid = Reflow.swapped(grid, from, target)
            let moves = [grid[from], grid[target]].map {
                WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target)
            }
            suppressGeometry(for: WindowAnimator.duration)
            Task { @MainActor in
                await WindowAnimator.animate(moves, clampTo: nil)
                status = .applied(movedWindows: 2)
            }
        case .snap(let frame):
            guard let win = draggedWindow else { return }
            let area = DisplayProvider.display(containing: frame)?.visibleFrame
            suppressGeometry(for: WindowAnimator.duration)
            upsertGrid(element: win.element, frame: frame)
            Task { @MainActor in
                await WindowAnimator.animate([WindowAnimator.Move(window: win, target: frame)], clampTo: area)
                status = .applied(movedWindows: 1)
            }
        }
    }

    /// Insert or update the grid tile for a window placed by snapping, classifying it by its app.
    private func upsertGrid(element: AXUIElement, frame: CGRect) {
        let app = AXWindow(element).pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let catId = categoryStore.categoryId(bundleId: app?.bundleIdentifier, appName: app?.localizedName ?? "")
        let tile = GridTile(handle: AXWindowHandle(element), bundleId: app?.bundleIdentifier,
                            categoryId: catId, appName: app?.localizedName ?? "", target: frame)
        if let i = grid.firstIndex(where: { CFEqual($0.handle.element, element) }) { grid[i] = tile }
        else { grid.append(tile) }
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
        let gridTilesForPlan = gridTiles(from: plan, windows: windows)
        grid = gridTilesForPlan
        suppressGeometry(for: WindowAnimator.duration)
        Task { @MainActor in
            await WindowAnimator.animate(
                gridTilesForPlan.map { WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target) },
                clampTo: nil
            )
            status = .applied(movedWindows: tiles.count)
        }
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
        suppressGeometry()
    }

    /// Ignore geometry notifications for a beat (plus any animation time) so the AX move/resize
    /// notifications our own applies generate aren't mistaken for user edits. The 0.35s tail is long
    /// enough for those to drain, short enough that the user's *next* resize is still picked up
    /// promptly. Pass `extra` to cover an in-flight slide animation.
    private func suppressGeometry(for extra: TimeInterval = 0) {
        suppressGeometryUntil = Date().addingTimeInterval(0.35 + extra)
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
