import Foundation
import CoreGraphics

/// Turns a display + window snapshot into a concrete `LayoutPlan`, using Claude when a key is
/// available and falling back to a deterministic local tiler otherwise (or on error).
public struct LayoutPlanner: Sendable {

    private let client: ClaudeClient

    public init(client: ClaudeClient = ClaudeClient()) {
        self.client = client
    }

    /// Plan a layout for one display's worth of windows.
    /// - Parameter image: optional base64 PNG screenshot for content-aware tiling.
    /// The planned layout plus the token usage spent producing it (zero when the offline fallback
    /// was used). `error` is set when the AI was expected to run but couldn't, so the UI can show why.
    public struct Outcome: Sendable {
        public let plan: LayoutPlan
        public let usage: TokenUsage
        public let usedAI: Bool
        public let error: String?
    }

    public func plan(
        display: DisplayInfo,
        windows: [ManagedWindow],
        gap: Double,
        model: PlannerModel,
        image: ClaudeClient.ImageBlock?,
        catalog: CategoryCatalog,
        learned: LearnedDimensions = .empty
    ) async -> Outcome {
        func fallback(error: String? = nil) -> Outcome {
            Outcome(
                plan: FallbackTiler.plan(display: display, windows: windows, gap: gap, catalog: catalog, learned: learned),
                usage: .zero, usedAI: false, error: error
            )
        }
        guard !windows.isEmpty else {
            return Outcome(plan: LayoutPlan(displaySignature: display.signature, tiles: []), usage: .zero, usedAI: false, error: nil)
        }

        // Without a key we never hit the network — use the offline fallback directly.
        guard Keychain.hasAPIKey else { return fallback() }

        do {
            let result = try await client.requestLayout(
                model: model.rawValue,
                system: Prompt.system,
                userText: Prompt.userText(display: display, windows: windows, gap: gap, catalog: catalog, learned: learned),
                toolName: "emit_layout",
                toolSchema: Prompt.layoutToolSchema,
                image: image
            )
            let tiles = try parseTiles(from: result.toolInput, windows: windows, clampingTo: display.visibleFrame, catalog: catalog, learned: learned)
            // If the model somehow returned nothing usable, fall back rather than leaving windows put.
            guard !tiles.isEmpty else { return fallback(error: "AI returned an empty layout") }
            return Outcome(plan: LayoutPlan(displaySignature: display.signature, tiles: tiles), usage: result.usage, usedAI: true, error: nil)
        } catch {
            let message = (error as? ClaudeClient.ClientError)?.errorDescription ?? error.localizedDescription
            NSLog("[Tessera] LLM planning failed, using fallback: \(message)")
            return fallback(error: message)
        }
    }

    /// Parse the tool output into tiles, mapping `window_id` back to our windows and clamping each
    /// frame into the usable area so a hallucinated coordinate can't shove a window off-screen.
    private func parseTiles(
        from input: [String: Any],
        windows: [ManagedWindow],
        clampingTo bounds: CGRect,
        catalog: CategoryCatalog,
        learned: LearnedDimensions
    ) throws -> [Tile] {
        guard let rawTiles = input["tiles"] as? [[String: Any]] else {
            throw ClaudeClient.ClientError.decoding("missing tiles array")
        }
        let byId = Dictionary(uniqueKeysWithValues: windows.map { ($0.id.uuidString, $0) })

        var tiles: [Tile] = []
        for raw in rawTiles {
            guard let idString = raw["window_id"] as? String,
                  let window = byId[idString],
                  let x = (raw["x"] as? NSNumber)?.doubleValue,
                  let y = (raw["y"] as? NSNumber)?.doubleValue,
                  let w = (raw["width"] as? NSNumber)?.doubleValue,
                  let h = (raw["height"] as? NSNumber)?.doubleValue
            else { continue }

            // Safety net: even if the model ignores the instruction, never let a window exceed its
            // max reasonable width/height. Trim from the right and bottom so the tile keeps its
            // top-left corner (preserving the top-left-anchored arrangement).
            let maxW = catalog.maxWidth(id: window.categoryId, bundleId: window.bundleId, usableWidth: bounds.width, learned: learned)
            let maxH = catalog.maxHeight(id: window.categoryId, bundleId: window.bundleId, usableHeight: bounds.height, learned: learned)
            let rect = CGRect(x: x, y: y, width: min(w, maxW), height: min(h, maxH))
            tiles.append(Tile(windowId: window.id, frame: clamp(rect, to: bounds)))
        }
        return tiles
    }

    /// Keep a frame inside `bounds`, preserving size where possible.
    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
