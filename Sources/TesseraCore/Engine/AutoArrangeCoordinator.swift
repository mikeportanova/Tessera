import Foundation
import AppKit

/// Bridges window-change events from `AXObserverManager` to the `TilingEngine`, debouncing bursts
/// (a single app launch can emit several window/focus events in quick succession) and only acting
/// when the user has auto-arrange enabled.
@MainActor
public final class AutoArrangeCoordinator {

    private let observerManager = AXObserverManager()
    private let engine: TilingEngine
    private let settings: AppSettings

    private var retileTask: Task<Void, Never>?
    private var reflowTask: Task<Void, Never>?
    /// Auto re-tile debounce — generous, since a single app launch emits several events. The auto
    /// path uses the offline tiler (no LLM), so this only coalesces bursts.
    private let retileDebounce: Duration = .milliseconds(400)
    /// Reflow (local) debounce — short, since it's cheap and should feel responsive.
    private let reflowDebounce: Duration = .milliseconds(150)

    public init(engine: TilingEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {
        observerManager.onWindowsChanged = { [weak self] in
            self?.scheduleRetile()
        }
        observerManager.onWindowGeometryChanged = { [weak self] in
            self?.scheduleReflow()
        }
        observerManager.start()
    }

    public func stop() {
        observerManager.stop()
        retileTask?.cancel(); retileTask = nil
        reflowTask?.cancel(); reflowTask = nil
    }

    /// New/closed window → AI re-tile, only when auto-arrange is on.
    private func scheduleRetile() {
        guard settings.autoArrange else { return }
        retileTask?.cancel()
        retileTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.retileDebounce)
            guard !Task.isCancelled, self.settings.autoArrange else { return }
            // Auto re-tiles use the free, fast offline tiler — never the LLM.
            await self.engine.retile(useAI: false)
        }
    }

    /// Window moved/resized → local neighbor reflow, only when snapping is on. Never calls the LLM.
    private func scheduleReflow() {
        guard settings.snapEnabled else { return }
        reflowTask?.cancel()
        reflowTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.reflowDebounce)
            guard !Task.isCancelled, self.settings.snapEnabled else { return }
            self.engine.handleGeometryChange()
        }
    }
}
