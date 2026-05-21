import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `EmbeddingProvider` that POSTs to an OpenAI-compatible `/v1/embeddings` endpoint.
///
/// Works against OpenAI directly, any hosted provider that mirrors the OpenAI embeddings
/// shape, or local servers such as Ollama's OpenAI-compatible mode (`http://127.0.0.1:11434`).
/// Batches all inputs into a single request to keep network overhead down.
public struct OpenAIStyleEmbedder: EmbeddingProvider {
    public struct Configuration: Sendable {
        /// Base URL of the embedding server. `/v1/embeddings` is appended.
        public var baseURL: URL
        /// Model identifier understood by the server (e.g. `"text-embedding-3-small"`).
        public var model: String
        /// Output vector dimension produced by `model`. Must be declared so Folio can
        /// validate every persisted vector against the registered index.
        public var dimension: Int
        /// Optional bearer token. Required for hosted providers like OpenAI; omit for
        /// local runtimes that don't require auth.
        public var apiKey: String?
        /// Per-request timeout.
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            model: String,
            dimension: Int,
            apiKey: String? = nil,
            timeout: TimeInterval = 60
        ) {
            self.baseURL = baseURL
            self.model = model
            self.dimension = dimension
            self.apiKey = apiKey
            self.timeout = timeout
        }
    }

    public let model: EmbeddingModelInfo
    private let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.config = configuration
        self.session = session
        self.model = EmbeddingModelInfo(id: configuration.model, dimension: configuration.dimension)
    }

    var embeddingsURL: URL {
        config.baseURL.appendingPathComponent("v1/embeddings")
    }

    public func embed(_ text: String) async throws -> [Float] {
        let vectors = try await postEmbeddings(inputs: [text])
        guard let first = vectors.first else {
            throw NSError(domain: "Folio", code: 540, userInfo: [NSLocalizedDescriptionKey: "OpenAIStyleEmbedder returned no vectors"])
        }
        return first
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await postEmbeddings(inputs: texts)
    }

    private func postEmbeddings(inputs: [String]) async throws -> [[Float]] {
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(EmbeddingsRequest(model: config.model, input: inputs))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 541, userInfo: [NSLocalizedDescriptionKey: "OpenAIStyleEmbedder invalid response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAIStyleEmbedder server error: \(bodyText)"])
        }

        let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
        let sorted = decoded.data.sorted { $0.index < $1.index }
        return sorted.map { item in item.embedding.map(Float.init) }
    }
}

private struct EmbeddingsRequest: Encodable {
    let model: String
    let input: [String]
}

private struct EmbeddingsResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
        let index: Int
    }
    let data: [Item]
}
