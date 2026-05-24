//
//  Embedder.swift
//  Folio
//
//  Created by Tai Wong on 9/20/25.
//

import Foundation

public struct EmbeddingModelInfo: Sendable, Hashable, Codable {
    public let id: String
    public let dimension: Int

    public init(id: String, dimension: Int) {
        self.id = id
        self.dimension = dimension
    }
}

public extension EmbeddingModelInfo {
    /// Google EmbeddingGemma 300M — purpose-built on-device text embedding model
    /// derived from Gemma 3. Native 768-dim output (MRL-truncatable to 512/256/128).
    /// Top open model under 500M params on MTEB. Used by `EmbeddingGemmaProvider`,
    /// which runs the Core ML build on the Apple Neural Engine in-process.
    static let embeddingGemma300m = EmbeddingModelInfo(
        id: "embedding-gemma-300m",
        dimension: 768
    )
}

public protocol EmbeddingProvider: Sendable {
    var model: EmbeddingModelInfo { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProvider {
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts {
            out.append(try await embed(t))
        }
        return out
    }
}
