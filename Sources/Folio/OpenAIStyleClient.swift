import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIStyleClient: Sendable {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let apiKey: String?
        public let timeout: TimeInterval
        /// Path appended to `baseURL` for chat completions. Defaults to OpenAI's
        /// `v1/chat/completions`. Override when targeting providers whose
        /// OpenAI-compatible layer lives under a different prefix (e.g. Gemini at
        /// `v1beta/openai/chat/completions`).
        public let chatCompletionsPath: String

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            apiKey: String? = nil,
            timeout: TimeInterval = 60,
            chatCompletionsPath: String = "v1/chat/completions"
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.timeout = timeout
            self.chatCompletionsPath = chatCompletionsPath
        }
    }

    public struct ChatCompletionResponse: Decodable, Sendable {
        public struct Choice: Decodable, Sendable {
            public let index: Int
            public let message: ChatMessage
            public let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        public struct Usage: Decodable, Sendable {
            public let promptTokens: Int?
            public let completionTokens: Int?
            public let totalTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }

        public let id: String
        public let choices: [Choice]
        public let usage: Usage?
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int?
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct ChatCompletionChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta
            let index: Int
        }
        let choices: [Choice]
    }

    private let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .init(), session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    public func chatCompletion(model: String, messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil) async throws -> ChatCompletionResponse {
        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: nil
        )

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 430, userInfo: [NSLocalizedDescriptionKey: "Invalid chat response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Chat completion failed: \(bodyText)"])
        }

        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    /// Streams chat completion deltas using OpenAI's server-sent-events shape.
    /// Yields the `choices[0].delta.content` of each chunk; finishes when the server
    /// emits `data: [DONE]`.
    public func chatCompletionStream(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: true
        )

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = config.timeout
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let finalRequest = request
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw NSError(domain: "Folio", code: 430, userInfo: [NSLocalizedDescriptionKey: "Invalid streaming response"])
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
                        throw NSError(
                            domain: "Folio",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Chat completion failed: \(bodyText)"]
                        )
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line
                            .dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                           let delta = chunk.choices.first?.delta.content,
                           !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    var chatCompletionsURL: URL {
        config.baseURL.appendingPathComponent(config.chatCompletionsPath)
    }
}
