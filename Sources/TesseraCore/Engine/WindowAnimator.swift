import AppKit
import CoreGraphics

/// Slides windows from their current frames to their targets with a short ease-out, instead of
/// snapping instantly. Intermediate steps use a lightweight setSize+setPosition; the final step uses
/// the full size→position→size dance plus an on-screen clamp so windows land exactly where intended.
///
/// Runs on the main actor and yields (`Task.sleep`) between frames, so the run loop keeps turning and
/// the UI stays responsive during the slide. Honors the system **Reduce Motion** setting — when that's
/// on, windows are placed instantly with no interpolation.
@MainActor
public enum WindowAnimator {
    /// Total slide duration. Long enough for a graceful ease at 60fps, short enough to stay snappy.
    public static let duration: TimeInterval = 0.26

    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public struct Move {
        public let window: AXWindow
        public let target: CGRect
        public init(window: AXWindow, target: CGRect) {
            self.window = window
            self.target = target
        }
    }

    /// Animate the moves to completion. Windows whose current frame can't be read are skipped.
    ///
    /// A per-frame loop at ~60fps: every frame applies a fresh position/size to every moving window
    /// and then yields, so the WindowServer renders each one. Pushing past 60fps backfires — apps
    /// repaint on their own schedule and the extra AX sets just coalesce, so intermediate frames
    /// vanish. Progress is computed from the **wall clock**, not a step index: `Task.sleep` overshoots
    /// and the AX sets themselves cost real milliseconds (especially for heavy apps × many windows),
    /// so a step-indexed loop stretches the slide and wobbles its velocity — a slow frame should skip
    /// ahead, keeping the eased motion even and the total duration honest. Windows already at their
    /// target are left out of the interpolation entirely (no AX churn for windows that aren't moving).
    public static func animate(_ moves: [Move], clampTo area: CGRect?) async {
        let items = moves.compactMap { m -> (AXWindow, CGRect, CGRect)? in
            guard let start = m.window.frame else { return nil }
            return (m.window, start, m.target)
        }
        guard !items.isEmpty else { return }

        // Only windows that actually have somewhere to go participate in the slide.
        let moving = items.filter { !approxSameFrame($0.1, $0.2) }

        if !reduceMotion && !moving.isEmpty {
            let frameNanos: UInt64 = 16_666_667   // ~60fps
            let startTime = Date()
            while true {
                let raw = min(1.0, Date().timeIntervalSince(startTime) / duration)
                if raw >= 1.0 { break }            // t = 1 is the exact final placement below
                let t = smootherStep(raw)
                for (win, start, target) in moving {
                    win.setSize(lerpSize(start.size, target.size, t))
                    win.setPosition(lerpPoint(start.origin, target.origin, t))
                }
                try? await Task.sleep(nanoseconds: frameNanos)
            }
        }

        // Final exact placement (and on-screen correction) regardless of reduce-motion.
        for (win, _, target) in items {
            _ = win.setFrame(target)
            if let area, let actual = win.frame,
               let fixed = WindowApplier.onScreenOrigin(for: actual, in: area), fixed != actual.origin {
                win.setPosition(fixed)
            }
        }
    }

    // MARK: - Interpolation

    /// Perlin smootherstep — zero velocity *and* acceleration at both ends, for a gentle ease.
    static func smootherStep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    static func lerpPoint(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func lerpSize(_ a: CGSize, _ b: CGSize, _ t: Double) -> CGSize {
        CGSize(width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private static func approxSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}
