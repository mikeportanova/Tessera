import Foundation
import AppKit
import Combine
import TesseraCore

/// Root object that owns Tessera's long-lived collaborators and wires up lifecycle. Created once by
/// `TesseraApp` and shared into the SwiftUI views.
@MainActor
public final class AppModel: ObservableObject {
    public let settings: AppSettings
    public let permissions: PermissionsManager
    public let engine: TilingEngine
    public let dimensionMemory: DimensionMemory
    public let rateLimiter: RateLimiter
    public let categoryStore: CategoryStore
    public let usageTracker: UsageTracker
    public let pricingStore: PricingStore
    private let autoArrange: AutoArrangeCoordinator
    private let dragInteractions: DragInteractionManager
    private let hotKey = HotKeyManager()
    private var cancellables: Set<AnyCancellable> = []

    @Published public var savedLayoutNames: [String] = []

    public init() {
        let settings = AppSettings()
        let permissions = PermissionsManager()
        let dimensionMemory = DimensionMemory()
        let rateLimiter = RateLimiter(maxPerHour: settings.maxAICallsPerHour)
        let categoryStore = CategoryStore()
        let usageTracker = UsageTracker()
        let pricingStore = PricingStore()
        let engine = TilingEngine(settings: settings, rateLimiter: rateLimiter, dimensionMemory: dimensionMemory, categoryStore: categoryStore, usageTracker: usageTracker)
        self.settings = settings
        self.permissions = permissions
        self.dimensionMemory = dimensionMemory
        self.rateLimiter = rateLimiter
        self.categoryStore = categoryStore
        self.usageTracker = usageTracker
        self.pricingStore = pricingStore
        self.engine = engine
        self.autoArrange = AutoArrangeCoordinator(engine: engine, settings: settings)
        self.dragInteractions = DragInteractionManager(engine: engine, settings: settings)
        categoryStore.usageTracker = usageTracker
    }

    /// Called once at launch.
    public func start() {
        // Belt-and-suspenders: the packaged app sets LSUIElement, but when run via `swift run`
        // there's no Info.plist, so enforce the agent (no-Dock) policy at runtime too.
        NSApp.setActivationPolicy(.accessory)

        permissions.refresh()
        if !permissions.accessibilityTrusted {
            permissions.requestAccessibility()
        }
        autoArrange.start()
        dragInteractions.start()
        pricingStore.refreshIfStale()   // weekly token-pricing refresh

        // Global "Tile Now" hotkey — re-registers whenever the user picks a different shortcut.
        hotKey.onPressed = { [weak self] in self?.tileNow() }
        settings.$tileShortcut
            .sink { [weak self] shortcut in self?.hotKey.apply(shortcut) }
            .store(in: &cancellables)

        refreshSavedLayouts()
    }

    public func approveExtraAICalls() {
        engine.approveExtraAICalls()
    }

    // MARK: - Actions exposed to the menu

    public func tileNow() {
        Task { await engine.retile() }
    }

    public func saveLayout(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.saveCurrentLayout(name: trimmed)
        refreshSavedLayouts()
    }

    public func restoreLayout(named name: String) {
        engine.restoreLayout(name: name)
    }

    public func deleteLayout(named name: String) {
        engine.deleteLayout(name: name)
        refreshSavedLayouts()
    }

    public func refreshSavedLayouts() {
        savedLayoutNames = engine.savedLayoutNames()
    }
}
