import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// On-device adapter that talks to a local EmbeddingGemma runtime.
///
/// Folio expects embeddings to be available without reaching out to hosted APIs so apps can
/// ship fully offline if desired. Tools like [Ollama](https://ollama.com) expose Gemma
/// embeddings through a lightweight HTTP server on `localhost`. This adapter keeps the
/// networking surface area small and performs one request per chunk, which matches
/// the streaming nature of many on-device runtimes.
public struct EmbeddingGemmaEmbedder: EmbeddingProvider {
    public struct Configuration: Sendable {
        /// Base URL of the local embedding server. Defaults to Ollama's standard port.
        public var baseURL: URL
        /// Model identifier understood by the runtime (e.g. "gemma:2b" or "gemma:7b" with an embedding template).
        public var model: String
        /// Output vector dimension produced by `model`. Must be declared up front so Folio can
        /// validate every persisted vector against the registered index.
        public var dimension: Int
        /// Optional timeout applied to each request.
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            model: String = "gemma:2b",
            dimension: Int,
            timeout: TimeInterval = 60
        ) {
            self.baseURL = baseURL
            self.model = model
            self.dimension = dimension
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

    public func embed(_ text: String) async throws -> [Float] {
        try await embedSingle(text: text)
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try await embedSingle(text: text))
        }
        return out
    }

    private func embedSingle(text: String) async throws -> [Float] {
        let endpoint = config.baseURL.appendingPathComponent("api/embeddings")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: config.model, input: text))

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 523, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma invalid response"])
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma server error: \(text)"])
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return decoded.embedding.map { Float($0) }
    }
}

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: String
}

private struct EmbeddingResponse: Decodable {
    let embedding: [Double]
}
