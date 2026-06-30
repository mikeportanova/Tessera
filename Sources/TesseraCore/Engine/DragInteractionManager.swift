import Foundation
import AppKit

/// Implements **drag-to-swap**: grab a tiled window and drop it onto another tile to swap their
/// positions. Uses a global mouse monitor (read-only — it observes, never consumes events) so it
/// needs only the Accessibility permission Tessera already requires.
///
/// Disambiguation is geometric and free: a swap only fires when the drag *starts in one tile and
/// ends in a different one*. Dragging within a single tile (e.g. resizing via an edge) leaves the
/// source and target tiles equal, so `TilingEngine.attemptSwap` no-ops.
@MainActor
public final class DragInteractionManager {

    private let engine: TilingEngine
    private let settings: AppSettings

    private var monitors: [Any] = []
    private var downLocation: CGPoint?     // AppKit (bottom-left) global coords
    private var didDrag = false

    /// Minimum cursor travel (points) before a press counts as a drag.
    private let dragThreshold: CGFloat = 12

    public init(engine: TilingEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {
        // Global monitors observe events destined for *other* apps — exactly the window drags we
        // care about. (Tessera has no windows of its own, so a local monitor isn't needed.)
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleDown(event) }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleDragged(event) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleUp(event) }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    public func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - Event handling

    private func handleDown(_ event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        didDrag = false
    }

    private func handleDragged(_ event: NSEvent) {
        guard let down = downLocation else { return }
        let now = NSEvent.mouseLocation
        if abs(now.x - down.x) > dragThreshold || abs(now.y - down.y) > dragThreshold {
            didDrag = true
        }
    }

    private func handleUp(_ event: NSEvent) {
        defer { downLocation = nil; didDrag = false }
        guard settings.snapEnabled, didDrag, let down = downLocation else { return }
        let up = NSEvent.mouseLocation

        // Convert both endpoints from AppKit (bottom-left) to CG (top-left) to match grid frames.
        let h = CoordinateConverter.primaryDisplayHeight()
        let fromCG = CoordinateConverter.appKitToCG(point: down, primaryHeight: h)
        let toCG = CoordinateConverter.appKitToCG(point: up, primaryHeight: h)
        engine.attemptSwap(fromCG: fromCG, toCG: toCG)
    }
}
