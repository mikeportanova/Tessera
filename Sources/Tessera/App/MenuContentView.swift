import SwiftUI
import TesseraCore

/// The menu-bar popover: tiling actions, the auto-vs-manual control, snap/reflow, the AI budget,
/// and save/restore. Configuration (API key, model, limits) lives in the Preferences window.
/// Styled for macOS 26 (Tahoe).
struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var engine: TilingEngine
    @EnvironmentObject private var rateLimiter: RateLimiter
    @EnvironmentObject private var updateChecker: UpdateChecker

    @Environment(\.openSettings) private var openSettings

    @State private var newLayoutName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !permissions.accessibilityTrusted {
                permissionsBanner
            }
            if case let .needsApproval(used, max) = engine.status {
                approvalBanner(used: used, max: max)
            }
            if case let .failed(message) = engine.status {
                failureBanner(message)
            }

            tileButton

            arrangeSection
            layoutsSection
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text("Tessera").font(.headline)
                Text("AI window tiling").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch engine.status {
        case .idle:
            EmptyView()
        case .planning:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Tiling…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .applied(moved):
            pill("Moved \(moved)", color: .green, symbol: "checkmark.circle.fill")
        case .needsApproval:
            pill("AI paused", color: .orange, symbol: "hand.raised.fill")
        case .failed:
            pill("Error", color: .red, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func pill(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: - Banners

    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility access needed", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Tessera can't move windows until you enable it in System Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
                .glassButton()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func failureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tiling problem", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func approvalBanner(used: Int, max: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI limit reached", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Used \(used) of \(max) AI layouts this hour. Approve more, or raise the limit in Preferences.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow 5 more this hour") { model.approveExtraAICalls() }
                .glassButton()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: - Primary action

    private var tileButton: some View {
        HStack(spacing: 8) {
            Button {
                model.tileNow()
            } label: {
                Label(settings.offlineMode ? "Tile Now (offline)" : "Tile Now",
                      systemImage: settings.offlineMode ? "square.grid.2x2" : "wand.and.stars")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .prominentGlassButton()
            .disabled(!permissions.accessibilityTrusted || engine.status == .planning)

            if engine.canUndo {
                Button {
                    model.undoLastLayout()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body.weight(.medium))
                }
                .controlSize(.large)
                .glassButton()
                .help("Undo the last layout (⌃⌥⌘Z)")
            }
        }
    }

    // MARK: - Arrange section

    private var arrangeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Arranging", symbol: "slider.horizontal.3")

            Picker(selection: $settings.intent) {
                ForEach(LayoutIntent.allCases, id: \.self) { intent in
                    Label(intent.displayName, systemImage: intent.symbolName).tag(intent)
                }
            } label: {
                Label("Focus", systemImage: "scope")
            }
            .pickerStyle(.menu)
            .help("Tell the layout engine what you're doing — coding keeps the editor big, communication puts chat front and center.")

            Toggle(isOn: $settings.autoArrange) {
                Label("Auto-tile when windows open", systemImage: "sparkles")
            }
            .help("When on, opening a new window re-tiles using the fast built-in tiler (no AI, no token cost). Use Tile Now for an AI layout.")

            Toggle(isOn: $settings.snapEnabled) {
                Label("Drag-to-swap & resize reflow", systemImage: "arrow.left.arrow.right.square")
            }
            .help("Drag a window onto another tile to swap them; resize a tile to reflow its neighbors. No AI used.")

            Toggle(isOn: $settings.offlineMode) {
                Label("Offline mode (no AI)", systemImage: "wifi.slash")
            }
            .help("Never call Claude — even Tile Now uses the built-in tiler. Zero cost, no network.")

            Toggle(isOn: $settings.contentAware) {
                Label("Content-aware (screenshot)", systemImage: "camera.viewfinder")
            }
            .help("Lets the AI arrange by on-screen content. Requires Screen Recording permission.")
            .disabled(settings.offlineMode)

            HStack(spacing: 10) {
                Label("Gap", systemImage: "square.dashed")
                Slider(value: $settings.gap, in: 0...40, step: 2)
                Text("\(Int(settings.gap))pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            aiBudget
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private var aiBudget: some View {
        if settings.offlineMode {
            Label("Offline mode — built-in tiler only, no tokens used.", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if settings.hasAPIKey {
            HStack(spacing: 8) {
                Label("AI this hour", systemImage: "brain")
                    .font(.caption).foregroundStyle(.secondary)
                Gauge(value: Double(rateLimiter.callsInLastHour), in: 0...Double(max(1, settings.maxAICallsPerHour))) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(rateLimiter.callsInLastHour >= settings.maxAICallsPerHour ? .orange : .accentColor)
                Text("\(rateLimiter.callsInLastHour)/\(settings.maxAICallsPerHour)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("No API key — using the built-in tiler. Add a key in Preferences for AI layouts.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Layouts section

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Saved layouts", symbol: "square.stack.3d.up")

            HStack {
                TextField("Name a layout to save", text: $newLayoutName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.saveLayout(named: newLayoutName)
                    newLayoutName = ""
                }
                .glassButton()
                .disabled(newLayoutName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.savedLayoutNames.isEmpty {
                Text("Save the current arrangement to restore it later — no AI call needed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.savedLayoutNames, id: \.self) { name in
                        layoutRow(name)
                    }
                }
            }
        }
    }

    private func layoutRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.caption).foregroundStyle(.secondary)
            Text(name).lineLimit(1)
            Spacer()
            Button("Restore") { model.restoreLayout(named: name) }
                .controlSize(.small)
                .buttonStyle(.borderless)
            Button(role: .destructive) { model.deleteLayout(named: name) } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Delete \(name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let version = updateChecker.availableVersion {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("Tessera \(version) is available")
                    Spacer()
                    switch updateChecker.phase {
                    case .downloading, .installing, .relaunching:
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(updatePhaseLabel).foregroundStyle(.secondary)
                        }
                    default:
                        if updateChecker.dmgURL != nil {
                            Button("Update Now") { Task { await updateChecker.updateNow() } }
                                .font(.callout.weight(.medium))
                                .buttonStyle(.borderless)
                        } else if let url = updateChecker.releaseURL {
                            Link("Get it", destination: url).font(.callout.weight(.medium))
                        }
                    }
                }
                if case let .failed(message) = updateChecker.phase {
                    HStack(spacing: 6) {
                        Text(message).foregroundStyle(.secondary).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = updateChecker.releaseURL {
                            Link("Open release page", destination: url).font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint.opacity(0.12)))
        }
        HStack {
            Button { openSettings() } label: {
                Label("Preferences", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.callout)
    }

    private var updatePhaseLabel: String {
        switch updateChecker.phase {
        case .downloading:  return "Downloading…"
        case .installing:   return "Installing…"
        case .relaunching:  return "Relaunching…"
        default:            return ""
        }
    }
}
