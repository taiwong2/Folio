import Foundation

/// Deterministic `TextGenerator` intended for tests and examples.
///
/// By default echoes the user's question and emits `[1]` whenever at least one
/// numbered passage block is present in the prompt, giving end-to-end tests a way
/// to exercise citation parsing without standing up a real model. Override `respond`
/// to drive bespoke behaviour.
public struct FakeTextGenerator: TextGenerator {
    public typealias Responder = @Sendable (GenerationRequest) -> String

    public let respond: Responder

    public init(respond: @escaping Responder = FakeTextGenerator.defaultResponder) {
        self.respond = respond
    }

    public init(canned text: String) {
        self.respond = { _ in text }
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        respond(request)
    }

    /// Echoes the most recent user message and tacks on `[1]` if the prompt
    /// contains at least one numbered passage block (`[1] (...)`).
    public static let defaultResponder: Responder = { request in
        let userContent = request.messages.last(where: { $0.role == .user })?.content ?? ""
        let hasPassage = userContent.range(of: #"\[1\]\s*\("#, options: .regularExpression) != nil
        if hasPassage {
            return "Answer based on passages [1]."
        }
        return userContent
    }
}
