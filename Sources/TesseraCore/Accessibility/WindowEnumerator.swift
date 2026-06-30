import Foundation
import AppKit
import ApplicationServices

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
        return result
    }
}
