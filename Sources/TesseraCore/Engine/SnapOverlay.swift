import AppKit

/// A translucent, click-through panel that previews where a dragged window will snap. Positioned in
/// CG (top-left) coordinates; converts to AppKit screen coordinates internally.
@MainActor
public final class SnapOverlay {
    private var panel: NSPanel?

    public init() {}

    /// Show/move the preview to a CG (top-left) frame.
    public func show(cgFrame: CGRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let appKit = CoordinateConverter.cgToAppKit(rect: cgFrame, primaryHeight: CoordinateConverter.primaryDisplayHeight())
        panel.setFrame(appKit, display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = SnapPreviewView()
        return p
    }
}

/// Draws a rounded rectangle filled with a faint accent tint and an accent border.
private final class SnapPreviewView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
