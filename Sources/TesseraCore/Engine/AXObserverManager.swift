import Foundation
import ApplicationServices
import AppKit

/// Watches for new windows across all regular apps and reports them to a callback.
///
/// Two layers:
///   • `NSWorkspace` notifications tell us when apps launch/terminate, so we can attach/detach
///     per-app AX observers.
///   • A per-pid `AXObserver` for `kAXWindowCreatedNotification` (and focus changes) tells us when
///     a new window appears within an already-running app.
///
/// All callbacks are delivered on the main run loop.
@MainActor
public final class AXObserverManager {

    /// Called when the *set* of windows changed — a window/app was created or destroyed. This is the
    /// trigger for a (rate-limited) AI re-tile.
    public var onWindowsChanged: (() -> Void)?

    /// Called when an existing window *moved or resized*. This drives local reflow only — never an
    /// AI call — so dragging a window around can't run up API usage.
    public var onWindowGeometryChanged: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.attach(to: app)
                self?.onWindowsChanged?()
            }
        })

        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.detach(pid: app.processIdentifier)
                self?.onWindowsChanged?()
            }
        })

        // Attach to everything already running.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(to: app)
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { nc.removeObserver($0) }
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { detach(pid: pid) }
    }

    // MARK: - Per-app observers

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, observers[pid] == nil, app.bundleIdentifier != "com.fileread.Tessera" else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()

        // Structural notifications → onWindowsChanged (may trigger AI). Geometry notifications →
        // onWindowGeometryChanged (local reflow only). The C callback routes by notification name.
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]
        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, context)
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        observers[pid] = observer
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Invoked by the C callback (already on the main run loop), routed by notification name.
    fileprivate func dispatch(notification: String) {
        switch notification {
        case kAXWindowMovedNotification as String, kAXWindowResizedNotification as String:
            onWindowGeometryChanged?()
        default:
            onWindowsChanged?()
        }
    }
}

/// C-compatible AX observer callback. Bridges back to the Swift manager via the opaque context.
private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let manager = Unmanaged<AXObserverManager>.fromOpaque(context).takeUnretainedValue()
    let name = notification as String
    // The callback fires on the run loop we registered with (main), so hop explicitly to satisfy
    // the main-actor isolation of the manager.
    MainActor.assumeIsolated {
        manager.dispatch(notification: name)
    }
}
