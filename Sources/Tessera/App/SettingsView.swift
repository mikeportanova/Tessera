import SwiftUI
import TesseraCore

/// The Preferences window (⌘, / "Preferences…"), organized into tabs.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs()
                .tabItem { Label("General", systemImage: "gearshape") }
            UsagePrefs()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            CategoriesPrefs()
                .tabItem { Label("Categories", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 580)
    }
}

// MARK: - General

private struct GeneralPrefs: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dimensionMemory: DimensionMemory

    @State private var apiKeyField: String = ""
    @State private var savedConfirmation = false

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField(settings.hasAPIKey ? "•••••••••••• (stored in Keychain)" : "sk-ant-…", text: $apiKeyField)
                    Button("Save") {
                        settings.updateAPIKey(apiKeyField); apiKeyField = ""; savedConfirmation = true
                    }
                    .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    if settings.hasAPIKey {
                        Button("Remove") { settings.updateAPIKey(""); savedConfirmation = false }
                    }
                }
                Text(settings.hasAPIKey
                     ? (savedConfirmation ? "Key saved to your Keychain." : "A key is stored in your Keychain.")
                     : "Without a key, Tessera uses its built-in layout algorithm instead of the AI.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Anthropic API key", systemImage: "key.horizontal") }

            Section("Model") {
                Picker("Layout model", selection: $settings.model) {
                    ForEach(PlannerModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(!settings.hasAPIKey)
            }

            Section("Global shortcut") {
                Picker("Tile now", selection: $settings.tileShortcut) {
                    ForEach(TileShortcut.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Press this anywhere to re-tile — handy when auto-arrange is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("AI budget") {
                Stepper(value: $settings.maxAICallsPerHour, in: 1...200) {
                    Text("Max AI layouts per hour: \(settings.maxAICallsPerHour)")
                }
                Text("When exceeded, Tessera pauses and asks for approval before calling the AI again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Learned dimensions") {
                HStack {
                    Text("Samples learned: \(dimensionMemory.sampleCount)")
                    Spacer()
                    Button("Forget all", role: .destructive) { dimensionMemory.reset() }
                        .disabled(dimensionMemory.sampleCount == 0)
                }
                Text("Tessera remembers how you size each app and feeds it back into future layouts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Usage

private struct UsagePrefs: View {
    @EnvironmentObject private var usage: UsageTracker
    @EnvironmentObject private var pricing: PricingStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            if !settings.hasAPIKey {
                Section {
                    Label("No API key — using the built-in tiler", systemImage: "bolt.slash")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("Tilings are running on Tessera's offline algorithm, which uses no tokens — so nothing is tracked here. Add an Anthropic API key in the General tab to enable AI layouts and usage tracking.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if usage.events.isEmpty {
                Section {
                    Text("No AI tilings yet. Trigger “Tile Now” (or open a window with auto-arrange on) and this fills in.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                // The headline metric the user asked for: average TOKENS per tiling.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(usage.avgTokensPerTiling.formatted()) tokens")
                            .font(.system(.title, design: .rounded).weight(.semibold))
                        Text("average per tiling")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(usage.tilingCountLast24h)").font(.title3.weight(.medium))
                        Text("tilings · 24h").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Label("Average tiling cost", systemImage: "wand.and.stars") }

            Section("Last 24 hours") {
                LabeledContent("Input tokens", value: usage.usageLast24h.input.formatted())
                LabeledContent("Output tokens", value: usage.usageLast24h.output.formatted())
                LabeledContent("Total tokens", value: usage.usageLast24h.total.formatted())
                LabeledContent("Estimated cost", value: usd(usage.costLast24h))
            }

            Section {
                ForEach(PricingStore.trackedModels, id: \.self) { model in
                    let p = pricing.effectivePrice(for: model)
                    LabeledContent(modelName(model)) {
                        Text("$\(p.input, specifier: "%.2f") in · $\(p.output, specifier: "%.2f") out / Mtok")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Text(pricing.lastFetched.map { "Updated \($0.formatted(.relative(presentation: .named)))" }
                         ?? "Using built-in prices")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await pricing.refresh() }
                    } label: {
                        if pricing.isRefreshing { ProgressView().controlSize(.small) }
                        else { Text("Update now") }
                    }
                    .disabled(pricing.isRefreshing)
                }
            } header: { Label("Token pricing", systemImage: "dollarsign.circle") } footer: {
                Text("Prices refresh automatically about once a week from Anthropic.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func usd(_ v: Double) -> String {
        v < 0.01 && v > 0 ? "< $0.01" : String(format: "$%.2f", v)
    }
    private func modelName(_ id: String) -> String {
        PlannerModel(rawValue: id)?.displayName ?? id
    }
}

// MARK: - Categories (master-detail, no accordions)

private struct CategoriesPrefs: View {
    @EnvironmentObject private var categories: CategoryStore
    @State private var selection: String?
    @State private var showingNew = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .sheet(isPresented: $showingNew) { NewCategorySheet(onCreate: { selection = $0 }) }
        .onAppear { if selection == nil { selection = categories.profiles.first?.id } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(categories.profiles) { profile in
                    HStack {
                        Image(systemName: profile.isBuiltIn ? "square.grid.2x2" : "star")
                            .foregroundStyle(profile.isBuiltIn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            .font(.caption)
                        Text(profile.name).lineLimit(1)
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button { showingNew = true } label: {
                Label("New Category", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 190)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, categories.profiles.contains(where: { $0.id == id }) {
            CategoryDetail(categoryId: id)
                .id(id)   // reset field focus when switching categories
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a category").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CategoryDetail: View {
    @EnvironmentObject private var categories: CategoryStore
    let categoryId: String

    private var profile: CategoryProfile {
        categories.profiles.first { $0.id == categoryId }
            ?? CategoryProfile(id: categoryId, name: categoryId, preferredWidthFraction: 0.4,
                               minWidth: 320, maxWidth: 1400, minHeight: 220, maxHeight: 1500)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SizePreview(profile: profile)
                sizing
                matches
                Spacer(minLength: 0)
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name).font(.title2.weight(.semibold))
            Text(profile.isBuiltIn ? "Built-in category" : "Custom category")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sizing: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderRow("Preferred width", value: bind(\.preferredWidthFraction),
                      range: 0.1...0.7, display: "\(Int(profile.preferredWidthFraction * 100))%")
            rangeRow("Width", min: bind(\.minWidth), max: bind(\.maxWidth), bound: 300...4000)
            rangeRow("Height", min: bind(\.minHeight), max: bind(\.maxHeight), bound: 200...3000)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(display).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
        }
    }

    private func rangeRow(_ label: String, min: Binding<CGFloat>, max: Binding<CGFloat>, bound: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 120, alignment: .leading)
            Stepper(value: min, in: bound, step: 20) {
                Text("min \(Int(min.wrappedValue))pt").monospacedDigit()
            }
            Stepper(value: max, in: bound, step: 20) {
                Text("max \(Int(max.wrappedValue))pt").monospacedDigit()
            }
        }
    }

    private var matches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MATCHES APPS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.5)
            if profile.keywords.isEmpty && profile.bundleIds.isEmpty {
                Text("Fallback for anything that doesn't match another category.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(profile.keywords.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            Spacer()
            if profile.isBuiltIn {
                Button("Reset to default") { categories.resetToDefault(id: profile.id) }
            } else {
                Button("Delete category", role: .destructive) { categories.delete(id: profile.id) }
            }
        }
    }

    /// Two-way binding to one field of this profile that writes the whole profile back to the store.
    private func bind<V>(_ keyPath: WritableKeyPath<CategoryProfile, V>) -> Binding<V> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in
                var p = profile
                p[keyPath: keyPath] = newValue
                categories.update(p)
            }
        )
    }
}

/// A little to-scale diagram showing how big this category's window is relative to the user's own
/// display — the board matches the current screen's aspect ratio, and the window rectangles are
/// scaled against its real point dimensions (the same coordinate space the tiler works in).
private struct SizePreview: View {
    let profile: CategoryProfile

    /// The current display's size in points. Falls back to a common 16:9 size if unavailable.
    private var screen: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1440)
    }

    var body: some View {
        let screen = self.screen
        GeometryReader { geo in
            // Fit a to-scale board with the display's aspect ratio into the available area.
            let scale = Swift.min(geo.size.width / screen.width, geo.size.height / screen.height)
            let boardW = screen.width * scale
            let boardH = screen.height * scale
            let maxW = Swift.min(profile.maxWidth, screen.width) * scale
            let maxH = Swift.min(profile.maxHeight, screen.height) * scale
            let minW = Swift.min(Swift.min(profile.minWidth, screen.width) * scale, maxW)
            let minH = Swift.min(Swift.min(profile.minHeight, screen.height) * scale, maxH)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4))
                    .frame(width: boardW, height: boardH)
                RoundedRectangle(cornerRadius: 3).fill(.tint.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.tint, lineWidth: 1))
                    .frame(width: maxW, height: maxH)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(.tint.opacity(0.7))
                    .frame(width: minW, height: minH)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(height: 150)
        .overlay(alignment: .bottomTrailing) {
            Text("filled = max · dashed = min, on your \(Int(screen.width))×\(Int(screen.height)) display")
                .font(.caption2).foregroundStyle(.secondary).padding(4)
        }
    }
}

private struct NewCategorySheet: View {
    @EnvironmentObject private var categories: CategoryStore
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var apps = ""
    @State private var generating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Category").font(.headline)
            Text("Name it and list a few example apps. Tessera asks the AI to infer sensible window sizing for apps like those.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Category name (e.g. Whiteboards)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Example apps, comma-separated (e.g. Miro, FigJam)", text: $apps).textFieldStyle(.roundedBorder)

            HStack {
                if generating { ProgressView().controlSize(.small); Text("Generating…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(generating || name.trimmingCharacters(in: .whitespaces).isEmpty || appList.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var appList: [String] {
        apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func generate() {
        generating = true
        Task {
            let profile = await categories.generateCategory(name: name, exampleApps: appList)
            categories.update(profile)
            generating = false
            onCreate(profile.id)
            dismiss()
        }
    }
}
