# Tessera

An LLM-driven window tiler for macOS — like Magnet / Rectangle / BetterSnapTool, but instead of
fixed halves and quarters, an AI looks at your open apps (and optionally a screenshot of your
screen), reasons about your display resolution and the *typical shape each kind of app wants*
(browsers and editors go wide, terminals get a medium column, chat and music apps become thin
columns), and tiles everything for you.

- **Tile now** — one click arranges every window on each display into an AI-chosen layout.
- **Auto-arrange** — watches for new apps/windows opening and re-tiles automatically (debounced).
- **Save / restore** — snapshot an arrangement and bring it back later (no AI call on restore).
- **Works without a key** — falls back to a built-in deterministic tiler when no API key is set or
  the network call fails, so it's always useful.

> Phase 2 (designed-in, not yet built): drag a window onto another tile to **swap** them, and drag
> tile edges to **expand/contract** with neighbors reflowing. See the architecture notes below.

## Requirements

- macOS 14+ (built and tested on macOS 26).
- Swift 6 toolchain (`swift --version`). Full Xcode is **not** required — everything builds from the
  command line with SwiftPM.
- An Anthropic API key (optional, for AI layouts). Stored in your **Keychain**, never on disk.

## Build & run

```bash
# Build the app bundle and launch it
bash scripts/run.sh

# …or just build the bundle without launching
bash scripts/build-app.sh        # produces dist/Tessera.app
```

The grid icon appears in your menu bar (Tessera is a background "agent" app — no Dock icon).

### Tests / checks

`swift test` needs the XCTest/Testing runtime, which a Command Line Tools-only install doesn't ship.
Checks therefore run as a plain executable:

```bash
swift run TesseraChecks
```

## First-run permissions

Tessera needs macOS permissions that **cannot be granted programmatically** — you toggle them in
System Settings:

1. **Accessibility** (required) — to move and resize other apps' windows. On first launch Tessera
   prompts and deep-links to *System Settings ▸ Privacy & Security ▸ Accessibility*. Toggle Tessera
   on. The menu updates automatically once granted.
2. **Screen Recording** (optional) — only if you enable **Content-aware** tiling, which sends a
   screenshot so the AI can arrange by what's on screen.

### Permission persistence during development

macOS pins permission grants to the app's **code signature**. The dev build is **ad-hoc signed**,
whose signature changes on most rebuilds, so macOS may re-prompt after rebuilding. To clear stale
grants during development:

```bash
tccutil reset Accessibility com.fileread.Tessera
tccutil reset ScreenCapture com.fileread.Tessera
```

For permissions that persist across updates, sign with a stable **Developer ID** identity (see
`scripts/build-app.sh`). Note Tessera is **non-sandboxed** by necessity (controlling other apps'
windows is exactly what the App Sandbox forbids), so it is distributed outside the Mac App Store.

## Configuration

Open the menu-bar popover ▸ **Settings**:

- **Anthropic API key** — paste a key (`sk-ant-…`); stored in the Keychain.
- **Model** — `claude-sonnet-4-6` (fast, default) or `claude-opus-4-8` (best quality).
- **Auto-arrange**, **Content-aware**, and the inter-tile **Gap** are on the main popover.

## Architecture

```
Sources/
  TesseraCore/            # all logic (a library, so the checks target can exercise it)
    Geometry/             # CoordinateConverter (the AppKit↔CG flip), Display, Models
    Accessibility/        # AXWindow/AXApplication (move/resize), WindowEnumerator, AppCategorizer
    Permissions/          # Accessibility + Screen Recording (TCC) prompting & polling
    Capture/              # ScreenCaptureKit screenshot → base64 PNG
    LLM/                  # ClaudeClient (URLSession + forced tool-use JSON), LayoutPlanner, Prompt
    Engine/               # TilingEngine, WindowApplier, FallbackTiler, AX observers, auto-arrange
    State/                # LayoutStore (save/restore), AppSettings, Keychain
  Tessera/                # thin SwiftUI menu-bar app (MenuBarExtra) — depends on TesseraCore
Tests/Checks/             # standalone assertion harness (swift run TesseraChecks)
```

**Key design points**

- **One coordinate converter.** AppKit is bottom-left origin; the Accessibility API and CoreGraphics
  are top-left. The domain model stores everything in CG (top-left) coordinates, and
  `CoordinateConverter` is the *only* place the flip happens.
- **Structured AI output.** The layout comes back via a forced tool call (`emit_layout`) with a
  strict JSON schema, then every frame is clamped into the display's usable area so a bad coordinate
  can never shove a window off-screen.
- **Robust window moves.** `AXWindow.setFrame` does the size → position → size dance to defeat
  macOS's cross-display size clamping (the same trick Rectangle uses).
- **Graceful degradation.** No key, no network, or a malformed response → `FallbackTiler`, a
  deterministic column tiler that respects each app category's width prior.

## License

TBD.
