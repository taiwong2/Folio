import Foundation

/// Deterministic in-memory `EmbeddingProvider` intended for tests and examples.
///
/// Produces a stable vector from a simple hash of the input so consumers can write
/// retrieval tests without standing up a real embedder. The vector content is not
/// semantically meaningful — only its shape and determinism are guaranteed.
public struct FakeEmbeddingProvider: EmbeddingProvider {
    public let model: EmbeddingModelInfo

    public init(id: String = "fake-v1", dimension: Int = 3) {
        self.model = EmbeddingModelInfo(id: id, dimension: dimension)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let seed = Float((text.hashValue & 0xff) + 1)
        return (0..<model.dimension).map { Float($0) * 0.01 + seed }
    }
}
