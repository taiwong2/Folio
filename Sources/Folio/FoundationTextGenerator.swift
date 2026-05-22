import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// `TextGenerator` backed by Apple's on-device Foundation Models framework. Available
/// on iOS 26+/macOS 26+; consumers should check `SystemLanguageModel.default.availability`
/// (or rely on the throwing call) before relying on it on a given device.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationTextGenerator: TextGenerator {
    private let defaultMaxTokens: Int?
    private let defaultTemperature: Double?

    public init(maxTokens: Int? = nil, temperature: Double? = nil) {
        self.defaultMaxTokens = maxTokens
        self.defaultTemperature = temperature
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw NSError(
                domain: "Folio",
                code: 610,
                userInfo: [NSLocalizedDescriptionKey: "FoundationModels unavailable: \(SystemLanguageModel.default.availability)"]
            )
        }

        let (instructions, prompt) = Self.split(messages: request.messages)
        let session = LanguageModelSession(instructions: instructions)

        var options = GenerationOptions()
        if let max = request.maxTokens ?? defaultMaxTokens {
            options.maximumResponseTokens = max
        }
        if let temp = request.temperature ?? defaultTemperature {
            options.temperature = temp
        }

        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }

    /// Splits a Folio `[ChatMessage]` list into a Foundation-style (instructions, prompt)
    /// pair. All `system` messages collapse into instructions; `user` / `assistant` /
    /// `tool` turns are rendered as a labelled transcript ending with the latest user turn.
    private static func split(messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        var instructions: [String] = []
        var transcript: [String] = []
        for message in messages {
            switch message.role {
            case .system:
                instructions.append(message.content)
            case .user:
                transcript.append("User: \(message.content)")
            case .assistant:
                transcript.append("Assistant: \(message.content)")
            case .tool:
                transcript.append("Tool: \(message.content)")
            }
        }
        let promptBody = transcript.joined(separator: "\n\n")
        return (instructions.joined(separator: "\n\n"), promptBody)
    }
}

#endif // canImport(FoundationModels)
