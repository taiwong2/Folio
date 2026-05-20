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
