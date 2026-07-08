import Foundation

/// Calls the Claude Messages API directly over `URLSession` (there is no first-party Swift SDK).
/// Structured output is obtained via a forced tool call (`tool_choice: {type: tool}`), which is the
/// most robust way to get strict JSON back across model versions.
public struct ClaudeClient: Sendable {

    public enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)
        case noToolUse
        case decoding(String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No Anthropic API key set. Add one in Tessera ▸ Settings."
            case let .http(status, body): return "Claude API error \(status): \(body)"
            case .noToolUse: return "Claude did not return a layout."
            case let .decoding(msg): return "Could not read Claude's layout: \(msg)"
            case let .transport(msg): return "Network error talking to Claude: \(msg)"
            }
        }
    }

    /// An image block to attach (base64 PNG).
    public struct ImageBlock: Sendable {
        public let base64PNG: String
        public init(base64PNG: String) { self.base64PNG = base64PNG }
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The structured tool output plus the token usage the call consumed. Not `Sendable` — the
    /// `toolInput` dictionary is consumed in the same nonisolated context that made the call.
    public struct Result {
        public let toolInput: [String: Any]
        public let usage: TokenUsage
    }

    /// Send a planning request and return the raw JSON object emitted by the named tool, plus the
    /// token usage reported by the API.
    public func requestLayout(
        model: String,
        system: String,
        userText: String,
        toolName: String,
        toolSchema: [String: Any],
        image: ImageBlock? = nil,
        maxTokens: Int = 2048
    ) async throws -> Result {
        guard let apiKey = Keychain.apiKey() else { throw ClientError.missingAPIKey }

        var userContent: [[String: Any]] = []
        if let image {
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": image.base64PNG,
                ],
            ])
        }
        userContent.append(["type": "text", "text": userText])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
            "tools": [[
                "name": toolName,
                "description": "Emit the final window layout.",
                "input_schema": toolSchema,
            ]],
            "tool_choice": ["type": "tool", "name": toolName],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30   // don't let a hung call pin tiling for the 60s default
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Error bodies look like {"type":"error","error":{"type":…,"message":…}} — surface just
            // the human-readable message, falling back to the raw body when it doesn't parse.
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = root["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw ClientError.http(status: http.statusCode, body: message)
            }
            throw ClientError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        // Parse the response: find the first tool_use block and return its `input` + usage.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw ClientError.decoding("unexpected response shape")
        }
        let usageObj = root["usage"] as? [String: Any]
        let usage = TokenUsage(
            input: (usageObj?["input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: (usageObj?["output_tokens"] as? NSNumber)?.intValue ?? 0
        )
        for block in content {
            if (block["type"] as? String) == "tool_use",
               let input = block["input"] as? [String: Any] {
                return Result(toolInput: input, usage: usage)
            }
        }
        throw ClientError.noToolUse
    }
}
