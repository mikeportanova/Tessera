import Foundation
import AppKit

/// Drives Magnet-style drag interactions by forwarding global mouse events to the engine: grab a
/// window by its title bar and the engine previews (with an overlay) where it will land — snapping
/// into open desktop area, or swapping when dropped onto another tile — and applies it on release.
///
/// Uses global mouse monitors (read-only — they observe, never consume events), so it needs only the
/// Accessibility permission Tessera already requires.
@MainActor
public final class DragInteractionManager {

    private let engine: TilingEngine
    private let settings: AppSettings

    private var monitors: [Any] = []
    private var downLocation: CGPoint?     // AppKit (bottom-left) global coords
    /// Window under the cursor captured at mouse-down (before the OS drag moves it), with its frame
    /// and a snapshot of every other visible window's bounds — the occupancy the snap search must
    /// avoid. Both are taken NOW because the OS drag starts moving the window before `dragBegan`
    /// fires, and a moved window can no longer be told apart from its own stale bounds.
    private var pendingGrab: (window: AXWindow, frame: CGRect, occupied: [CGRect])?
    private var dragging = false
    /// Set when the user presses Escape mid-drag: the snap is abandoned and the release applies nothing.
    private var cancelled = false

    /// Minimum cursor travel (points) before a press counts as a drag.
    private let dragThreshold: CGFloat = 8
    /// Escape.
    private let escapeKeyCode: UInt16 = 53

    public init(engine: TilingEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {
        stop()   // idempotent: a second start() must not orphan the first set of monitors
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUp() }
        }
        let key = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        monitors = [down, drag, up, key].compactMap { $0 }
    }

    public func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private var primaryHeight: CGFloat { CoordinateConverter.primaryDisplayHeight() }
    private func cg(_ appKit: CGPoint) -> CGPoint {
        CoordinateConverter.appKitToCG(point: appKit, primaryHeight: primaryHeight)
    }

    // MARK: - Event handling

    private func handleDown() {
        downLocation = NSEvent.mouseLocation
        dragging = false
        cancelled = false
        pendingGrab = nil
        // Capture the window under the cursor NOW, before the OS drag moves it, so the title-bar grab
        // test is against its original position. Only when snapping is enabled (skips the AX hit-test
        // cost on every click otherwise).
        guard settings.snapEnabled else { return }
        let p = cg(NSEvent.mouseLocation)
        if let w = AXWindow.window(atCG: p), let f = w.frame {
            // Every other visible window's bounds, dragged window excluded by exact frame match —
            // reliable only at this instant, while the window still sits at `f`.
            let occupied = WindowEnumerator.onScreenWindowBounds().filter { b in
                !(abs(b.minX - f.minX) < 3 && abs(b.minY - f.minY) < 3 &&
                  abs(b.width - f.width) < 3 && abs(b.height - f.height) < 3)
            }
            pendingGrab = (w, f, occupied)
        }
    }

    private func handleDragged() {
        guard settings.snapEnabled, !cancelled, let down = downLocation else { return }
        let now = NSEvent.mouseLocation
        if !dragging {
            guard abs(now.x - down.x) > dragThreshold || abs(now.y - down.y) > dragThreshold else { return }
            dragging = true
            guard let grab = pendingGrab else { return }
            engine.dragBegan(atCG: cg(down), window: grab.window, originalFrame: grab.frame, occupied: grab.occupied)
        }
        engine.dragMoved(toCG: cg(now))
    }

    private func handleUp() {
        defer { downLocation = nil; dragging = false; cancelled = false; pendingGrab = nil }
        guard dragging, !cancelled else { return }
        engine.dragEnded(atCG: cg(NSEvent.mouseLocation))
    }

    /// Escape mid-drag abandons the snap: drop the preview and let the release apply nothing.
    private func handleKeyDown(_ event: NSEvent) {
        guard dragging, !cancelled, event.keyCode == escapeKeyCode else { return }
        cancelled = true
        engine.dragCancelled()
    }
}
