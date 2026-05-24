import Foundation

/// A single message in a multi-turn conversation handed to a `TextGenerator`.
///
/// Shared by `OpenAIStyleClient`'s chat path and any `TextGenerator` conformance so
/// the same value travels unchanged from caller, through retrieval-augmented
/// prompting, to the backend model.
public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Request payload accepted by every `TextGenerator`. Backends translate this into
/// their own wire format.
public struct GenerationRequest: Sendable {
    public let messages: [ChatMessage]
    public let temperature: Double?
    public let maxTokens: Int?

    public init(messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil) {
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// Synthesises text from a `GenerationRequest`. Backends include OpenAI-compatible
/// HTTP servers, Apple's on-device Foundation Models, preinstalled LiteRT models, or
/// any custom implementation. The contract is purely text-in / text-out so retrieval,
/// citation parsing, and answer assembly stay backend-agnostic.
public protocol TextGenerator: Sendable {
    /// Returns the full completion as a single string.
    func generate(_ request: GenerationRequest) async throws -> String

    /// Streams incremental text fragments. Implementations that lack a native streaming
    /// surface should yield the full completion as one event and then finish.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error>
}

public extension TextGenerator {
    /// Default `stream` implementation for backends that only expose a unary `generate`.
    /// Wraps the single response in a one-element stream so callers can use the same
    /// surface either way.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let text = try await generate(request)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Final output of `FolioEngine.answer()`: the model's text, any citations resolved
/// from inline `[N]` markers, and the underlying retrieval result list (including
/// per-passage scores) so consumers can compute their own confidence policies.
public struct Answer: Sendable {
    public let text: String
    public let citations: [Citation]
    public let usedPassages: [RetrievedResult]

    public init(text: String, citations: [Citation], usedPassages: [RetrievedResult]) {
        self.text = text
        self.citations = citations
        self.usedPassages = usedPassages
    }
}

/// Streaming event emitted by `FolioEngine.answerStream()`. Carries the retrieved
/// passages up front, the model's text in chunks, and a consolidated `Answer` at the end.
public enum AnswerStreamEvent: Sendable {
    case passages([RetrievedResult])
    case text(String)
    case done(Answer)
}

/// Opinionated builder that turns a question plus retrieved passages into the message
/// list a `TextGenerator` consumes. Folio ships one default; consumers can supply
/// their own to change phrasing, language, or citation conventions.
public struct AnswerTemplate: Sendable {
    public typealias Builder = @Sendable (_ question: String, _ passages: [RetrievedResult]) -> [ChatMessage]

    public let build: Builder

    public init(build: @escaping Builder) {
        self.build = build
    }

    /// Default RAG template: a brief system prompt with citation instructions plus
    /// a numbered passage list followed by the user question.
    ///
    /// Uses `passage.text` (the full chunk content, with neighbor expansion if
    /// retrieval enabled it) rather than `passage.excerpt` (FTS5's narrow snippet
    /// window). The excerpt is meant for UI display — it often crops the matched
    /// term itself, which leaves the model staring at incomplete context and
    /// confidently reporting "the document does not mention X".
    public static let `default` = AnswerTemplate { question, passages in
        let system = """
        You are a careful assistant. Answer the user's question using ONLY the passages below.
        Cite supporting passages inline with their numbered markers like [1] or [2].
        If the passages do not contain enough information, say so plainly instead of guessing.
        """

        var context = ""
        for (i, passage) in passages.enumerated() {
            let n = i + 1
            let source = passage.citations.first?.sourceName ?? passage.sourceId
            let section = passage.citations.first?.sectionTitle
            let header = section.map { "\(source) — \($0)" } ?? source
            context += "[\(n)] (\(header))\n\(passage.text)\n\n"
        }
        context += "Question: \(question)"

        return [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: context)
        ]
    }
}

/// Resolves inline `[N]` markers in generated text into a deduplicated, in-order list
/// of `Citation` values drawn from the passages that were sent to the model.
@inline(__always)
func resolveCitationMarkers(in text: String, passages: [RetrievedResult]) -> [Citation] {
    let regex = /\[(\d+)\]/
    var ordered: [Citation] = []
    var seenChunkIds = Set<String>()
    for match in text.matches(of: regex) {
        guard let n = Int(match.output.1), n > 0, n <= passages.count else { continue }
        for citation in passages[n - 1].citations {
            if seenChunkIds.insert(citation.chunkId).inserted {
                ordered.append(citation)
            }
        }
    }
    return ordered
}
