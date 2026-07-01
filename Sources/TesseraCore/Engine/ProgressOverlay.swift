import AppKit

/// A small, centered, translucent HUD shown while an AI layout is being planned. Because it's a
/// floating panel (not part of the menu-bar popover), the user sees "Planning layout…" even after the
/// popover dismisses on click — the network round-trip is otherwise invisible.
@MainActor
public final class ProgressOverlay {
    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var label: NSTextField?

    public init() {}

    /// Show (or re-center) the HUD with the given caption.
    public func show(text: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text

        // Center on the screen under the pointer (fallback: main screen).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        spinner?.startAnimation(nil)
        panel.orderFrontRegardless()
    }

    public func hide() {
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let width: CGFloat = 220, height: CGFloat = 100
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Liquid-glass card: a rounded HUD-material blur behind the content.
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Planning layout…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(spinner)
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: blur.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
        ])

        p.contentView = blur
        self.spinner = spinner
        self.label = label
        return p
    }
}
