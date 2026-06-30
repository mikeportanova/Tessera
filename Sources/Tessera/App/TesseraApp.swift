import SwiftUI
import AppKit
import TesseraCore

@main
struct TesseraApp: App {
    // The app delegate owns the model so startup logic runs at launch — a MenuBarExtra's content
    // view (and any `.task` on it) isn't created until the user first opens the popover.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Tessera", systemImage: "rectangle.grid.2x2") {
            MenuContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.settings)
                .environmentObject(delegate.model.permissions)
                .environmentObject(delegate.model.engine)
                .environmentObject(delegate.model.rateLimiter)
        }
        .menuBarExtraStyle(.window)

        // Standard Preferences window (⌘, / "Preferences…"), where any user enters their own key.
        Settings {
            PreferencesView()
                .environmentObject(delegate.model.settings)
                .environmentObject(delegate.model.dimensionMemory)
                .environmentObject(delegate.model.categoryStore)
                .environmentObject(delegate.model.usageTracker)
                .environmentObject(delegate.model.pricingStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
