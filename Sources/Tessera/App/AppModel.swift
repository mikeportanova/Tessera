import Foundation
import AppKit
import Combine
import ServiceManagement
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
    public let appRules: AppRulesStore
    public let updateChecker: UpdateChecker
    private let autoArrange: AutoArrangeCoordinator
    private let dragInteractions: DragInteractionManager
    private let hotKey = HotKeyManager()
    private var cancellables: Set<AnyCancellable> = []

    @Published public var savedLayoutNames: [String] = []

    /// Mirrors `SMAppService.mainApp` so the Preferences toggle can bind to it.
    @Published public var launchAtLogin: Bool = false {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[Tessera] launch-at-login change failed: \(error.localizedDescription)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    public init() {
        let settings = AppSettings()
        let permissions = PermissionsManager()
        let dimensionMemory = DimensionMemory()
        let rateLimiter = RateLimiter(maxPerHour: settings.maxAICallsPerHour)
        let categoryStore = CategoryStore()
        let usageTracker = UsageTracker()
        let pricingStore = PricingStore()
        let appRules = AppRulesStore()
        let engine = TilingEngine(settings: settings, rateLimiter: rateLimiter, dimensionMemory: dimensionMemory, categoryStore: categoryStore, usageTracker: usageTracker, appRules: appRules)
        self.settings = settings
        self.permissions = permissions
        self.dimensionMemory = dimensionMemory
        self.rateLimiter = rateLimiter
        self.categoryStore = categoryStore
        self.usageTracker = usageTracker
        self.pricingStore = pricingStore
        self.appRules = appRules
        self.updateChecker = UpdateChecker()
        self.engine = engine
        self.autoArrange = AutoArrangeCoordinator(engine: engine, settings: settings)
        self.dragInteractions = DragInteractionManager(engine: engine, settings: settings)
        categoryStore.usageTracker = usageTracker
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
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
        updateChecker.checkIfStale()    // weekly release check

        // Global hotkeys: Tile Now, Magnet-style quick snaps, and undo — re-registered whenever the
        // user changes the tile shortcut or the quick-snap toggle.
        hotKey.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .tile:      self.tileNow()
            case .leftHalf:  self.engine.quickSnap(.leftHalf)
            case .rightHalf: self.engine.quickSnap(.rightHalf)
            case .maximize:  self.engine.quickSnap(.maximize)
            case .undo:      self.engine.undoLastLayout()
            }
        }
        settings.$tileShortcut
            .combineLatest(settings.$quickSnapShortcuts)
            .sink { [weak self] shortcut, quickSnap in
                self?.hotKey.apply(tileShortcut: shortcut, quickSnapEnabled: quickSnap)
            }
            .store(in: &cancellables)

        // Live gap: dragging the gap slider re-applies the current layout immediately via the fast
        // offline tiler (no LLM, no token cost) — no need to press Tile Now again.
        // NOTE: use DispatchQueue.main (not RunLoop.main) so updates are delivered *during* the
        // slider's mouse-tracking loop, and throttle (not debounce) so it updates continuously as
        // the slider moves rather than only after release. Only fires when something is tiled.
        settings.$gap
            .dropFirst()
            .removeDuplicates()
            .throttle(for: .milliseconds(140), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.engine.hasActiveLayout else { return }
                Task { await self.engine.retile(useAI: false, interactive: false) }
            }
            .store(in: &cancellables)

        refreshSavedLayouts()
    }

    public func approveExtraAICalls() {
        engine.approveExtraAICalls()
    }

    /// Flush debounced writes so a quick quit can't drop a recent edit.
    public func shutdown() {
        categoryStore.flush()
        dimensionMemory.flush()
    }

    // MARK: - Actions exposed to the menu

    public func tileNow() {
        Task { await engine.retile(useAI: !settings.offlineMode) }
    }

    public func undoLastLayout() {
        engine.undoLastLayout()
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
