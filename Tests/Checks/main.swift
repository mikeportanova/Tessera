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
    // Chat's min width is generous (sidebar + thread), and the offline tiler honors it even on a
    // small display rather than squeezing the window below it.
    check(cat.profile(id: "chat").minWidth >= 600, "chat category min width is generous")
    let small = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                            visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775),
                            backingScale: 2, isPrimary: true)
    let browser = makeWindow("browser")
    let chat = makeWindow("chat")
    let plan = FallbackTiler.plan(display: small, windows: [browser, chat], gap: 8, catalog: cat)
    let chatTile = plan.tiles.first { $0.windowId == chat.id }!
    check(chatTile.frame.width >= cat.profile(id: "chat").minWidth - 0.5,
          "chat keeps at least its min width on a small display")
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
    // 2×2 grid, 8pt gaps on a 1008×1008 area. Drag the top-left window's bottom-right corner:
    // widen +100 and grow +80 taller. The vertical divider (x≈500) and horizontal divider (y≈500)
    // both move, so ALL three neighbors — including the diagonal (bottom-right) — must resize.
    let gap: CGFloat = 8
    let tl = makeTile(CGRect(x: 0,   y: 0,   width: 500, height: 500))   // 0 resized
    let tr = makeTile(CGRect(x: 508, y: 0,   width: 500, height: 500))   // 1 right
    let bl = makeTile(CGRect(x: 0,   y: 508, width: 500, height: 500))   // 2 below
    let br = makeTile(CGRect(x: 508, y: 508, width: 500, height: 500))   // 3 diagonal
    let oldFrame = tl.target
    let newFrame = CGRect(x: 0, y: 0, width: 600, height: 580)           // divider → x=600, y=580
    let out = Reflow.afterResize(tiles: [tl, tr, bl, br], resizedIndex: 0, oldFrame: oldFrame, newFrame: newFrame, gap: gap)

    // Right neighbor: left edge follows the vertical divider AND bottom edge follows the horizontal one.
    check(approxEqual(out[1].target.minX, 608), "top-right left edge tracks the vertical divider")
    check(approxEqual(out[1].target.maxY, 580), "top-right bottom edge tracks the horizontal divider")
    // Below neighbor: top edge follows the horizontal divider AND right edge follows the vertical one.
    check(approxEqual(out[2].target.minY, 588), "bottom-left top edge tracks the horizontal divider")
    check(approxEqual(out[2].target.maxX, 600), "bottom-left right edge tracks the vertical divider")
    // Diagonal neighbor: BOTH its left and top edges move — the bug that prompted this.
    check(approxEqual(out[3].target.minX, 608), "diagonal left edge tracks the vertical divider")
    check(approxEqual(out[3].target.minY, 588), "diagonal top edge tracks the horizontal divider")
    check(approxEqual(out[3].target.maxX, 1008) && approxEqual(out[3].target.maxY, 1008),
          "diagonal keeps its outer corner anchored")
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

// MARK: - Drag-to-snap geometry

do {
    let area = CGRect(x: 0, y: 0, width: 2000, height: 1000)
    // A window occupies the left half; the open area is the right half.
    let occupied = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
    let empty = Snap.largestEmptyRect(containing: CGPoint(x: 1500, y: 500), in: area, avoiding: occupied)
    check(empty != nil, "finds an empty rect in the open area")
    if let e = empty {
        check(e.minX >= 1000 - 0.5 && abs(e.maxX - 2000) < 0.5, "empty rect is the open right region")
    }
    // Pointer over the occupied window → no snap (caller treats as swap).
    check(Snap.largestEmptyRect(containing: CGPoint(x: 500, y: 500), in: area, avoiding: occupied) == nil,
          "no snap rect when pointer is over an occupied window")
}

do {
    // Width cap on a wide display (5200×2180). A full-width, half-height rect must be trimmed to
    // half the width, anchored on the cursor's side; a genuine full-screen rect is left alone.
    let area = CGRect(x: 0, y: 0, width: 5200, height: 2180)
    let fullWidthHalfHeight = CGRect(x: 0, y: 0, width: 5200, height: 1090)
    let leftCursor = Snap.capWidth(fullWidthHalfHeight, in: area, toward: CGPoint(x: 300, y: 500))
    check(abs(leftCursor.width - 2600) < 0.5 && abs(leftCursor.minX - 0) < 0.5, "wide/partial rect capped to left half near a left cursor")
    let rightCursor = Snap.capWidth(fullWidthHalfHeight, in: area, toward: CGPoint(x: 4800, y: 500))
    check(abs(rightCursor.width - 2600) < 0.5 && abs(rightCursor.maxX - 5200) < 0.5, "wide/partial rect capped to right half near a right cursor")
    check(abs(leftCursor.height - 1090) < 0.5, "capping width never touches height")

    let fullScreen = Snap.capWidth(area, in: area, toward: CGPoint(x: 2600, y: 1090))
    check(fullScreen == area, "genuine full-screen suggestion is left uncapped")

    let column = CGRect(x: 0, y: 0, width: 1600, height: 2180)      // already under half width
    check(Snap.capWidth(column, in: area, toward: CGPoint(x: 800, y: 1090)) == column, "narrow full-height column is left alone")
}

do {
    // Shape guard: reject a short, super-wide sliver; accept normal and tall-narrow shapes.
    check(!Snap.isReasonablyShaped(CGRect(x: 0, y: 0, width: 2600, height: 400)), "short/super-wide sliver (6.5:1) is rejected")
    check(Snap.isReasonablyShaped(CGRect(x: 0, y: 0, width: 2600, height: 1000)), "a well-proportioned zone (2.6:1) is accepted")
    check(Snap.isReasonablyShaped(CGRect(x: 0, y: 0, width: 400, height: 1600)), "a tall narrow column is accepted (tall shapes aren't capped)")
    check(!Snap.isReasonablyShaped(CGRect(x: 0, y: 0, width: 900, height: 0)), "a zero-height rect is rejected")

    // isProposable adds the "short" qualifier so full-height wide zones (ultrawide maximize) survive.
    let area = CGRect(x: 0, y: 0, width: 5120, height: 1440)                 // 32:9-ish ultrawide
    check(Snap.isProposable(area, in: area), "full-height ultrawide zone is proposable despite a >3 ratio")
    check(!Snap.isProposable(CGRect(x: 0, y: 0, width: 2600, height: 400), in: CGRect(x: 0, y: 0, width: 5200, height: 2180)),
          "a short, super-wide band is not proposable")
    check(Snap.isProposable(CGRect(x: 0, y: 0, width: 2600, height: 1040), in: CGRect(x: 0, y: 0, width: 5200, height: 2180)),
          "a half-height, half-width zone is proposable")

    // Zones smaller than the smallest tileable window are never proposed.
    let big = CGRect(x: 0, y: 0, width: 5200, height: 2180)
    check(!Snap.isProposable(CGRect(x: 0, y: 0, width: 200, height: 800), in: big),
          "a zone narrower than minTileableSize is not proposable")
    check(!Snap.isProposable(CGRect(x: 0, y: 0, width: 800, height: 120), in: big),
          "a zone shorter than minTileableSize is not proposable")
    check(Snap.isProposable(CGRect(x: 0, y: 0, width: 240, height: 2180), in: big),
          "a min-width full-height column is proposable")
}

do {
    // Two windows border the open region. A greedy shrink keeps the wider left strip first, then
    // the second window forces it to trim again → 400k. The true maximum is the full-width top
    // strip → 500k. This guards against that regression.
    let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let a = CGRect(x: 500, y: 500, width: 500, height: 500)
    let b = CGRect(x: 0, y: 800, width: 500, height: 200)
    let e = Snap.largestEmptyRect(containing: CGPoint(x: 200, y: 200), in: area, avoiding: [a, b])
    check(e != nil, "finds an empty rect with two bordering windows")
    if let e {
        check(abs(e.width * e.height - 500_000) < 1.0,
              "picks the true maximal empty rect, not a greedy sub-rect")
    }
}

do {
    // Edge bias halves the empty rect toward the cursor; a corner gives a quarter.
    let e = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let left = Snap.biased(e, toward: CGPoint(x: 50, y: 400))
    check(abs(left.width - 500) < 0.5 && abs(left.minX - 0) < 0.5, "left bias → left half")
    let right = Snap.biased(e, toward: CGPoint(x: 950, y: 400))
    check(abs(right.minX - 500) < 0.5 && abs(right.width - 500) < 0.5, "right bias → right half")
    let center = Snap.biased(e, toward: CGPoint(x: 500, y: 400))
    check(abs(center.width - 1000) < 0.5 && abs(center.height - 800) < 0.5, "center → whole rect")
    let corner = Snap.biased(e, toward: CGPoint(x: 950, y: 750))
    check(abs(corner.width - 500) < 0.5 && abs(corner.height - 400) < 0.5 && abs(corner.minX - 500) < 0.5 && abs(corner.minY - 400) < 0.5,
          "bottom-right corner → bottom-right quarter")
}

// MARK: - Too many windows: recency-priority + on-screen guarantee

do {
    // 30 windows on a normal display: every window gets a tile, and none is off-screen.
    let many = (0..<30).map { _ in makeWindow("browser") }
    let plan = FallbackTiler.plan(display: display, windows: many, gap: 8, catalog: cat)
    check(plan.tiles.count == 30, "every window gets a tile even when there are too many")
    check(plan.tiles.allSatisfy { display.visibleFrame.contains($0.frame) }, "no tile is pushed off-screen")
    // Overflow windows are demoted to the small comfortable-cell size.
    let small = plan.tiles.filter { abs($0.frame.width - FallbackTiler.comfortableCell.width) < 0.5 }
    check(!small.isEmpty, "overflow windows are demoted to small cascaded tiles")
}

do {
    // On-screen guard: a window that can't shrink and spills past the edge is pulled back.
    let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let spilling = CGRect(x: 900, y: 700, width: 400, height: 300)   // extends past right/bottom
    let fixed = WindowApplier.onScreenOrigin(for: spilling, in: area)
    check(fixed != nil, "a spilling window is corrected")
    if let fixed {
        check(fixed.x + 400 <= area.maxX + 0.5 && fixed.y + 300 <= area.maxY + 0.5, "correction brings it fully on-screen")
    }
    check(WindowApplier.onScreenOrigin(for: CGRect(x: 10, y: 10, width: 100, height: 100), in: area) == nil,
          "an already on-screen window needs no correction")
}

// MARK: - Prompt token efficiency

do {
    let w0 = makeWindow("browser")
    let w1 = makeWindow("terminal")
    let text = Prompt.userText(display: display, windows: [w0, w1], gap: 8, catalog: cat)
    check(text.contains("w0") && text.contains("w1"), "prompt uses short window ids")
    check(!text.contains(w0.id.uuidString) && !text.contains(w1.id.uuidString), "prompt no longer embeds 36-char UUIDs")
    check(!text.contains("currentSize"), "prompt dropped currentSize")
    check(!text.contains("title="), "prompt drops titles when no screenshot is attached")
    let withTitles = Prompt.userText(display: display, windows: [w0], gap: 8, catalog: cat, includeTitles: true)
    check(Prompt.shortID(3) == "w3", "shortID format")
    _ = withTitles
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

// MARK: - Layout cache

do {
    // Signature is order-independent but count- and display-sensitive.
    let a = LayoutCache.signature(appKeys: ["com.a", "com.b"], displaySignatures: ["d1"])
    let b = LayoutCache.signature(appKeys: ["com.b", "com.a"], displaySignatures: ["d1"])
    check(a == b, "cache signature ignores window order")
    let c = LayoutCache.signature(appKeys: ["com.a", "com.b", "com.b"], displaySignatures: ["d1"])
    check(a != c, "a second window of an app changes the signature")
    let d = LayoutCache.signature(appKeys: ["com.a", "com.b"], displaySignatures: ["d2"])
    check(a != d, "a different display arrangement changes the signature")
}

do {
    // Resolve must consume every entry AND every window; a drifted set returns nil.
    let w1 = makeWindow("browser"), w2 = makeWindow("chat")
    let cached = CachedLayout(entries: [
        CachedLayout.Entry(appKey: "browser", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        CachedLayout.Entry(appKey: "chat", frame: CGRect(x: 810, y: 0, width: 400, height: 600)),
    ], savedAt: Date())
    let resolved = LayoutCache.resolve(cached, windows: [w2, w1])   // order shouldn't matter
    check(resolved != nil && resolved!.count == 2, "cached layout resolves to all windows")
    if let r = resolved {
        let browserFrame = r.first { $0.window.id == w1.id }!.frame
        check(abs(browserFrame.width - 800) < 0.5, "resolved frame goes to the matching app")
    }
    check(LayoutCache.resolve(cached, windows: [w1]) == nil, "missing window → no cache hit (replan)")
    check(LayoutCache.resolve(cached, windows: [w1, w2, makeWindow("editor")]) == nil,
          "extra window → no cache hit (replan)")
}

// MARK: - Update checker version compare

do {
    check(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.9"), "0.2.0 > 0.1.9")
    check(UpdateChecker.isVersion("0.1.10", newerThan: "0.1.9"), "0.1.10 > 0.1.9 (numeric, not lexical)")
    check(!UpdateChecker.isVersion("0.1.9", newerThan: "0.1.9"), "equal versions are not newer")
    check(UpdateChecker.isVersion("v1.0", newerThan: "0.9.9"), "leading v is stripped")
    check(!UpdateChecker.isVersion("0.1", newerThan: "0.1.0"), "0.1 == 0.1.0")
}

// MARK: - Quick snap geometry

do {
    let area = CGRect(x: 0, y: 25, width: 2000, height: 1000)
    let left = Snap.half(left: true, of: area, gap: 10)
    let right = Snap.half(left: false, of: area, gap: 10)
    check(abs(left.width - 985) < 0.5 && abs(right.width - 985) < 0.5, "halves split the area minus three gaps")
    check(abs(left.minX - 10) < 0.5, "left half starts one gap in")
    check(abs(right.maxX - 1990) < 0.5, "right half ends one gap short of the edge")
    check(abs(left.maxX + 10 - right.minX) < 0.5, "exactly one gap between the halves")
    let maxed = Snap.maximized(of: area, gap: 10)
    check(abs(maxed.width - 1980) < 0.5 && abs(maxed.minY - 35) < 0.5, "maximize insets by the gap")
}

// MARK: - Per-app rules + intents in the offline tiler

do {
    // A pinned-right chat app must end up in the rightmost column even though the tiler would
    // otherwise order it by width preference.
    let browser = makeWindow("browser")
    var chat = makeWindow("chat")
    chat = ManagedWindow(id: chat.id, pid: 1, appName: "chat", bundleId: "com.test.chat", title: "",
                         categoryId: "chat", frame: chat.frame, isMinimized: false, axHandle: chat.axHandle)
    let rules = AppRules(byBundleId: ["com.test.chat": .pinRight])
    let plan = FallbackTiler.plan(display: display, windows: [chat, browser], gap: 8, catalog: cat, rules: rules)
    let chatTile = plan.tiles.first { $0.windowId == chat.id }!
    let browserTile = plan.tiles.first { $0.windowId == browser.id }!
    check(chatTile.frame.minX > browserTile.frame.minX, "pinRight app lands right of the others")
}

do {
    // Under the coding intent, an editor outranks newer chat/music windows for the primary tiles.
    check(LayoutIntent.coding.priority(categoryId: "editor") < LayoutIntent.coding.priority(categoryId: "chat"),
          "coding intent ranks editor above chat")
    check(LayoutIntent.communication.priority(categoryId: "chat") < LayoutIntent.communication.priority(categoryId: "terminal"),
          "communication intent ranks chat above terminal")
    check(LayoutIntent.automatic.priority(categoryId: "chat") == LayoutIntent.automatic.priority(categoryId: "editor"),
          "automatic intent is pure recency (no category ranking)")
}

// MARK: - Learned position (side preference)

do {
    let leftish = LearnedDims(widthFraction: 0.3, heightFraction: 0.8, xFraction: 0.2, samples: 5)
    check(leftish.sidePreference == "left", "x≈0.2 reads as a left-side habit")
    let rightish = LearnedDims(widthFraction: 0.3, heightFraction: 0.8, xFraction: 0.8, samples: 5)
    check(rightish.sidePreference == "right", "x≈0.8 reads as a right-side habit")
    let centered = LearnedDims(widthFraction: 0.3, heightFraction: 0.8, xFraction: 0.5, samples: 5)
    check(centered.sidePreference == nil, "centered x has no side preference")
    let unseen = LearnedDims(widthFraction: 0.3, heightFraction: 0.8, xFraction: 0.9, samples: 1)
    check(unseen.sidePreference == nil, "one sample isn't a habit yet")
}

// MARK: - Report

print("Tessera checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
