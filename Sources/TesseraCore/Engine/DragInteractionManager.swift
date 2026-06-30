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
    private var dragging = false

    /// Minimum cursor travel (points) before a press counts as a drag.
    private let dragThreshold: CGFloat = 8

    public init(engine: TilingEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUp() }
        }
        monitors = [down, drag, up].compactMap { $0 }
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
    }

    private func handleDragged() {
        guard settings.snapEnabled, let down = downLocation else { return }
        let now = NSEvent.mouseLocation
        if !dragging {
            guard abs(now.x - down.x) > dragThreshold || abs(now.y - down.y) > dragThreshold else { return }
            dragging = true
            engine.dragBegan(atCG: cg(down))
        }
        engine.dragMoved(toCG: cg(now))
    }

    private func handleUp() {
        defer { downLocation = nil; dragging = false }
        guard dragging else { return }
        engine.dragEnded(atCG: cg(NSEvent.mouseLocation))
    }
}
