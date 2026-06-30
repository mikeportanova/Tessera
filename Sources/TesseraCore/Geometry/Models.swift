import Foundation
import CoreGraphics
import ApplicationServices

/// All frames in Tessera's domain model are stored in **CG / Accessibility coordinates**:
/// origin top-left, Y increases downward. This is the coordinate space the Accessibility
/// API expects when setting `kAXPositionAttribute`. The one place we convert to/from AppKit's
/// bottom-left space is `CoordinateConverter`.
public typealias CGFrame = CGRect

/// A coarse classification of an app, used to seed the LLM with sensible width preferences
/// and as a fallback when the model is unavailable.
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case browser        // wide
    case editor         // wide  (IDEs, code editors)
    case terminal       // medium / narrow
    case chat           // thin column
    case email          // medium
    case notes          // medium
    case music          // thin column / small
    case design         // wide
    case reference       // medium (PDF, docs)
    case other

    /// Fraction of the usable display width this category typically wants, as a starting hint.
    /// The LLM is free to override; this is only a prior and an offline fallback.
    public var preferredWidthFraction: Double {
        switch self {
        case .browser, .editor, .design: return 0.5
        case .terminal, .email, .notes, .reference: return 0.34
        case .chat: return 0.30   // chat apps (e.g. Slack) need room for a channel list + stream
        case .music: return 0.20
        case .other: return 0.4
        }
    }

    /// The widest this kind of window should ever be made, in points, regardless of how much screen
    /// is free. Beyond this a window is just stretched uncomfortably (e.g. a 2000pt-wide terminal),
    /// so we'd rather leave empty desktop than exceed it. A learned per-app preference can raise
    /// this ceiling (see `LearnedDimensions.maxWidth`).
    public var maxReasonableWidth: CGFloat {
        switch self {
        case .design:    return 1800
        case .editor:    return 1600
        case .browser:   return 1500
        case .terminal:  return 1200
        case .reference: return 1200
        case .email:     return 1100
        case .notes:     return 1000
        case .other:     return 1400
        case .chat:      return 1000   // channel list + message stream (+ occasional thread pane)
        case .music:     return 560
        }
    }

    /// The tallest this kind of window should ever be made, in points. Like `maxReasonableWidth`,
    /// this caps over-stretching on tall displays (e.g. Slack shouldn't run the full height of a
    /// 2160px monitor); leftover height is left as empty desktop. A learned preference can raise it.
    public var maxReasonableHeight: CGFloat {
        switch self {
        case .browser, .editor, .design: return 1600
        case .reference: return 1500
        case .terminal, .email, .notes: return 1400
        case .other: return 1500
        case .chat: return 1100
        case .music: return 760
        }
    }
}

/// A window we can actually move, captured at a single point in time.
public struct ManagedWindow: Identifiable, Sendable {
    public let id: UUID
    public let pid: pid_t
    public let appName: String
    public let bundleId: String?
    public let title: String
    /// The id of the `CategoryProfile` this window classified to (built-in or custom).
    public let categoryId: String
    /// Current on-screen frame in CG (top-left) coordinates.
    public var frame: CGFrame
    public let isMinimized: Bool
    /// Opaque handle to the live AXUIElement, used by WindowApplier to set geometry.
    /// Not Codable — re-resolved on every enumeration.
    public let axHandle: AXWindowHandle

    public init(
        id: UUID = UUID(),
        pid: pid_t,
        appName: String,
        bundleId: String?,
        title: String,
        categoryId: String,
        frame: CGFrame,
        isMinimized: Bool,
        axHandle: AXWindowHandle
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.categoryId = categoryId
        self.frame = frame
        self.isMinimized = isMinimized
        self.axHandle = axHandle
    }
}

/// A reference-typed wrapper around the live AXUIElement so `ManagedWindow` can stay a value type.
/// AXUIElement is a CoreFoundation type; we hold it here and never serialize it.
public final class AXWindowHandle: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

/// A display we can tile into.
public struct DisplayInfo: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    /// Full bounds in CG (top-left) coordinates.
    public let frame: CGFrame
    /// Usable bounds (menu bar + Dock excluded) in CG (top-left) coordinates — this is what we tile into.
    public let visibleFrame: CGFrame
    public let backingScale: CGFloat
    public let isPrimary: Bool

    public init(
        id: CGDirectDisplayID,
        frame: CGFrame,
        visibleFrame: CGFrame,
        backingScale: CGFloat,
        isPrimary: Bool
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScale = backingScale
        self.isPrimary = isPrimary
    }

    /// Stable-ish key for save/restore: resolution + origin. Survives relaunches as long as the
    /// display arrangement is unchanged.
    public var signature: String {
        "\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.x)),\(Int(frame.origin.y))"
    }
}

/// One window's target rectangle within a display, produced by the planner.
public struct Tile: Codable, Sendable {
    public let windowId: UUID
    /// Target frame in CG (top-left) coordinates.
    public let frame: CGFrame

    public init(windowId: UUID, frame: CGFrame) {
        self.windowId = windowId
        self.frame = frame
    }
}

/// The full output of a planning pass for one display.
public struct LayoutPlan: Codable, Sendable {
    public let displaySignature: String
    public let tiles: [Tile]

    public init(displaySignature: String, tiles: [Tile]) {
        self.displaySignature = displaySignature
        self.tiles = tiles
    }
}

/// A persisted arrangement, keyed by display signature and matched back to windows by
/// bundle id + (best-effort) title — AX handles don't survive relaunch.
public struct SavedLayout: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let bundleId: String?
        public let appName: String
        public let titleHint: String
        public let frame: CGFrame

        public init(bundleId: String?, appName: String, titleHint: String, frame: CGFrame) {
            self.bundleId = bundleId
            self.appName = appName
            self.titleHint = titleHint
            self.frame = frame
        }
    }

    public let name: String
    public let displaySignature: String
    public let entries: [Entry]
    public let savedAt: Date

    public init(name: String, displaySignature: String, entries: [Entry], savedAt: Date) {
        self.name = name
        self.displaySignature = displaySignature
        self.entries = entries
        self.savedAt = savedAt
    }
}
