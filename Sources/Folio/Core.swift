//
//  Core.swift
//  Folio
//
//  Created by Tai Wong on 9/13/25.
//

import Foundation


///Common Data Types
public struct Chunk: Sendable, Hashable {
    public let id: String?
    public let sourceId: String
    public let page: Int?
    public let text: String
    public let tags: Set<String>
    public let ordinal: Int
    public let sectionTitle: String?
    public let parentId: String?
    public let contentHash: String?
    
    public init(
        id: String? = nil,
        sourceId: String,
        page: Int?,
        text: String,
        tags: Set<String> = [],
        ordinal: Int = 0,
        sectionTitle: String? = nil,
        parentId: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id; self.sourceId = sourceId; self.page = page; self.text = text; self.tags = tags; self.ordinal = ordinal; self.sectionTitle = sectionTitle; self.parentId = parentId; self.contentHash = contentHash
    }
}

public struct LoadedPage: Sendable {
    public let index: Int
    public let text: String
    
    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

public struct LoadedDocument: Sendable {
    public let name: String
    public let pages: [LoadedPage]
    
    public init(name: String, pages: [LoadedPage]) {
        self.name = name
        self.pages = pages
    }
}

public enum IngestInput {
    case pdf(URL)
    case text(String, name: String?)
    case data(Data, uti: String, name: String?)
}

/// Cooperative-cancellation + progress signalling for long ingests.
///
/// Each call reports the phase (`.loading`, `.chunking`, `.embedding`) plus the
/// number of completed/total work units. During `.loading`/`.chunking` the unit
/// is a page; during `.embedding` it's a chunk. `total` is `nil` until the
/// chunker has produced its full list and the total chunk count is known.
public struct IngestProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case loading
        case chunking
        case embedding
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int?

    public init(phase: Phase, completed: Int, total: Int?) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public typealias IngestProgressHandler = @Sendable (IngestProgress) -> Void

public struct ChunkingConfig: Sendable {
    public var maxTokensPerChunk = 650
    public var overlapTokens = 80
    public init() {}
    
}

///Extension Points
public protocol DocumentLoader {
    func supports(_ input: IngestInput) -> Bool
    func load(_ input: IngestInput) throws -> LoadedDocument
}

public protocol Chunker {
    func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk]
}
