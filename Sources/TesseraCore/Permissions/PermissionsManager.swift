import Foundation
import ApplicationServices
import AppKit
import Combine

/// Tracks and requests the two TCC permissions Tessera needs:
///   1. **Accessibility** — mandatory, to move/resize other apps' windows.
///   2. **Screen Recording** — optional, only when content-aware (screenshot) tiling is enabled.
///
/// Neither can be granted programmatically; the user toggles them in System Settings. macOS fires
/// no notification when Accessibility is granted, so we poll `AXIsProcessTrusted()`.
@MainActor
public final class PermissionsManager: ObservableObject {
    @Published public private(set) var accessibilityTrusted: Bool = false

    private var pollTimer: Timer?

    public init() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Prompt for Accessibility (shows the system dialog deep-linking to System Settings) and begin
    /// polling for the grant. Safe to call repeatedly.
    public func requestAccessibility() {
        // Use the documented key string directly; referencing the imported `kAXTrustedCheckOptionPrompt`
        // global trips Swift 6 strict-concurrency checks (it's a non-isolated mutable global).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityTrusted {
            startPolling()
        }
    }

    /// Re-check without prompting.
    public func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Open the Accessibility pane directly (for a "Open System Settings" menu item).
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open the Screen Recording pane directly.
    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // The timer fires on the main run loop (this object is @MainActor), so we can assume main
        // isolation rather than spawning a Task that would capture the non-Sendable `timer`.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.accessibilityTrusted = true
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }
}
