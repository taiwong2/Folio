import Foundation

/// Pre-configured cloud and local-server presets for the OpenAI-compatible HTTP path.
///
/// Most major providers ship an OpenAI-compatible endpoint, so a single
/// `OpenAIStyleGenerator` adapter covers OpenAI itself, Anthropic, Gemini, Ollama,
/// and anything else that mirrors the `chat/completions` wire shape. Native APIs
/// (Anthropic's `/v1/messages`, Gemini's `generateContent`) are intentionally not
/// covered here — add a dedicated `TextGenerator` conformance when provider-specific
/// features (e.g. Claude prompt caching) are needed.
public enum CloudProvider: Sendable {
    case openAI(model: String, apiKey: String)
    case anthropic(model: String, apiKey: String)
    case gemini(model: String, apiKey: String)
    case ollama(model: String, baseURL: URL = URL(string: "http://127.0.0.1:11434")!)
    case custom(model: String, baseURL: URL, apiKey: String? = nil, chatCompletionsPath: String = "v1/chat/completions")
}

/// `TextGenerator` that delegates to an `OpenAIStyleClient`. Carries a fixed model so
/// callers don't have to pass one with every request.
public struct OpenAIStyleGenerator: TextGenerator {
    public let model: String
    private let client: OpenAIStyleClient

    public init(model: String, client: OpenAIStyleClient = OpenAIStyleClient()) {
        self.model = model
        self.client = client
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        let response = try await client.chatCompletion(
            model: model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        )
        return response.choices.first?.message.content ?? ""
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        client.chatCompletionStream(
            model: model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        )
    }
}

public extension OpenAIStyleGenerator {
    /// Builds a generator pre-wired for a known cloud or local provider. Each case
    /// maps to that provider's OpenAI-compatible base URL and authentication style.
    static func cloud(_ provider: CloudProvider, timeout: TimeInterval = 60, session: URLSession = .shared) -> OpenAIStyleGenerator {
        switch provider {
        case let .openAI(model, apiKey):
            let config = OpenAIStyleClient.Configuration(
                baseURL: URL(string: "https://api.openai.com")!,
                apiKey: apiKey,
                timeout: timeout
            )
            return OpenAIStyleGenerator(model: model, client: OpenAIStyleClient(configuration: config, session: session))

        case let .anthropic(model, apiKey):
            let config = OpenAIStyleClient.Configuration(
                baseURL: URL(string: "https://api.anthropic.com")!,
                apiKey: apiKey,
                timeout: timeout
            )
            return OpenAIStyleGenerator(model: model, client: OpenAIStyleClient(configuration: config, session: session))

        case let .gemini(model, apiKey):
            let config = OpenAIStyleClient.Configuration(
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
                apiKey: apiKey,
                timeout: timeout,
                chatCompletionsPath: "chat/completions"
            )
            return OpenAIStyleGenerator(model: model, client: OpenAIStyleClient(configuration: config, session: session))

        case let .ollama(model, baseURL):
            let config = OpenAIStyleClient.Configuration(
                baseURL: baseURL,
                apiKey: nil,
                timeout: timeout
            )
            return OpenAIStyleGenerator(model: model, client: OpenAIStyleClient(configuration: config, session: session))

        case let .custom(model, baseURL, apiKey, chatCompletionsPath):
            let config = OpenAIStyleClient.Configuration(
                baseURL: baseURL,
                apiKey: apiKey,
                timeout: timeout,
                chatCompletionsPath: chatCompletionsPath
            )
            return OpenAIStyleGenerator(model: model, client: OpenAIStyleClient(configuration: config, session: session))
        }
    }
}
