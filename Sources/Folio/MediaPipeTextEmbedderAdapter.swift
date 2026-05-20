#if canImport(MediaPipeTasksText)
import Foundation
import MediaPipeTasksText

/// Adapter that bridges MediaPipe's `TextEmbedder` to Folio's `EmbeddingProvider` protocol.
///
/// This makes it easy to plug on-device Embedding Gemma models (distributed as
/// MediaPipe text embedders) directly into Folio's ingestion and hybrid search
/// pipeline.
public final class MediaPipeTextEmbedderAdapter: EmbeddingProvider {
    public let model: EmbeddingModelInfo
    private let embedder: TextEmbedder
    private let queue: DispatchQueue

    /// Creates an adapter around a configured MediaPipe `TextEmbedder` instance.
    /// - Parameters:
    ///   - embedder: The underlying MediaPipe text embedder to delegate to.
    ///   - model: The model identity (id + dimension) this embedder produces vectors for.
    ///   - label: Optional label used when serialising calls to the embedder.
    public init(embedder: TextEmbedder, model: EmbeddingModelInfo, label: String = "Folio.MediaPipeTextEmbedderAdapter") {
        self.embedder = embedder
        self.model = model
        self.queue = DispatchQueue(label: label)
    }

    public func embed(_ text: String) async throws -> [Float] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.embedder.embed(text: text)
                    cont.resume(returning: try Self.vector(from: result))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let vectors = try texts.map { text -> [Float] in
                        let result = try self.embedder.embed(text: text)
                        return try Self.vector(from: result)
                    }
                    cont.resume(returning: vectors)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func vector(from result: TextEmbedderResult) throws -> [Float] {
        guard let embedding = result.embeddingResult.embeddings.first else {
            throw NSError(
                domain: "Folio",
                code: 532,
                userInfo: [NSLocalizedDescriptionKey: "TextEmbedder returned no embeddings"]
            )
        }

        if let floats = values(from: embedding, key: "floatEmbedding") {
            return floats
        }

        if let quantized = values(from: embedding, key: "quantizedEmbedding") {
            return quantized
        }

        throw NSError(
            domain: "Folio",
            code: 533,
            userInfo: [NSLocalizedDescriptionKey: "TextEmbedder embedding missing vector payload"]
        )
    }

    private static func values(from embedding: Any, key: String) -> [Float]? {
        guard let object = embedding as AnyObject? else { return nil }

        if let numbers = object.value(forKey: key) as? [NSNumber] {
            return numbers.map { $0.floatValue }
        }

        if let floats = object.value(forKey: key) as? [Float] {
            return floats
        }

        if let doubles = object.value(forKey: key) as? [Double] {
            return doubles.map(Float.init)
        }

        if let bytes = object.value(forKey: key) as? [UInt8] {
            return bytes.map { Float($0) }
        }

        if let data = object.value(forKey: key) as? Data {
            return Array(data).map { Float($0) }
        }

        return nil
    }
}

extension MediaPipeTextEmbedderAdapter: @unchecked Sendable {}

public extension MediaPipeTextEmbedderAdapter {
    /// Loads Google's EmbeddingGemma 300M MediaPipe model from the given path
    /// and returns an adapter pinned to `EmbeddingModelInfo.embeddingGemma300m`
    /// so persisted vectors are validated against the 768-dim contract.
    ///
    /// Obtain a compatible `.task` / `.tflite` file from the
    /// [litert-community/embeddinggemma-300m](https://huggingface.co/litert-community/embeddinggemma-300m)
    /// Hugging Face repo and bundle it with your app.
    static func embeddingGemma300m(modelPath: URL) throws -> MediaPipeTextEmbedderAdapter {
        let options = TextEmbedderOptions()
        options.baseOptions.modelAssetPath = modelPath.path
        let embedder = try TextEmbedder(options: options)
        return MediaPipeTextEmbedderAdapter(embedder: embedder, model: .embeddingGemma300m)
    }
}
#endif
