import Foundation

/// Builds the system + user prompt that asks Claude for a tiling layout, and documents the
/// app-type width heuristics the model should lean on.
public enum Prompt {

    /// System prompt: defines the model's job and the rules of good tiling.
    public static let system = """
    You are the layout engine for Tessera, a macOS window tiler. Given the usable area of a display \
    and a list of open windows, you decide where every window goes so the screen is used well.

    Rules:
    - Tile every window you are given. Do not drop any. Do not overlap windows.
    - NEVER make a window wider than its maxWidth or taller than its maxHeight (given per window, in
      points). A window stretched past a comfortable size (e.g. a 2000pt terminal, or Slack running
      the full height of a tall monitor) is worse than leaving empty desktop. It is perfectly fine —
      and often correct — to NOT fill the whole area: leave bare desktop rather than over-stretch.
    - Anchor the layout to the TOP-LEFT: start at the left edge and pack tiles toward the right, and
      start at the top edge and let tiles extend downward. Leave any leftover width as empty desktop
      on the RIGHT, and any leftover height as empty desktop at the BOTTOM. Do NOT center the group
      or pin it to the right/bottom.
    - Respect each app's natural shape. Typical width preferences as a fraction of usable width:
        • browsers, code editors/IDEs, design tools  → wide
        • terminals, email, notes, PDF/reference      → medium
        • chat apps, music players                     → thin column
      Treat widthPrior as the target width fraction and maxWidth as the hard ceiling.
    - With 1 window: size it to about its preferred width (NOT the whole screen unless that's still
      within maxWidth) and place it at the left edge. With 2: place them side by side at their
      preferred widths, starting from the left. With 3–4: combine columns and rows. With more:
      prefer a grid. Always grow rightward from the left edge.
    - Respect each window's minSize: don't make a tile smaller than its given minWidth/minHeight.
    - Windows are listed most-recently-used first. If there are more windows than can each get a tile
      at or above its minSize, give the most-recent windows proper tiles and place the older overflow
      as a small stack in a corner (each at least its minSize). Never make a tile below its minSize
      and never push any window off-screen — leaving some windows stacked is better than either.
    - Coordinates are top-left origin (y grows downward), in the SAME coordinate space as the \
      provided usable area. Every tile must lie fully within the usable area.

    Return your answer ONLY by calling the emit_layout tool.
    """

    /// Build the user-message text describing the display and windows.
    /// `display` and window frames are in CG (top-left) coordinates. `learned` supplies width priors
    /// the user has taught Tessera by resizing tiles over time.
    /// The id we put on the wire for the window at index `i`. Short (`w0`, `w1`, …) rather than a
    /// 36-char UUID — paid for on both the prompt *and* the echoed-back output, so the saving is
    /// doubled. `parseTiles` maps it back to the window by the same index.
    public static func shortID(_ index: Int) -> String { "w\(index)" }

    /// One window's descriptor line: sizing priors plus any user-taught hints (pin rule, learned side).
    private static func windowLine(
        _ w: ManagedWindow, index: Int, usable: CGRect,
        catalog: CategoryCatalog, learned: LearnedDimensions, rules: AppRules, includeTitles: Bool
    ) -> String {
        let prior = catalog.widthPrior(id: w.categoryId, bundleId: w.bundleId, learned: learned)
        let dims = learned.dims(bundleId: w.bundleId, categoryId: w.categoryId)
        let maxW = catalog.maxWidth(id: w.categoryId, bundleId: w.bundleId, usableWidth: usable.width, learned: learned)
        let maxH = catalog.maxHeight(id: w.categoryId, bundleId: w.bundleId, usableHeight: usable.height, learned: learned)
        let p = catalog.profile(id: w.categoryId)
        var line = "\(shortID(index)) | \(w.appName) | \(p.name) | \(String(format: "%.2f", prior))\(dims != nil ? "*" : "")"
            + " | \(Int(p.minWidth))x\(Int(p.minHeight)) | \(Int(maxW))x\(Int(maxH))"
        switch rules.rule(for: w.bundleId) {
        case .pinLeft:  line += " | PINNED:leftmost"
        case .pinRight: line += " | PINNED:rightmost"
        default:
            if let side = dims?.sidePreference { line += " | prefers:\(side)" }
        }
        if includeTitles {
            let title = sanitizedTitle(w.title)
            if !title.isEmpty { line += " | \"\(title.prefix(50))\"" }
        }
        return line
    }

    /// Strip newlines/control characters and collapse whitespace runs so an odd (or hostile) window
    /// title can't inject extra prompt lines. Truncation happens at the call site, after cleanup.
    private static func sanitizedTitle(_ title: String) -> String {
        let stripped = String(title.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        })
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func trailerLines(intent: LayoutIntent) -> [String] {
        var lines = [
            "",
            "widthPrior is a fraction of usable width; * means learned from this user (weight it heavily).",
            "PINNED means a hard placement rule; prefers:left/right is a learned habit — honor it when reasonable.",
            "Never exceed a window's max wxh; leave empty desktop instead. Place a tile for every id, echoing the id verbatim.",
        ]
        if let guidance = intent.promptGuidance {
            lines.insert(guidance, at: 1)
        }
        return lines
    }

    /// Build the user-message text describing the display and windows.
    /// `display` and window frames are in CG (top-left) coordinates. `learned` supplies width priors
    /// the user has taught Tessera. `includeTitles` adds window titles (only worth the tokens when a
    /// screenshot is also attached for content-aware tiling).
    public static func userText(
        display: DisplayInfo,
        windows: [ManagedWindow],
        gap: Double,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty,
        includeTitles: Bool = false,
        intent: LayoutIntent = .automatic,
        rules: AppRules = .empty
    ) -> String {
        let vf = display.visibleFrame
        var lines: [String] = []
        lines.append("Display \(Int(display.frame.width))x\(Int(display.frame.height)) @\(Int(display.backingScale))x")
        lines.append("Usable area (place tiles inside this): x=\(Int(vf.origin.x)) y=\(Int(vf.origin.y)) w=\(Int(vf.width)) h=\(Int(vf.height)); gap \(Int(gap))pt")
        lines.append("")
        lines.append("Windows (id | app | category | widthPrior | min wxh | max wxh):")
        for (i, w) in windows.enumerated() {
            lines.append(windowLine(w, index: i, usable: vf, catalog: catalog, learned: learned, rules: rules, includeTitles: includeTitles))
        }
        lines.append(contentsOf: trailerLines(intent: intent))
        return lines.joined(separator: "\n")
    }

    /// The display id we put on the wire for the display at index `i` (`d0`, `d1`, …).
    public static func displayID(_ index: Int) -> String { "d\(index)" }

    /// Multi-display variant: all displays and all windows in ONE request, so the model may move a
    /// window to a different display when that improves the overall layout. Coordinates are global
    /// CG (top-left) — each display's usable area is given in that same space.
    public static func multiDisplayUserText(
        displays: [DisplayInfo],
        windows: [ManagedWindow],
        gap: Double,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty,
        intent: LayoutIntent = .automatic,
        rules: AppRules = .empty
    ) -> String {
        var lines: [String] = []
        lines.append("There are \(displays.count) displays. Global top-left coordinates; gap \(Int(gap))pt.")
        lines.append("Displays (id | size | usable area):")
        for (i, d) in displays.enumerated() {
            let vf = d.visibleFrame
            lines.append("\(displayID(i)) | \(Int(d.frame.width))x\(Int(d.frame.height)) | x=\(Int(vf.origin.x)) y=\(Int(vf.origin.y)) w=\(Int(vf.width)) h=\(Int(vf.height))")
        }
        lines.append("")
        lines.append("Windows (id | app | category | widthPrior | min wxh | max wxh | current display):")
        for (i, w) in windows.enumerated() {
            // Size ceilings are computed against the window's current display; if you move it, keep
            // the same ceilings (they are per-app comfort limits, not per-display).
            let current = displays.enumerated().max {
                w.frame.intersectionArea($0.element.visibleFrame) < w.frame.intersectionArea($1.element.visibleFrame)
            }
            let usable = current?.element.visibleFrame ?? displays[0].visibleFrame
            var line = windowLine(w, index: i, usable: usable, catalog: catalog, learned: learned, rules: rules, includeTitles: false)
            line += " | \(displayID(current?.offset ?? 0))"
            lines.append(line)
        }
        lines.append("")
        lines.append("You MAY move a window to a different display when it makes the overall layout better (e.g. chat/email to a secondary display, main work on the biggest display). Set the display field on every tile; every tile must lie fully within that display's usable area.")
        lines.append(contentsOf: trailerLines(intent: intent))
        return lines.joined(separator: "\n")
    }

    /// JSON schema for the forced `emit_layout` tool call. Computed (not a stored `static let`) so
    /// it isn't a shared mutable global under Swift 6 strict concurrency — each call builds a fresh
    /// dictionary. `multiDisplay` adds a required per-tile display id.
    public static func layoutToolSchema(multiDisplay: Bool = false) -> [String: Any] {
        var properties: [String: Any] = [
            "window_id": ["type": "string", "description": "The window id (e.g. w0), copied verbatim."],
            "x": ["type": "number"],
            "y": ["type": "number"],
            "width": ["type": "number"],
            "height": ["type": "number"],
        ]
        var required = ["window_id", "x", "y", "width", "height"]
        if multiDisplay {
            properties["display"] = ["type": "string", "description": "The display id (e.g. d0) this tile is on."]
            required.append("display")
        }
        return [
            "type": "object",
            "properties": [
                "tiles": [
                    "type": "array",
                    "description": "One entry per window, covering the usable area without overlap.",
                    "items": [
                        "type": "object",
                        "properties": properties,
                        "required": required,
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["tiles"],
            "additionalProperties": false,
        ]
    }
}
