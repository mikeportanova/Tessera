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

    /// Whether the last layout can be reverted with Undo.
    @Published public private(set) var canUndo = false

    private let enumerator = WindowEnumerator()
    private let planner = LayoutPlanner()
    private let applier = WindowApplier()
    private let store = LayoutStore()
    private let settings: AppSettings
    public let rateLimiter: RateLimiter
    public let dimensionMemory: DimensionMemory
    public let categoryStore: CategoryStore
    public let usageTracker: UsageTracker
    public let appRules: AppRulesStore
    public let layoutCache = LayoutCache()

    /// The frames Tessera last assigned, with live AX handles — survives re-enumeration.
    private var grid: [GridTile] = []

    /// Whether a layout is currently applied (something has been tiled). Used to decide whether a
    /// live setting change like the gap should be re-applied.
    public var hasActiveLayout: Bool { !grid.isEmpty }

    /// Centered "Planning layout…" HUD, shown while an AI plan is in flight.
    private let progressOverlay = ProgressOverlay()
    /// Ghost-rectangle preview with Apply/Cancel, used when the user opts into previewing.
    private let preview = LayoutPreview()

    /// Window-set signature of the last tiling pass — the layout cache key. Nil once the window set
    /// changes (an app opened/closed), so manual corrections only refine the entry they belong to.
    private var lastSignature: String?

    /// Frames (and grid) captured immediately before the last layout was applied. One level deep.
    private var undoFrames: [(handle: AXWindowHandle, frame: CGRect)] = []
    private var undoGrid: [GridTile] = []

    /// Guard against overlapping planning passes.
    private var isPlanning = false
    /// Ignore geometry notifications until this instant — set after we apply frames ourselves, so
    /// our own moves don't masquerade as user resizes.
    private var suppressGeometryUntil = Date.distantPast

    public init(settings: AppSettings, rateLimiter: RateLimiter, dimensionMemory: DimensionMemory, categoryStore: CategoryStore, usageTracker: UsageTracker, appRules: AppRulesStore = AppRulesStore()) {
        self.settings = settings
        self.rateLimiter = rateLimiter
        self.dimensionMemory = dimensionMemory
        self.categoryStore = categoryStore
        self.usageTracker = usageTracker
        self.appRules = appRules
    }

    // MARK: - Tile now / re-tile

    /// - Parameter useAI: when false (e.g. an automatic re-tile on a new window), the offline tiler
    ///   is used and the LLM is never called — keeps frequent auto-arranges fast and free. Manual
    ///   "Tile Now" / the hotkey pass true.
    /// - Parameter interactive: false for automatic triggers (auto-arrange, live gap changes) —
    ///   skips the optional preview so the user isn't interrupted by a prompt they didn't ask for.
    public func retile(useAI: Bool = true, interactive: Bool = true) async {
        guard !isPlanning else { return }
        isPlanning = true
        status = .planning
        defer { isPlanning = false; progressOverlay.hide() }

        let catalog = categoryStore.snapshot()
        let rules = appRules.snapshot()
        var windows = enumerator.managedWindows(catalog: catalog)
        // Per-app "float" rule: those windows overlay every layout and are never tiled.
        windows.removeAll { rules.rule(for: $0.bundleId) == .float }
        guard !windows.isEmpty else { status = .applied(movedWindows: 0); grid = []; return }

        let usingAI = useAI && Keychain.hasAPIKey
        rateLimiter.maxPerHour = settings.maxAICallsPerHour
        let learned = dimensionMemory.snapshot()
        let intent = settings.intent
        let displays = DisplayProvider.displays()

        let signature = LayoutCache.signature(windows: windows, displays: displays)
        lastSignature = signature

        // Layout cache: the same window set on the same displays re-applies the last AI layout
        // instantly — zero tokens, zero latency. Manual corrections have already been folded in.
        if usingAI, settings.reuseLayouts,
           let cached = layoutCache.layout(for: signature),
           let resolved = LayoutCache.resolve(cached, windows: windows) {
            let tiles = resolved.map { r in
                GridTile(handle: r.window.axHandle, bundleId: r.window.bundleId,
                         categoryId: r.window.categoryId, appName: r.window.appName, target: r.frame)
            }
            await applyTiles(tiles, interactive: interactive)
            return
        }

        // Only the AI path has a visible wait worth a HUD; the offline tiler is instant.
        if usingAI { progressOverlay.show(text: "Planning layout…") }

        // Assign each window to the display its frame most overlaps — in one pass over the
        // already-fetched `displays`, rather than re-enumerating screens per window.
        var windowsByDisplay: [CGDirectDisplayID: [ManagedWindow]] = [:]
        for window in windows {
            let best = displays.max {
                window.frame.intersectionArea($0.visibleFrame) < window.frame.intersectionArea($1.visibleFrame)
            } ?? displays.first
            if let id = best?.id { windowsByDisplay[id, default: []].append(window) }
        }

        var newGrid: [GridTile] = []
        var passUsage = TokenUsage.zero
        var aiError: String?
        var allUsedAI = true

        if usingAI, displays.count > 1 {
            // Multi-display: ONE request covering everything, so windows may move between displays.
            if !rateLimiter.canCall() {
                status = .needsApproval(used: rateLimiter.callsInLastHour, max: rateLimiter.maxPerHour)
                return
            }
            let outcome = await planner.planMultiDisplay(
                displays: displays, windows: windows, gap: settings.gap, model: settings.model,
                catalog: catalog, learned: learned, intent: intent, rules: rules
            )
            rateLimiter.recordCall()
            passUsage = outcome.usage
            aiError = outcome.error
            allUsedAI = outcome.usedAI
            newGrid = gridTiles(from: outcome.plan, windows: windows)
        } else {
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
                        image: image, catalog: catalog, learned: learned, intent: intent, rules: rules
                    )
                    rateLimiter.recordCall()
                } else {
                    // Offline: deterministic tiler, no network, no token spend.
                    let plan = FallbackTiler.plan(display: display, windows: group, gap: settings.gap,
                                                  catalog: catalog, learned: learned, intent: intent, rules: rules)
                    outcome = LayoutPlanner.Outcome(plan: plan, usage: .zero, usedAI: false, error: nil)
                }
                passUsage = passUsage + outcome.usage
                if let e = outcome.error, aiError == nil { aiError = e }
                if !outcome.usedAI { allUsedAI = false }
                newGrid.append(contentsOf: gridTiles(from: outcome.plan, windows: group))
            }
        }

        // Record the whole pass as one "tiling" usage event (sum across displays).
        usageTracker.record(passUsage, model: settings.model.rawValue, kind: .tiling)
        progressOverlay.hide()

        await applyTiles(newGrid, interactive: interactive)

        // Only cache layouts the AI actually produced — the offline tiler is already instant, and a
        // fallback layout shouldn't shadow a future AI answer for this window set.
        if usingAI, allUsedAI, aiError == nil {
            layoutCache.store(signature: signature, entries: newGrid.map {
                CachedLayout.Entry(appKey: LayoutCache.appKey(bundleId: $0.bundleId, appName: $0.appName), frame: $0.target)
            })
        }

        // If the AI was expected but failed, surface why (we still tiled via the fallback).
        if usingAI, let aiError {
            status = .failed("AI unavailable — used built-in tiler. \(aiError)")
        }
    }

    /// Shared tail of every tiling path: optional preview gate, undo snapshot, animated apply.
    /// Sets `grid` and `status` (unless the user cancels the preview).
    private func applyTiles(_ tiles: [GridTile], interactive: Bool) async {
        guard !tiles.isEmpty else { status = .applied(movedWindows: 0); grid = []; return }

        if interactive, settings.previewBeforeApply {
            progressOverlay.hide()
            guard await preview.confirm(cgFrames: tiles.map(\.target)) else {
                status = .idle
                return
            }
        }

        captureUndo(handles: tiles.map(\.handle))
        let moves = tiles.map {
            WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target,
                                clamp: DisplayProvider.display(containing: $0.target)?.visibleFrame)
        }
        suppressGeometry(for: WindowAnimator.duration)
        await WindowAnimator.animate(moves)
        grid = tiles
        status = .applied(movedWindows: tiles.count)
    }

    // MARK: - Undo

    /// Snapshot the current frames of the windows about to move (plus the current grid), so the last
    /// layout operation can be reverted with one keystroke.
    private func captureUndo(handles: [AXWindowHandle]) {
        undoFrames = handles.compactMap { h in
            AXWindow(h.element).frame.map { (handle: h, frame: $0) }
        }
        undoGrid = grid
        canUndo = !undoFrames.isEmpty
    }

    /// Revert the last tiling/snap/swap: slide every affected window back to where it was.
    public func undoLastLayout() {
        guard canUndo else { return }
        let moves = undoFrames.compactMap { entry -> WindowAnimator.Move? in
            let win = AXWindow(entry.handle.element)
            guard win.isAlive else { return nil }
            return WindowAnimator.Move(window: win, target: entry.frame,
                                       clamp: DisplayProvider.display(containing: entry.frame)?.visibleFrame)
        }
        grid = undoGrid.filter { AXWindow($0.handle.element).isAlive }
        undoFrames = []
        undoGrid = []
        canUndo = false
        guard !moves.isEmpty else { return }
        suppressGeometry(for: WindowAnimator.duration)
        Task { @MainActor in
            await WindowAnimator.animate(moves)
            status = .applied(movedWindows: moves.count)
        }
    }

    // MARK: - Quick snap (Magnet-style, focused window)

    public enum QuickSnapAction: Sendable {
        case leftHalf, rightHalf, maximize
    }

    /// Move the focused window to a half/maximized frame on its display. No AI, no enumeration.
    public func quickSnap(_ action: QuickSnapAction) {
        guard let win = focusedWindow(), let frame = win.frame,
              let display = DisplayProvider.display(containing: frame) ?? DisplayProvider.displays().first
        else { return }
        let vf = display.visibleFrame
        let g = CGFloat(settings.gap)
        let target: CGRect
        switch action {
        case .leftHalf:  target = Snap.half(left: true, of: vf, gap: g)
        case .rightHalf: target = Snap.half(left: false, of: vf, gap: g)
        case .maximize:  target = Snap.maximized(of: vf, gap: g)
        }
        captureUndo(handles: [AXWindowHandle(win.element)])
        upsertGrid(element: win.element, frame: target)
        recordPlacement(of: win.element, frame: target, in: vf)
        suppressGeometry(for: WindowAnimator.duration)
        Task { @MainActor in
            await WindowAnimator.animate([WindowAnimator.Move(window: win, target: target, clamp: vf)])
            status = .applied(movedWindows: 1)
        }
    }

    /// The focused window of the frontmost app (excluding Tessera itself).
    private func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.fileread.Tessera" else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return AXWindow(ref as! AXUIElement)
    }

    // MARK: - Grid maintenance

    /// The set of open windows changed (app launched/quit, window created/destroyed): stale grid
    /// entries are pruned immediately and the cache key from the previous pass no longer applies.
    public func windowSetChanged() {
        lastSignature = nil
        pruneStaleTiles()
    }

    /// Drop grid entries whose windows have been closed, so their slots neither block snapping into
    /// now-empty space nor offer a swap onto a window that no longer exists.
    public func pruneStaleTiles() {
        grid.removeAll { !AXWindow($0.handle.element).isAlive }
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
    /// The dragged window's frame at grab time — used to reposition the displaced window when an
    /// untiled window is swapped onto an existing tile.
    private var draggedOriginalFrame: CGRect?
    private var dragProposal: DragProposal?
    /// Every visible window's bounds captured at drag start (minus the dragged window) — the
    /// occupancy the empty-rect search must avoid. Includes windows Tessera has never tiled, which
    /// the grid alone can't see; captured once because windows don't move mid-drag.
    private var dragOccupied: [CGRect] = []

    /// A window drag started. The `window` and its `originalFrame` are captured by the caller at
    /// mouse-down (before the OS drag moves the window), so the title-bar test uses the grab point
    /// against the window's *original* position — not a stale hit-test after it has already moved.
    /// We only engage when the grab was on the title bar (so dragging a file out of the content area
    /// doesn't move/snap the window).
    /// `occupied` is the caller's mouse-down snapshot of every OTHER visible window's bounds —
    /// captured before the OS drag moved the window, when its own footprint could still be excluded.
    public func dragBegan(atCG point: CGPoint, window: AXWindow, originalFrame: CGRect, occupied: [CGRect]) {
        draggedWindow = nil; draggedGridIndex = nil; draggedOriginalFrame = nil; dragProposal = nil; dragOccupied = []
        // Stale slots would block snapping into now-empty space or offer swaps onto dead windows.
        pruneStaleTiles()
        // Title-bar grab only — and clear of the edge resize handles, so grabbing the top edge or a
        // top corner to RESIZE never arms a move/swap.
        guard Reflow.isMoveGrab(point: point, frame: originalFrame) else { return }
        // Manual moves happen outside the engine, so targets can be stale: re-sync every tile to its
        // window's live frame so a vacated slot reads as snappable empty space and swap targeting
        // reflects where windows actually are. The dragged window pins to its mouse-down frame — the
        // OS drag has already started moving it.
        grid = Reflow.synced(grid, liveFrames: grid.map { tile in
            CFEqual(tile.handle.element, window.element) ? originalFrame : AXWindow(tile.handle.element).frame
        })
        draggedWindow = window
        draggedOriginalFrame = originalFrame
        draggedGridIndex = grid.firstIndex { CFEqual($0.handle.element, window.element) }
        dragOccupied = occupied
    }

    /// The pointer moved mid-drag: preview where the window will land (swap target or snap rect).
    public func dragMoved(toCG point: CGPoint) {
        guard let dragged = draggedWindow else { return }

        // A window MOVE never changes the window's size; a RESIZE always does. If the size is
        // drifting, the user grabbed a resize handle we couldn't rule out — abandon the drag so a
        // resize can never end in a swap or snap. (Reflow picks the resize up afterward.)
        if let original = draggedOriginalFrame, let live = dragged.frame,
           abs(live.width - original.width) > 2 || abs(live.height - original.height) > 2 {
            dragCancelled()
            return
        }
        guard let display = DisplayProvider.display(containing: CGRect(x: point.x, y: point.y, width: 1, height: 1)) else {
            snapOverlay.hide(); dragProposal = nil; return
        }

        // Dropping onto another tile swaps into its slot. Works whether the dragged window is already
        // tiled (a straight exchange) or brand-new/untiled (it adopts the slot; see dragEnded) — so a
        // just-opened app can be dropped onto a tile even when the desktop is fully occupied.
        if let target = grid.firstIndex(where: { $0.target.contains(point) }), target != draggedGridIndex {
            dragProposal = .swap(targetIndex: target)
            snapOverlay.show(cgFrame: grid[target].target)
            return
        }

        // Otherwise snap into the open area: largest empty rect, biased toward the pointer, inset for the gap.
        let occupied = dragOccupied
        if let empty = Snap.largestEmptyRect(containing: point, in: display.visibleFrame, avoiding: occupied) {
            var biased = Snap.biased(empty, toward: point)
            // If halving toward an edge left a zone too small to use, offer the whole area instead
            // of nothing — a small gap near an edge should still be snappable.
            if !Snap.isProposable(biased, in: display.visibleFrame) { biased = empty }
            // Never propose a too-wide, partial-height rectangle (looks absurd on wide displays).
            let capped = Snap.capWidth(biased, in: display.visibleFrame, toward: point)
            let g = CGFloat(settings.gap)
            let inset = capped.insetBy(dx: g, dy: g)
            let frame = inset.width > 80 && inset.height > 80 ? inset : capped
            // Don't offer a comically short, super-wide sliver — there's no good window that shape.
            if Snap.isProposable(frame, in: display.visibleFrame) {
                dragProposal = .snap(frame)
                snapOverlay.show(cgFrame: frame)
            } else {
                dragProposal = nil
                snapOverlay.hide()
            }
        } else {
            dragProposal = nil
            snapOverlay.hide()
        }
    }

    /// The drag was abandoned (e.g. the user pressed Escape): drop the preview and apply nothing. The
    /// window simply stays wherever the OS drag left it.
    public func dragCancelled() {
        snapOverlay.hide()
        draggedWindow = nil; draggedGridIndex = nil; draggedOriginalFrame = nil; dragProposal = nil; dragOccupied = []
    }

    /// The drag ended: apply the previewed proposal.
    public func dragEnded(atCG point: CGPoint) {
        snapOverlay.hide()
        defer { draggedWindow = nil; draggedGridIndex = nil; draggedOriginalFrame = nil; dragProposal = nil; dragOccupied = [] }
        guard let proposal = dragProposal else { return }
        switch proposal {
        case .swap(let target):
            guard grid.indices.contains(target) else { return }
            let moves: [WindowAnimator.Move]
            if let from = draggedGridIndex {
                // Both windows are tiled → straight exchange of their slots.
                guard from != target else { return }
                captureUndo(handles: [grid[from].handle, grid[target].handle])
                grid = Reflow.swapped(grid, from, target)
                moves = [grid[from], grid[target]].map {
                    WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target)
                }
                recordGridPlacement(of: grid[from])
                recordGridPlacement(of: grid[target])
            } else if let win = draggedWindow, let origin = draggedOriginalFrame {
                // Dragged window is untiled (e.g. a just-opened app): it takes the target tile's slot,
                // and that tile's window moves into the dragged window's old frame. Both end up managed.
                let targetFrame = grid[target].target
                let displaced = AXWindow(grid[target].handle.element)
                let clampArea = DisplayProvider.display(containing: targetFrame)?.visibleFrame
                let displacedFrame = tidyDisplacedFrame(origin, in: clampArea)
                captureUndo(handles: [AXWindowHandle(win.element), grid[target].handle])
                grid[target] = makeGridTile(for: win.element, frame: targetFrame)
                upsertGrid(element: displaced.element, frame: displacedFrame)
                moves = [WindowAnimator.Move(window: win, target: targetFrame, clamp: clampArea),
                         WindowAnimator.Move(window: displaced, target: displacedFrame, clamp: clampArea)]
                recordGridPlacement(of: grid[target])
            } else {
                return
            }
            updateCacheFromGrid()
            suppressGeometry(for: WindowAnimator.duration)
            Task { @MainActor in
                await WindowAnimator.animate(moves)
                status = .applied(movedWindows: moves.count)
            }
        case .snap(let frame):
            guard let win = draggedWindow else { return }
            let area = DisplayProvider.display(containing: frame)?.visibleFrame
            captureUndo(handles: [AXWindowHandle(win.element)])
            suppressGeometry(for: WindowAnimator.duration)
            upsertGrid(element: win.element, frame: frame)
            recordPlacement(of: win.element, frame: frame, in: area)
            updateCacheFromGrid()
            Task { @MainActor in
                await WindowAnimator.animate([WindowAnimator.Move(window: win, target: frame, clamp: area)])
                status = .applied(movedWindows: 1)
            }
        }
    }

    /// Fold a manual placement into `DimensionMemory` — sizes *and* the horizontal position, so
    /// "this app lives on the right" becomes a durable habit that future layouts honor.
    private func recordPlacement(of element: AXUIElement, frame: CGRect, in area: CGRect?) {
        guard let area, area.width > 0, area.height > 0 else { return }
        let app = AXWindow(element).pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let catId = categoryStore.categoryId(bundleId: app?.bundleIdentifier, appName: app?.localizedName ?? "")
        dimensionMemory.record(
            bundleId: app?.bundleIdentifier,
            categoryId: catId,
            widthFraction: Double(frame.width / area.width),
            heightFraction: Double(frame.height / area.height),
            xFraction: Double((frame.midX - area.minX) / area.width)
        )
    }

    private func recordGridPlacement(of tile: GridTile) {
        let area = DisplayProvider.display(containing: tile.target)?.visibleFrame
        recordPlacement(of: tile.handle.element, frame: tile.target, in: area)
    }

    /// Push the current grid back into the layout cache entry for this window set, so a manual
    /// correction (swap, snap, resize) refines what "the layout" means for these windows.
    private func updateCacheFromGrid() {
        guard settings.reuseLayouts, let signature = lastSignature, !grid.isEmpty else { return }
        layoutCache.updateIfPresent(signature: signature, entries: grid.map {
            CachedLayout.Entry(appKey: LayoutCache.appKey(bundleId: $0.bundleId, appName: $0.appName), frame: $0.target)
        })
    }

    /// A sensible destination for the window bumped out of a slot by an untiled drop: kept no larger
    /// than the display and fully on-screen, so a large or centered new window doesn't fling it
    /// partly off the edge.
    private func tidyDisplacedFrame(_ frame: CGRect, in area: CGRect?) -> CGRect {
        guard let area else { return frame }
        let size = CGSize(width: Swift.min(frame.width, area.width), height: Swift.min(frame.height, area.height))
        var result = CGRect(origin: frame.origin, size: size)
        if let fixed = WindowApplier.onScreenOrigin(for: result, in: area) { result.origin = fixed }
        return result
    }

    /// Build a grid tile for a window placed by snapping, classifying it by its app.
    private func makeGridTile(for element: AXUIElement, frame: CGRect) -> GridTile {
        let app = AXWindow(element).pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let catId = categoryStore.categoryId(bundleId: app?.bundleIdentifier, appName: app?.localizedName ?? "")
        return GridTile(handle: AXWindowHandle(element), bundleId: app?.bundleIdentifier,
                        categoryId: catId, appName: app?.localizedName ?? "", target: frame)
    }

    /// Insert or update the grid tile for a window placed by snapping.
    private func upsertGrid(element: AXUIElement, frame: CGRect) {
        let tile = makeGridTile(for: element, frame: frame)
        if let i = grid.firstIndex(where: { CFEqual($0.handle.element, element) }) { grid[i] = tile }
        else { grid.append(tile) }
    }

    // MARK: - Resize reflow + learning

    /// Called (debounced) when an existing window moved or resized. If exactly one tracked window
    /// changed *size*, reflow its neighbors and learn its new proportions. Never calls the LLM.
    public func handleGeometryChange() {
        guard Date() >= suppressGeometryUntil, !grid.isEmpty else { return }

        // Read current frames straight from the grid's live AX handles — no need to enumerate every
        // window of every app. Find the single tile whose size changed beyond the tolerance, and any
        // tiles that merely MOVED (same size, new position).
        var resizedIndices: [Int] = []
        var movedOnly: [(index: Int, frame: CGRect)] = []
        var newFrame: CGRect = .zero
        for (idx, tile) in grid.enumerated() {
            guard let liveFrame = AXWindow(tile.handle.element).frame else { continue }
            let sizeDelta = abs(liveFrame.width - tile.target.width) + abs(liveFrame.height - tile.target.height)
            let moveDelta = abs(liveFrame.minX - tile.target.minX) + abs(liveFrame.minY - tile.target.minY)
            if sizeDelta > Reflow.tolerance {
                resizedIndices.append(idx)
                newFrame = liveFrame
            } else if moveDelta > Reflow.tolerance {
                movedOnly.append((idx, liveFrame))
            }
        }

        // A pure move means the user relocated the window: its tile follows it, vacating the old
        // slot so drag-to-snap sees that space as empty again. No reflow — the move was deliberate.
        for m in movedOnly { grid[m.index].target = m.frame }

        // Only reflow a single-window resize; multiple simultaneous changes mean it wasn't a simple
        // divider drag, so leave those for the next full tile.
        guard resizedIndices.count == 1, let resizedIndex = resizedIndices.first else {
            if !movedOnly.isEmpty { updateCacheFromGrid() }   // manual moves still refine the cache
            return
        }

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

        // Learn the new proportions (and position) relative to the display's usable area.
        if let display = DisplayProvider.display(containing: newFrame) {
            let vf = display.visibleFrame
            let resized = grid[resizedIndex]
            dimensionMemory.record(
                bundleId: resized.bundleId,
                categoryId: resized.categoryId,
                widthFraction: Double(newFrame.width / vf.width),
                heightFraction: Double(newFrame.height / vf.height),
                xFraction: Double((newFrame.midX - vf.minX) / vf.width)
            )
        }
        updateCacheFromGrid()   // a manual resize refines the cached layout for this window set
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
        captureUndo(handles: gridTilesForPlan.map(\.handle))
        grid = gridTilesForPlan
        suppressGeometry(for: WindowAnimator.duration)
        Task { @MainActor in
            await WindowAnimator.animate(
                gridTilesForPlan.map { WindowAnimator.Move(window: AXWindow($0.handle.element), target: $0.target) }
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
