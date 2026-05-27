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
/// from inline `[N]` markers, the underlying retrieval result list (including
/// per-passage scores), and a heuristic `confidence` score in `[0, 1]`.
///
/// `confidence` is the mean fused score (`RetrievedResult.score`) of the passages
/// the model actually cited. It returns `0` when the model emitted no citation
/// markers — that's the strongest cue the answer is ungrounded — and when no
/// passages were retrieved. The score is a heuristic, not a calibrated
/// probability, so callers should treat thresholds as policy choices rather than
/// statistical claims.
public struct Answer: Sendable {
    public let text: String
    public let citations: [Citation]
    public let usedPassages: [RetrievedResult]
    public let confidence: Double

    public init(text: String, citations: [Citation], usedPassages: [RetrievedResult], confidence: Double) {
        self.text = text
        self.citations = citations
        self.usedPassages = usedPassages
        self.confidence = confidence
    }
}

/// Computes the `Answer.confidence` value from the model's text and the passages it
/// was given. Looks up each `[N]` marker against `passages`, averages the fused
/// scores of the unique passages cited, and clamps to `[0, 1]`. Returns `0` when no
/// markers were emitted or no passages exist.
func computeAnswerConfidence(in text: String, passages: [RetrievedResult]) -> Double {
    guard !passages.isEmpty else { return 0 }
    let regex = /\[(\d+)\]/
    var citedScores: [Double] = []
    var seen = Set<Int>()
    for match in text.matches(of: regex) {
        guard let n = Int(match.output.1), n > 0, n <= passages.count else { continue }
        if seen.insert(n).inserted {
            citedScores.append(passages[n - 1].score)
        }
    }
    guard !citedScores.isEmpty else { return 0 }
    let mean = citedScores.reduce(0, +) / Double(citedScores.count)
    return max(0, min(1, mean))
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

        Citation rules (these are required, not optional):
        • Every factual claim must be followed by a numbered marker like [1] or [2] referring to the passage that supports it.
        • If a single sentence draws on multiple passages, list each: "X did Y [1][3]."
        • Answers with no citations will be rejected as ungrounded.

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

    /// Strict variant of `.default` that explicitly instructs the model to emit
    /// the literal token `[NO_ANSWER]` when the passages do not contain enough
    /// information. Pairs with `AnswerPolicy` on `FolioEngine.answer` to turn
    /// that token into a structured refusal.
    public static let strict = AnswerTemplate { question, passages in
        let system = """
        You are a careful assistant. Answer the user's question using ONLY the passages below.

        Citation rules (required):
        • Every factual claim must be followed by a numbered marker like [1] or [2] referring to the passage that supports it.
        • If a single sentence draws on multiple passages, list each: "X did Y [1][3]."

        Refusal rule (critical):
        • If the passages do not contain enough information to answer the question, respond with exactly the token [NO_ANSWER] and nothing else.
        • Do not guess, infer, or fall back to outside knowledge.
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

/// Opt-in safety thresholds applied to a generated `Answer`. Any threshold
/// left as `nil` is not enforced; the default-initialised `AnswerPolicy`
/// preserves the V1 behavior of always returning the model's text.
///
/// When any check trips, `FolioEngine.answer` returns an `Answer` whose
/// `text` is `refusalText`, citations are empty, and `confidence` is `0`.
/// `usedPassages` is still populated so callers can show what was searched.
public struct AnswerPolicy: Sendable {
    /// Reject answers whose `Answer.confidence` (mean fused score of cited
    /// passages) falls below this value. `nil` disables the check.
    public var minConfidence: Double?

    /// Reject answers that resolved zero citations.
    public var requireCitations: Bool

    /// Reject answers whose quoted spans don't appear verbatim in any
    /// cited passage at this rate or higher. `nil` disables.
    public var minQuoteGrounding: Double?

    /// Reject answers whose numeric tokens don't appear in any cited
    /// passage at this rate or higher. `nil` disables.
    public var minNumericConsistency: Double?

    /// The text returned in place of the model's output when any check trips.
    public var refusalText: String

    public init(
        minConfidence: Double? = nil,
        requireCitations: Bool = false,
        minQuoteGrounding: Double? = nil,
        minNumericConsistency: Double? = nil,
        refusalText: String = "I couldn't find that in the provided sources."
    ) {
        self.minConfidence = minConfidence
        self.requireCitations = requireCitations
        self.minQuoteGrounding = minQuoteGrounding
        self.minNumericConsistency = minNumericConsistency
        self.refusalText = refusalText
    }

    /// Permissive default — preserves prior behavior. The `[NO_ANSWER]` token
    /// check is always on regardless of this policy.
    public static let `default` = AnswerPolicy()

    /// Opinionated strict preset: requires citations and a minimum confidence
    /// of 0.3. Suitable when paired with `AnswerTemplate.strict`.
    public static let strict = AnswerPolicy(minConfidence: 0.3, requireCitations: true)
}

/// Decides whether a generated answer should be replaced with a refusal. The
/// `[NO_ANSWER]` token check always runs; threshold checks only run when the
/// corresponding policy field is non-nil.
func shouldRefuseAnswer(
    text: String,
    citations: [Citation],
    confidence: Double,
    passages: [RetrievedResult],
    policy: AnswerPolicy
) -> Bool {
    if text.contains("[NO_ANSWER]") { return true }
    if let min = policy.minConfidence, confidence < min { return true }
    if policy.requireCitations && citations.isEmpty { return true }
    if let min = policy.minQuoteGrounding,
       quoteGrounding(text: text, passages: passages) < min { return true }
    if let min = policy.minNumericConsistency,
       numericConsistency(text: text, passages: passages) < min { return true }
    return false
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
