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
        includeTitles: Bool = false
    ) -> String {
        let vf = display.visibleFrame
        var lines: [String] = []
        lines.append("Display \(Int(display.frame.width))x\(Int(display.frame.height)) @\(Int(display.backingScale))x")
        lines.append("Usable area (place tiles inside this): x=\(Int(vf.origin.x)) y=\(Int(vf.origin.y)) w=\(Int(vf.width)) h=\(Int(vf.height)); gap \(Int(gap))pt")
        lines.append("")
        lines.append("Windows (id | app | category | widthPrior | min wxh | max wxh):")
        for (i, w) in windows.enumerated() {
            let prior = catalog.widthPrior(id: w.categoryId, bundleId: w.bundleId, learned: learned)
            let isLearned = learned.dims(bundleId: w.bundleId, categoryId: w.categoryId) != nil
            let maxW = catalog.maxWidth(id: w.categoryId, bundleId: w.bundleId, usableWidth: vf.width, learned: learned)
            let maxH = catalog.maxHeight(id: w.categoryId, bundleId: w.bundleId, usableHeight: vf.height, learned: learned)
            let p = catalog.profile(id: w.categoryId)
            var line = "\(shortID(i)) | \(w.appName) | \(p.name) | \(String(format: "%.2f", prior))\(isLearned ? "*" : "")"
                + " | \(Int(p.minWidth))x\(Int(p.minHeight)) | \(Int(maxW))x\(Int(maxH))"
            if includeTitles, !w.title.isEmpty { line += " | \"\(w.title.prefix(50))\"" }
            lines.append(line)
        }
        lines.append("")
        lines.append("widthPrior is a fraction of usable width; * means learned from this user (weight it heavily).")
        lines.append("Never exceed a window's max wxh; leave empty desktop instead. Place a tile for every id, echoing the id verbatim.")
        return lines.joined(separator: "\n")
    }

    /// JSON schema for the forced `emit_layout` tool call. Computed (not a stored `static let`) so
    /// it isn't a shared mutable global under Swift 6 strict concurrency — each call builds a fresh
    /// dictionary.
    public static var layoutToolSchema: [String: Any] {[
        "type": "object",
        "properties": [
            "tiles": [
                "type": "array",
                "description": "One entry per window, covering the usable area without overlap.",
                "items": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "string", "description": "The window id (e.g. w0), copied verbatim."],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "width": ["type": "number"],
                        "height": ["type": "number"],
                    ],
                    "required": ["window_id", "x", "y", "width", "height"],
                    "additionalProperties": false,
                ],
            ]
        ],
        "required": ["tiles"],
        "additionalProperties": false,
    ]}
}
