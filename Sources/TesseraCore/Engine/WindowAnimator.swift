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
    /// A fixed per-frame loop at ~60fps: every frame applies a fresh position/size to every window and
    /// then yields, so the WindowServer renders each one. Pushing past 60fps backfires — apps repaint
    /// on their own schedule and the extra AX sets just coalesce, so intermediate frames vanish. The
    /// smootherstep easing gives a gentle start and stop; the frame count is derived from the duration
    /// so the pacing stays ~60fps regardless of how long the slide is.
    public static func animate(_ moves: [Move], clampTo area: CGRect?) async {
        let items = moves.compactMap { m -> (AXWindow, CGRect, CGRect)? in
            guard let start = m.window.frame else { return nil }
            return (m.window, start, m.target)
        }
        guard !items.isEmpty else { return }

        if !reduceMotion {
            let frames = max(2, Int((duration * 60).rounded()))
            let stepNanos = UInt64(duration / Double(frames) * 1_000_000_000)
            for step in 1..<frames {
                let t = smootherStep(Double(step) / Double(frames))
                for (win, start, target) in items {
                    win.setSize(lerpSize(start.size, target.size, t))
                    win.setPosition(lerpPoint(start.origin, target.origin, t))
                }
                try? await Task.sleep(nanoseconds: stepNanos)
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
}
