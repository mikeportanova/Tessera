# Tessera — Future Feature Ideas

Proposals collected while building. None of these are started; they're ranked roughly by how much
they'd advance the core goal (*intelligently lay out my windows at the touch of a key*).

## High value

1. **Per-intent hotkeys / instant workspace switching.** The intent picker exists (Coding /
   Communication / Research / Writing), but switching still takes two clicks. Bind e.g. ⌃⌥⌘1–4 to
   "set intent + tile now" so one keystroke reshapes the desktop around what you're about to do.
   Pairs perfectly with the layout cache: each (intent, window set) pair could cache separately,
   making workspace switching instant after the first use.

2. **Focus-follows-layout.** After tiling, raise + focus the window the intent says is primary (the
   editor when coding, chat when communicating). The layout change then *feels* like a mode switch,
   not just window rearrangement.

3. **Multi-desktop / Spaces awareness.** Tessera currently tiles the current Space only (AX can't
   move windows between Spaces without private APIs). A pragmatic version: detect Space changes
   (`NSWorkspace.activeSpaceDidChangeNotification`), keep a separate live grid + cache signature per
   Space, and re-tile per Space. "Overflow to another Space" could replace the corner cascade for
   older windows.

4. **App auto-launch per intent.** A "Coding" intent that can *open* your editor/terminal if they
   aren't running (opt-in, per-intent app list) turns intents into true workspace definitions.

5. **Smart displaced-window handling.** When a swap/snap displaces a window, offer a mini-layout of
   candidate spots (largest empty rects) instead of returning it to the dragged window's origin.

## Medium value

6. **Layout history / multiple undo.** The undo stack is one level deep. A small ring buffer (5–10
   snapshots) with ⌃⌥⌘Z stepping backward would make experimentation risk-free. Cheap to build on
   the existing `captureUndo` machinery.

7. **Time-of-day priors.** The usage tracker already timestamps tilings. Learn that mornings are
   communication-heavy and afternoons are coding-heavy; default the Automatic intent accordingly.

8. **Sparkle auto-updates.** The update checker links to GitHub Releases but the user still
   downloads/installs manually. Sparkle (EdDSA-signed appcast) would make updates one-click. Needs:
   public releases (or hosted appcast), Sparkle SPM dependency, embedding the framework in
   build-app.sh, and key management.

9. **`release.sh` + GitHub Releases automation.** `gh release create v0.x.y dist/Tessera-0.x.y.dmg`
   after make-dmg.sh, so the update checker actually has something to find. (Requires the repo to be
   public, or the releases API returns 404 to unauthenticated users.)

10. **Window title–aware categories.** A browser window titled "YouTube" behaves like media; a
    "Figma" tab behaves like design. Feed titles to the classifier (only when content-aware is on,
    to control tokens).

## Nice to have

11. **Tile-edge divider dragging.** Grab the *gap between two tiles* (not a window edge) and drag to
    resize both simultaneously, BetterTouchTool-style. The reflow engine already handles the
    geometry; this needs a hover-detection overlay strip between tiles.

12. **Corner/edge quick-snap zones.** Extend ⌃⌥←/→ with quarters (⌃⌥U/I/J/K or drag-to-corner) —
    the `Snap.biased` quarter logic already computes these frames.

13. **Per-display gap settings.** A 5K display wants bigger gaps than a 13" laptop panel.

14. **Menu-bar icon states.** Animate the menu-bar glyph while planning (progress) and flash on
    completion, so feedback exists even without the HUD.

15. **Layout export/import.** Share a named layout (JSON) between machines or teammates.

16. **"Gather" command.** One keystroke to pull all windows from all displays onto the current
    display and tile them — useful when undocking from a multi-monitor setup.
