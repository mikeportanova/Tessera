import AppKit

/// Shows a proposed layout as ghost rectangles plus a small floating "Apply / Cancel" card, and waits
/// for the user's decision before any window moves. The card is a non-activating panel that can
/// become key, so ⏎ applies and ⎋ cancels without switching apps.
@MainActor
public final class LayoutPreview: NSObject {

    private var ghostPanels: [NSPanel] = []
    private var hud: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Present the proposed frames (CG top-left coords) and await the user's choice.
    /// Times out as "cancel" after 30s so an unattended prompt can't hold the engine forever.
    public func confirm(cgFrames: [CGRect]) async -> Bool {
        finish(false, resume: false)   // tear down any stray prior state
        showGhosts(cgFrames)
        showHUD()
        return await withCheckedContinuation { c in
            continuation = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finish(false)
            }
        }
    }

    @objc private func applyPressed() { finish(true) }
    @objc private func cancelPressed() { finish(false) }

    private func finish(_ apply: Bool, resume: Bool = true) {
        ghostPanels.forEach { $0.orderOut(nil) }
        ghostPanels = []
        hud?.orderOut(nil)
        hud = nil
        guard resume, let c = continuation else { return }
        continuation = nil
        c.resume(returning: apply)
    }

    // MARK: - Ghost rectangles

    private func showGhosts(_ cgFrames: [CGRect]) {
        let primaryHeight = CoordinateConverter.primaryDisplayHeight()
        for frame in cgFrames {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = GhostView()
            p.setFrame(CoordinateConverter.cgToAppKit(rect: frame, primaryHeight: primaryHeight), display: true)
            p.orderFrontRegardless()
            ghostPanels.append(p)
        }
    }

    // MARK: - Decision card

    private func showHUD() {
        let width: CGFloat = 260, height: CGFloat = 92
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "Apply this layout?")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPressed))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
        p.contentView = blur

        // Bottom-center of the screen under the pointer (fallback: main).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.minY + 60))
        }
        p.makeKeyAndOrderFront(nil)
        hud = p
    }
}

/// Borderless panels can't become key by default; the decision card needs key status so ⏎/⎋ work.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dashed ghost rectangle for a proposed tile.
private final class GhostView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
