import Foundation

/// What the user is focused on right now. Telling the layout engine the *intent* changes layout
/// quality far more than any generic prompt tuning: "coding" wants the editor huge and chat tiny;
/// "communication" is the reverse.
public enum LayoutIntent: String, Codable, CaseIterable, Sendable {
    case automatic
    case coding
    case communication
    case research
    case writing

    public var displayName: String {
        switch self {
        case .automatic:     return "Automatic"
        case .coding:        return "Coding"
        case .communication: return "Communication"
        case .research:      return "Research"
        case .writing:       return "Writing"
        }
    }

    public var symbolName: String {
        switch self {
        case .automatic:     return "sparkles"
        case .coding:        return "chevron.left.forwardslash.chevron.right"
        case .communication: return "bubble.left.and.bubble.right"
        case .research:      return "magnifyingglass"
        case .writing:       return "pencil.and.outline"
        }
    }

    /// Extra guidance line for the LLM prompt, or nil for automatic.
    public var promptGuidance: String? {
        switch self {
        case .automatic:
            return nil
        case .coding:
            return "The user is CODING: give code editors/IDEs and terminals the largest, most prominent tiles; a browser gets a medium reference column; chat, email and music get the smallest tiles or the overflow stack."
        case .communication:
            return "The user is CATCHING UP ON COMMUNICATION: give chat and email the largest, most central tiles; notes and browser medium; editors/terminals can be small or stacked."
        case .research:
            return "The user is RESEARCHING: give browsers and PDF/reference windows the largest tiles; notes get a medium column for capture; chat and email get the smallest tiles or the overflow stack."
        case .writing:
            return "The user is WRITING: give notes/document windows the largest tile; reference/browser a medium column beside it; chat, email and music get the smallest tiles or the overflow stack."
        }
    }

    /// Priority rank for a category under this intent (lower = more important). The offline tiler
    /// uses this to decide which windows get proper tiles when there are more windows than fit, and
    /// to keep important windows from being demoted to the overflow stack.
    public func priority(categoryId: String) -> Int {
        switch self {
        case .automatic:
            return 0   // pure recency
        case .coding:
            switch categoryId {
            case "editor", "terminal":            return 0
            case "browser", "design":             return 1
            case "reference", "notes":            return 2
            default:                              return 3
            }
        case .communication:
            switch categoryId {
            case "chat", "email":                 return 0
            case "browser", "notes":              return 1
            default:                              return 2
            }
        case .research:
            switch categoryId {
            case "browser", "reference":          return 0
            case "notes":                         return 1
            default:                              return 2
            }
        case .writing:
            switch categoryId {
            case "notes", "reference":            return 0
            case "browser":                       return 1
            default:                              return 2
            }
        }
    }
}
