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
    public static func userText(
        display: DisplayInfo,
        windows: [ManagedWindow],
        gap: Double,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty
    ) -> String {
        let vf = display.visibleFrame
        var lines: [String] = []
        lines.append("Display: \(Int(display.frame.width))x\(Int(display.frame.height)) @\(Int(display.backingScale))x")
        lines.append("Usable area (tile within this): x=\(Int(vf.origin.x)), y=\(Int(vf.origin.y)), width=\(Int(vf.width)), height=\(Int(vf.height))")
        lines.append("Gap between tiles: \(Int(gap))pt")
        lines.append("")
        lines.append("Windows to place (\(windows.count)):")
        for w in windows {
            let prior = catalog.widthPrior(id: w.categoryId, bundleId: w.bundleId, learned: learned)
            let isLearned = learned.dims(bundleId: w.bundleId, categoryId: w.categoryId) != nil
            let maxW = catalog.maxWidth(id: w.categoryId, bundleId: w.bundleId, usableWidth: vf.width, learned: learned)
            let maxH = catalog.maxHeight(id: w.categoryId, bundleId: w.bundleId, usableHeight: vf.height, learned: learned)
            let p = catalog.profile(id: w.categoryId)
            lines.append(
                "- id=\(w.id.uuidString) | app=\"\(w.appName)\" | category=\(p.name) "
                + "| widthPrior=\(String(format: "%.2f", prior))\(isLearned ? " (learned from this user)" : "") "
                + "| minSize=\(Int(p.minWidth))x\(Int(p.minHeight))pt | maxWidth=\(Int(maxW))pt | maxHeight=\(Int(maxH))pt "
                + "| currentSize=\(Int(w.frame.width))x\(Int(w.frame.height)) | title=\"\(w.title.prefix(60))\""
            )
        }
        lines.append("")
        lines.append("Width priors marked \"(learned from this user)\" reflect how this person has "
            + "previously resized that app — weight them heavily. Never exceed a window's maxWidth or "
            + "maxHeight; leave empty desktop instead.")
        lines.append("Produce a tile for every window id above, using its id verbatim.")
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
                        "window_id": ["type": "string", "description": "The window id, copied verbatim."],
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
