import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Produces the set of `ManagedWindow`s currently on screen that Tessera can tile.
///
/// Strategy: walk `NSWorkspace.runningApplications` filtered to regular (Dock-visible) apps, then
/// for each app read its tileable windows via the Accessibility API. We deliberately rely on AX
/// (not `CGWindowListCopyWindowInfo`) for the windows we intend to move, because only AX gives a
/// movable handle. `CGWindowList` is still useful for fast title/z-order reads, but there is no
/// stable shared id between the two, so we keep the model AX-anchored.
public struct WindowEnumerator {

    /// Apps we never want to tile (our own UI, system agents that sneak in as regular, etc.).
    private let ignoredBundleIds: Set<String>

    public init(ignoredBundleIds: Set<String> = ["com.fileread.Tessera"]) {
        self.ignoredBundleIds = ignoredBundleIds
    }

    /// All tileable windows across all regular apps, in CG (top-left) coordinates. Windows are
    /// classified via the supplied `catalog` (so custom categories apply).
    public func managedWindows(catalog: CategoryCatalog) -> [ManagedWindow] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !$0.isTerminated
                && !(($0.bundleIdentifier).map(ignoredBundleIds.contains) ?? false)
        }

        var result: [ManagedWindow] = []
        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let appName = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier
            let categoryId = catalog.categoryId(bundleId: bundleId, appName: appName)

            let axApp = AXApplication(pid: pid)
            for axWindow in axApp.windows() {
                guard let frame = axWindow.frame, frame.width > 1, frame.height > 1 else { continue }
                result.append(
                    ManagedWindow(
                        pid: pid,
                        appName: appName,
                        bundleId: bundleId,
                        title: axWindow.title,
                        categoryId: categoryId,
                        frame: frame,
                        isMinimized: axWindow.isMinimized,
                        axHandle: AXWindowHandle(axWindow.element)
                    )
                )
            }
        }

        // Return in recency order — front-most first — using the window-server z-order as a proxy
        // for "most recently interacted with." (Geometry + owner pid don't require Screen Recording.)
        let z = onScreenZOrder()
        func rank(_ win: ManagedWindow) -> Int {
            var best = Int.max
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (i, e) in z.enumerated() where e.pid == win.pid {
                let d = abs(e.bounds.minX - win.frame.minX) + abs(e.bounds.minY - win.frame.minY)
                if d < bestDist { bestDist = d; best = i }
            }
            return best
        }
        return result.sorted { rank($0) < rank($1) }
    }

    /// On-screen windows in front-to-back order with their owner pid and bounds (CG top-left).
    private func onScreenZOrder() -> [(pid: pid_t, bounds: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let b = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { return nil }
            return (pid, CGRect(x: x, y: y, width: w, height: h))
        }
    }
}
