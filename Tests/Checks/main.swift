import Foundation
import CoreGraphics
import ApplicationServices
import TesseraCore

// A tiny zero-dependency assertion harness. `swift test` needs the XCTest/Testing runtime, which a
// Command Line Tools-only install doesn't ship — so checks run as a plain executable instead:
//     swift run TesseraChecks
// Exits non-zero if any check fails, so it works in CI and the build scripts.

var failures = 0
var passed = 0

// Top-level code in an executable's main.swift is @MainActor-isolated under Swift 6, so the helper
// that mutates the counters must share that isolation.
@MainActor
func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
    } else {
        failures += 1
        FileHandle.standardError.write(Data("✗ \(name)\n".utf8))
    }
}

func approxEqual(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.0001) -> Bool { abs(a - b) < tol }

// MARK: - CoordinateConverter

let H: CGFloat = 1440

do {
    let appKit = CGPoint(x: 200, y: 300)
    let cg = CoordinateConverter.appKitToCG(point: appKit, primaryHeight: H)
    let back = CoordinateConverter.cgToAppKit(point: cg, primaryHeight: H)
    check(approxEqual(back.x, appKit.x) && approxEqual(back.y, appKit.y), "point round-trips")
    check(approxEqual(cg.y, 1140), "point Y flips about primary height (300 up -> 1140 down)")
}

do {
    let appKit = CGRect(x: 100, y: 50, width: 400, height: 600)
    let cg = CoordinateConverter.appKitToCG(rect: appKit, primaryHeight: H)
    let back = CoordinateConverter.cgToAppKit(rect: cg, primaryHeight: H)
    check(
        approxEqual(back.origin.x, appKit.origin.x) && approxEqual(back.origin.y, appKit.origin.y)
            && approxEqual(back.width, appKit.width) && approxEqual(back.height, appKit.height),
        "rect round-trips"
    )
}

do {
    let appKit = CGRect(x: 0, y: 0, width: 400, height: 600)
    let cg = CoordinateConverter.appKitToCG(rect: appKit, primaryHeight: H)
    check(approxEqual(cg.origin.y, 840) && approxEqual(cg.origin.x, 0), "bottom-left rect maps to correct top-left")
}

do {
    let appKit = CGRect(x: 0, y: 0, width: 800, height: H)
    let cg = CoordinateConverter.appKitToCG(rect: appKit, primaryHeight: H)
    check(approxEqual(cg.origin.y, 0), "full-height window anchored at CG top")
}

// MARK: - DisplayInfo signature

do {
    let d = DisplayInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415),
        backingScale: 2,
        isPrimary: true
    )
    check(d.signature == "2560x1440@0,0", "display signature is resolution-keyed")
}

// MARK: - FallbackTiler

// The default (built-in) catalog, used wherever a test needs category dimensions.
let cat = CategoryCatalog(profiles: CategoryStore.builtInProfiles())

func makeWindow(_ categoryId: String) -> ManagedWindow {
    ManagedWindow(
        pid: 1,
        appName: categoryId,
        bundleId: nil,
        title: "",
        categoryId: categoryId,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        isMinimized: false,
        axHandle: AXWindowHandle(AXUIElementCreateApplication(1))
    )
}

let display = DisplayInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415),
    backingScale: 2,
    isPrimary: true
)

do {
    let windows = [makeWindow("browser"), makeWindow("terminal"), makeWindow("chat")]
    let plan = FallbackTiler.plan(display: display, windows: windows, gap: 8, catalog: cat)
    check(plan.tiles.count == windows.count, "fallback produces one tile per window")
}

do {
    let windows = [makeWindow("browser"), makeWindow("editor"), makeWindow("terminal"), makeWindow("chat")]
    let plan = FallbackTiler.plan(display: display, windows: windows, gap: 8, catalog: cat)
    let allInside = plan.tiles.allSatisfy { display.visibleFrame.contains($0.frame) }
    check(allInside, "all fallback tiles stay within the usable area")
}

do {
    // A single window is capped in BOTH width and height to its category max, anchored top-left.
    let plan = FallbackTiler.plan(display: display, windows: [makeWindow("browser")], gap: 8, catalog: cat)
    let tile = plan.tiles[0]
    check(tile.frame.width <= cat.profile(id: "browser").maxWidth + 1, "single window width capped to category max")
    check(abs(tile.frame.minX - (display.visibleFrame.minX + 8)) < 0.01, "single window left-aligned")
    check(abs(tile.frame.minY - (display.visibleFrame.minY + 8)) < 0.01, "single window top-aligned")
}

// MARK: - Classification (via the catalog)

check(cat.categoryId(bundleId: "com.apple.Safari", appName: "Safari") == "browser", "Safari categorized as browser")
check(cat.categoryId(bundleId: "com.googlecode.iterm2", appName: "iTerm2") == "terminal", "iTerm categorized as terminal")
check(cat.categoryId(bundleId: nil, appName: "Some Slack Clone") == "chat", "name keyword falls back to chat")
check(cat.categoryId(bundleId: nil, appName: "Mystery App") == "other", "unknown app -> other")

// MARK: - Learned priors (folded in by the catalog)

do {
    let learned = LearnedDimensions(
        byBundle: ["com.acme.app": LearnedDims(widthFraction: 0.7, heightFraction: 0.9, samples: 3)],
        byCategory: ["terminal": LearnedDims(widthFraction: 0.25, heightFraction: 0.5, samples: 5)]
    )
    check(cat.widthPrior(id: "other", bundleId: "com.acme.app", learned: learned) == 0.7, "per-app learned prior wins")
    check(cat.widthPrior(id: "terminal", bundleId: "com.unknown", learned: learned) == 0.25, "falls back to per-category learned prior")
    check(
        approxEqual(CGFloat(cat.widthPrior(id: "browser", bundleId: nil, learned: .empty)), CGFloat(cat.profile(id: "browser").preferredWidthFraction)),
        "falls back to category default when nothing learned"
    )
}

// MARK: - Reflow: swap + resize

func makeTile(_ frame: CGRect, bundle: String? = nil, categoryId: String = "other") -> GridTile {
    GridTile(
        handle: AXWindowHandle(AXUIElementCreateApplication(1)),
        bundleId: bundle,
        categoryId: categoryId,
        appName: "test",
        target: frame
    )
}

do {
    let a = makeTile(CGRect(x: 0, y: 0, width: 100, height: 100))
    let b = makeTile(CGRect(x: 200, y: 0, width: 100, height: 100))
    let swapped = Reflow.swapped([a, b], 0, 1)
    check(swapped[0].target.origin.x == 200 && swapped[1].target.origin.x == 0, "swap exchanges target frames")
}

do {
    // Two side-by-side tiles with an 8pt gap; widen the left one by 100 → right one's left edge
    // tracks it and its width shrinks by 100, keeping the right edge fixed.
    let gap: CGFloat = 8
    let left = makeTile(CGRect(x: 0, y: 0, width: 500, height: 1000))
    let right = makeTile(CGRect(x: 508, y: 0, width: 492, height: 1000))   // minX = 500 + gap
    let oldFrame = left.target
    let newFrame = CGRect(x: 0, y: 0, width: 600, height: 1000)
    let out = Reflow.afterResize(tiles: [left, right], resizedIndex: 0, oldFrame: oldFrame, newFrame: newFrame, gap: gap)
    check(approxEqual(out[0].target.width, 600), "resized tile keeps its new width")
    check(approxEqual(out[1].target.minX, 608), "right neighbor's left edge follows the divider")
    check(approxEqual(out[1].target.maxX, 1000), "right neighbor keeps its right edge fixed")
}

do {
    let tiles = [
        makeTile(CGRect(x: 0, y: 0, width: 100, height: 100)),
        makeTile(CGRect(x: 200, y: 0, width: 100, height: 100)),
    ]
    check(Reflow.indexOfTile(containing: CGPoint(x: 250, y: 50), in: tiles) == 1, "indexOfTile finds the containing tile")
    check(Reflow.indexOfTile(containing: CGPoint(x: 150, y: 50), in: tiles) == nil, "indexOfTile returns nil in a gap")
}

do {
    // Title-bar gate: a swap source must be grabbed from the top strip, not the content area.
    let tiles = [
        makeTile(CGRect(x: 0, y: 0, width: 500, height: 800)),     // tile 0
        makeTile(CGRect(x: 520, y: 0, width: 500, height: 800)),   // tile 1
    ]
    // A point in tile 0's title bar (y < 30) → recognized as a window grab.
    check(Reflow.indexOfTile(titleBarContaining: CGPoint(x: 100, y: 10), in: tiles) == 0,
          "title-bar grab in the top strip is detected")
    // A point deep in tile 0's content (y = 400, like a file icon) → NOT a window grab.
    check(Reflow.indexOfTile(titleBarContaining: CGPoint(x: 100, y: 400), in: tiles) == nil,
          "a drag starting in the content area is not a title-bar grab (no swap)")
}

// MARK: - Max-width caps (don't over-stretch; left-align)

do {
    // A single terminal on a very wide display must NOT fill the screen — cap ~1200pt, left-aligned.
    let wide = DisplayInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 3840, height: 1600),
        visibleFrame: CGRect(x: 0, y: 25, width: 3840, height: 1575),
        backingScale: 2, isPrimary: true
    )
    let win = ManagedWindow(pid: 1, appName: "iTerm2", bundleId: nil, title: "", categoryId: "terminal",
                            frame: .zero, isMinimized: false, axHandle: AXWindowHandle(AXUIElementCreateApplication(1)))
    let plan = FallbackTiler.plan(display: wide, windows: [win], gap: 8, catalog: cat)
    let t = plan.tiles[0]
    check(t.frame.width <= cat.profile(id: "terminal").maxWidth + 1, "single terminal capped to max reasonable width")
    check(t.frame.width < wide.visibleFrame.width - 1000, "single terminal leaves lots of empty desktop")
    check(abs(t.frame.minX - (wide.visibleFrame.minX + 8)) < 0.01, "single window is left-aligned (not centered)")
}

do {
    // maxWidth helper: default caps at category ceiling; a learned wide preference raises it.
    let usable: CGFloat = 4000
    check(cat.maxWidth(id: "terminal", bundleId: nil, usableWidth: usable, learned: .empty) == cat.profile(id: "terminal").maxWidth,
          "default max width is the category ceiling")
    let wideLearned = LearnedDimensions(byBundle: [:], byCategory: ["terminal": LearnedDims(widthFraction: 0.6, heightFraction: 0.9, samples: 8)])
    check(cat.maxWidth(id: "terminal", bundleId: nil, usableWidth: usable, learned: wideLearned) > cat.profile(id: "terminal").maxWidth,
          "a learned wide preference raises the ceiling")
}

do {
    // Height caps: Slack (chat) on a tall display must NOT run the full height; ~1100pt, top-aligned.
    let tall = DisplayInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 5120, height: 2160),
        visibleFrame: CGRect(x: 0, y: 37, width: 5120, height: 2123),
        backingScale: 2, isPrimary: true
    )
    let slack = ManagedWindow(pid: 1, appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", title: "",
                              categoryId: "chat", frame: .zero, isMinimized: false,
                              axHandle: AXWindowHandle(AXUIElementCreateApplication(1)))
    let plan = FallbackTiler.plan(display: tall, windows: [slack], gap: 8, catalog: cat)
    let t = plan.tiles[0]
    check(t.frame.height <= cat.profile(id: "chat").maxHeight + 1, "Slack height capped to chat max")
    check(t.frame.height < tall.visibleFrame.height - 800, "Slack leaves lots of empty desktop below")
    check(abs(t.frame.minY - (tall.visibleFrame.minY + 8)) < 0.01, "Slack top-aligned")
    // Chat is now wider than before (was 560) but still capped.
    check(t.frame.width <= cat.profile(id: "chat").maxWidth + 1, "chat width within its (now wider) max")
    check(cat.profile(id: "chat").maxWidth >= 900, "chat max width widened for channel list + stream")
}

// MARK: - Custom category generation (offline heuristic path)

do {
    // With no API key the generator returns a usable heuristic profile whose keywords map the
    // example apps to the new category.
    let store = CategoryStore()
    let profile = await store.generateCategory(name: "Whiteboard", exampleApps: ["Miro", "FigJam"])
    check(!profile.isBuiltIn, "generated category is custom")
    check(profile.keywords.contains("miro"), "example apps become matching keywords")
    check(profile.maxWidth > 0 && profile.maxHeight > 0, "generated profile has sane dimensions")
    let withNew = CategoryCatalog(profiles: cat.profiles + [profile])
    check(withNew.categoryId(bundleId: nil, appName: "Miro") == profile.id, "an example app classifies to the new category")
}

// MARK: - Token usage + pricing

do {
    let a = TokenUsage(input: 100, output: 50)
    let b = TokenUsage(input: 10, output: 5)
    check((a + b).input == 110 && (a + b).output == 55, "TokenUsage adds component-wise")
    check(a.total == 150, "TokenUsage total = input + output")
    check(TokenUsage.zero.isZero, "zero usage is zero")
}

do {
    // Default pricing: 1M in + 1M out on Opus 4.8 = $5 + $25 = $30.
    let oneM = TokenUsage(input: 1_000_000, output: 1_000_000)
    check(abs(ModelPricing.cost(oneM, model: "claude-opus-4-8") - 30) < 0.001, "Opus default cost = $30 for 1M+1M")
    check(abs(ModelPricing.cost(oneM, model: "claude-sonnet-4-6") - 18) < 0.001, "Sonnet default cost = $18 for 1M+1M")
    check(abs(ModelPricing.cost(oneM, model: "claude-haiku-4-5") - 6) < 0.001, "Haiku default cost = $6 for 1M+1M")
}

do {
    // Runtime overrides (what the weekly pricing refresh writes) take effect.
    ModelPricing.overrides = ["claude-opus-4-8": (input: 8, output: 40)]
    let oneM = TokenUsage(input: 1_000_000, output: 1_000_000)
    check(abs(ModelPricing.cost(oneM, model: "claude-opus-4-8") - 48) < 0.001, "pricing override is applied")
    ModelPricing.overrides = [:]
    check(abs(ModelPricing.cost(oneM, model: "claude-opus-4-8") - 30) < 0.001, "clearing overrides restores default")
}

// MARK: - Report

print("Tessera checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
