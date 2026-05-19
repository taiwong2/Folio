//
//  DocChunkStore.swift
//  DataKit
//
//  Created by Tai Wong on 9/2/25.
//

import Foundation
import GRDB
import CryptoKit

public struct Snippet: Codable, Hashable, Sendable {
    public let sourceId: String
    public let page: Int?
    public let excerpt: String
    public let score: Double
}

public struct Source: Equatable, Hashable, Codable {
    public let id: String
    public let filePath: String
    public let displayName: String
    public let pages: Int?
    public let chunks: Int
    public let importedAt: String
    public let url: String?
    public let uti: String?
    public let fileType: String?
    public let updatedAt: String
}

extension DocChunkStore {
    
    public struct SnippetHit: Sendable, Hashable {
        public let rowid: Int64
        public let chunkId: String
        public let sourceId: String
        public let sourceDisplayName: String
        public let sourceFileType: String?
        public let page: Int?
        public let sectionTitle: String?
        public let excerpt: String
        public let bm25: Double
    }

    public struct NeighborChunk: Sendable {
        public let rowid: Int64
        public let chunkId: String
        public let text: String
        public let page: Int?
        public let sectionTitle: String?
        public let parentId: String?
    }

    public struct VectorRow: Sendable {
        public let rowid: Int64
        public let chunkId: String
        public let dim: Int
        public let vec: [Float]
    }

    public struct EmbeddableChunk: Sendable {
        public let rowid: Int64
        public let chunkId: String
        public let sourceId: String
        public let page: Int?
        public let text: String
        public let contextPrefix: String
        public let ftsContent: String

        public var embeddingText: String {
            if !ftsContent.isEmpty { return ftsContent }
            if contextPrefix.isEmpty { return text }
            return contextPrefix + text
        }
    }

    public struct ChunkIdentifier: Sendable, Hashable {
        public let rowid: Int64
        public let chunkId: String
    }
    
    func contentHash(for content: String) -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    func deterministicChunkId(sourceId: String, ordinal: Int, contentHash: String) -> String {
        "\(sourceId):\(ordinal):\(String(contentHash.prefix(16)))"
    }
    
    func cacheKey(sourceId: String, page: Int?, chunk:String) -> String {
        let base = "\(sourceId)|\(page ?? -1)|\(chunk)"
        let d = SHA256.hash(data: Data(base.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
    
    func getCachedPrefix(for key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM prefix_cache WHERE key = ?", arguments: [key])
        }
    }
    
    func putCachedPrefix(key: String, value: String, metaJSON: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO prefix_cache(key, value, meta)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, meta=excluded.meta
                """,
                arguments: [key, value, metaJSON]
            )
        }
    }
    
    func ftsHits(query: String, inSource source: String? = nil, filter: RetrievalFilter = .init(), limit: Int = 10) throws -> [SnippetHit] {
        try dbQueue.read { db in
            var sql = """
            SELECT
              d.rowid AS rowid,
              d.id AS chunk_id,
              d.source_id AS source_id,
              s.display_name AS source_display_name,
              s.file_type AS source_file_type,
              d.page AS page,
              d.section_title AS section_title,
              REPLACE(
                snippet(doc_chunks_fts, 0, '', '', '…', 18),
                COALESCE(d.context_prefix || ' ', ''),
                ''
              ) AS excerpt,
              bm25(doc_chunks_fts) AS score
            FROM doc_chunks AS d
            JOIN sources AS s ON s.id = d.source_id
            JOIN doc_chunks_fts ON doc_chunks_fts.rowid = d.rowid
            WHERE doc_chunks_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [query]

            if let s = source {
                sql += " AND d.source_id = ?"
                args.append(s)
            }

            appendFilterSQL(filter, sql: &sql, args: &args)

            sql += " ORDER BY score LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map {
                SnippetHit(
                    rowid: $0["rowid"],
                    chunkId: $0["chunk_id"],
                    sourceId: $0["source_id"],
                    sourceDisplayName: $0["source_display_name"],
                    sourceFileType: $0["source_file_type"],
                    page: $0["page"],
                    sectionTitle: $0["section_title"],
                    excerpt: $0["excerpt"],
                    bm25: $0["score"]
                )
            }
        }
    }
    
    func fetchNeighbors(sourceId: String, around rowid: Int64, expand: Int) throws -> [NeighborChunk] {
        try dbQueue.read { db in
            let prevRows = try Row.fetchAll(db, sql: """
                SELECT rowid, id AS chunk_id, content, page, section_title, parent_id
                FROM doc_chunks
                WHERE source_id = ? AND rowid < ?
                ORDER BY rowid DESC
                LIMIT ?
            """, arguments: [sourceId, rowid, expand]).reversed()

            let nextRows = try Row.fetchAll(db, sql: """
                SELECT rowid, id AS chunk_id, content, page, section_title, parent_id
                FROM doc_chunks
                WHERE source_id = ? AND rowid >= ?
                ORDER BY rowid ASC
                LIMIT ?
            """, arguments: [sourceId, rowid, expand + 1])

            let toChunk: (Row) -> NeighborChunk = { r in
                NeighborChunk(rowid: r["rowid"], chunkId: r["chunk_id"], text: r["content"], page: r["page"], sectionTitle: r["section_title"], parentId: r["parent_id"])
            }
            return prevRows.map(toChunk) + nextRows.map(toChunk)
        }
    }

    func fetchAllChunks(forSourceId sourceId: String) throws -> [NeighborChunk] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, id AS chunk_id, content, page, section_title, parent_id
                FROM doc_chunks
                WHERE source_id = ?
                ORDER BY rowid ASC
            """, arguments: [sourceId])

            return rows.map { row in
                NeighborChunk(
                    rowid: row["rowid"],
                    chunkId: row["chunk_id"],
                    text: row["content"],
                    page: row["page"],
                    sectionTitle: row["section_title"],
                    parentId: row["parent_id"]
                )
            }
        }
    }

    func fetchChunks(forSourceId sourceId: String, startingFromPage startPage: Int) throws -> [NeighborChunk] {
        try dbQueue.read { db in
            guard let pivotRowid = try Int64.fetchOne(
                db,
                sql: """
                    SELECT rowid
                    FROM doc_chunks
                    WHERE source_id = ? AND COALESCE(page, 0) >= ?
                    ORDER BY rowid ASC
                    LIMIT 1
                """,
                arguments: [sourceId, startPage]
            ) else {
                return []
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, id AS chunk_id, content, page, section_title, parent_id
                FROM doc_chunks
                WHERE source_id = ? AND rowid >= ?
                ORDER BY rowid ASC
            """, arguments: [sourceId, pivotRowid])

            return rows.map { row in
                NeighborChunk(
                    rowid: row["rowid"],
                    chunkId: row["chunk_id"],
                    text: row["content"],
                    page: row["page"],
                    sectionTitle: row["section_title"],
                    parentId: row["parent_id"]
                )
            }
        }
    }

    func findAnchorRowid(sourceId: String, anchor: String) throws -> Int64? {
        guard !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT rowid
                    FROM doc_chunks
                    WHERE source_id = ?
                      AND instr(lower(content), lower(?)) > 0
                    ORDER BY rowid ASC
                    LIMIT 1
                """,
                arguments: [sourceId, anchor]
            )
        }
    }

    func insertReturningIdentifiers(
        chunkId: String? = nil,
        sourceId: String,
        ordinal: Int,
        page: Int?,
        content: String,
        sectionTitle: String? = nil,
        contextPrefix: String? = nil,
        parentId: String? = nil,
        contentHash: String? = nil,
        ftsContent: String? = nil
    ) throws -> ChunkIdentifier {
        try dbQueue.write { db in
            let hash = contentHash ?? self.contentHash(for: content)
            let id = chunkId ?? self.deterministicChunkId(sourceId: sourceId, ordinal: ordinal, contentHash: hash)

            try db.execute(sql: """
              INSERT INTO doc_chunks (id, source_id, ordinal, page, content, section_title, context_prefix, parent_id, content_hash)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, sourceId, ordinal, page, content, sectionTitle, contextPrefix, parentId, hash])

            try db.execute(sql: """
              INSERT INTO doc_chunks_fts(rowid, content, source_id, section_title)
              VALUES (
                (SELECT rowid FROM doc_chunks WHERE id = ?),
                ?, ?, ?
              )
            """, arguments: [id, ftsContent ?? content, sourceId, sectionTitle])

            let rowid = try Int64.fetchOne(db,
                sql: "SELECT rowid FROM doc_chunks WHERE id = ?",
                arguments: [id]
            )!

            return ChunkIdentifier(rowid: rowid, chunkId: id)
        }
    }

    func insertVector(chunkId: String, dim: Int, vector: [Float]) throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try dbQueue.write { db in
            try db.execute(sql: """
              INSERT INTO doc_chunk_vectors(chunk_id, dim, vec) VALUES (?, ?, ?)
              ON CONFLICT(chunk_id) DO UPDATE SET dim=excluded.dim, vec=excluded.vec
            """, arguments: [chunkId, dim, data])
        }
    }

    func fetchVectors(forRowids rowids: [Int64]) throws -> [VectorRow] {
        guard !rowids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: rowids.count).joined(separator: ",")
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.rowid AS rowid, d.id AS chunk_id, v.dim, v.vec
                    FROM doc_chunks AS d
                    JOIN doc_chunk_vectors AS v ON v.chunk_id = d.id
                    WHERE d.rowid IN (\(placeholders))
                """,
                arguments: StatementArguments(rowids)
            )
            return rows.map { r in
                let dim: Int = r["dim"]
                let data: Data = r["vec"]
                var arr = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
                _ = arr.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                return VectorRow(rowid: r["rowid"], chunkId: r["chunk_id"], dim: dim, vec: arr)
            }
        }
    }

    func fetchEmbeddableChunks(for sourceId: String?, limit: Int) throws -> [EmbeddableChunk] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            var sql = """
                SELECT
                  d.rowid,
                  d.id AS chunk_id,
                  d.source_id,
                  d.page,
                  d.content,
                  COALESCE(d.section_title, '') AS section_title,
                  COALESCE(d.context_prefix, '') AS context_prefix,
                  f.content AS fts_content
                FROM doc_chunks AS d
                JOIN doc_chunks_fts AS f ON f.rowid = d.rowid
                LEFT JOIN doc_chunk_vectors AS v ON v.chunk_id = d.id
                WHERE v.chunk_id IS NULL
            """
            var args: [DatabaseValueConvertible] = []

            if let sourceId {
                sql += " AND (d.source_id = ? OR d.source_id LIKE ?)"
                args.append(contentsOf: [sourceId, "\(sourceId) p.%"])
            }

            sql += " ORDER BY d.rowid LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                EmbeddableChunk(
                    rowid: row["rowid"],
                    chunkId: row["chunk_id"],
                    sourceId: row["source_id"],
                    page: row["page"],
                    text: row["content"],
                    contextPrefix: row["context_prefix"] ?? "",
                    ftsContent: row["fts_content"] ?? row["content"]
                )
            }
        }
    }

}


internal struct DocChunkStore {
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func insert(
        chunkId: String? = nil,
        sourceId: String,
        ordinal: Int,
        page: Int?,
        content: String,
        sectionTitle: String? = nil,
        contextPrefix: String? = nil,
        parentId: String? = nil,
        contentHash: String? = nil,
        ftsContent: String? = nil
    ) throws {
        try dbQueue.write { db in
            let hash = contentHash ?? self.contentHash(for: content)
            let id = chunkId ?? self.deterministicChunkId(sourceId: sourceId, ordinal: ordinal, contentHash: hash)
            try db.execute(sql: """
              INSERT INTO doc_chunks (id, source_id, ordinal, page, content, section_title, context_prefix, parent_id, content_hash)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, sourceId, ordinal, page, content, sectionTitle, contextPrefix, parentId, hash])

            try db.execute(sql: """
              INSERT INTO doc_chunks_fts(rowid, content, source_id, section_title)
              VALUES (
                (SELECT rowid FROM doc_chunks WHERE id = ?),
                ?, ?, ?
              )
            """, arguments: [id, ftsContent ?? content, sourceId, sectionTitle])
        }
    }

    func ftsSnippets(query: String, inSource source: String? = nil, filter: RetrievalFilter = .init(), limit: Int = 10) throws -> [Snippet] {
        try dbQueue.read { db in
            var sql = """
                SELECT d.source_id, d.page, snippet(doc_chunks_fts, 0, '', '', '…', 18) AS excerpt, bm25(doc_chunks_fts) AS score
                FROM doc_chunks AS d
                JOIN sources AS s ON s.id = d.source_id
                JOIN doc_chunks_fts ON doc_chunks_fts.rowid = d.rowid
                WHERE doc_chunks_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [query]

            if let s = source {
                sql += " AND (d.source_id = ? OR d.source_id LIKE ?)"
                args.append(contentsOf: [s, "\(s) p.%"])
            }

            appendFilterSQL(filter, sql: &sql, args: &args)

            sql += " ORDER BY score LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            
            return rows.map {
                Snippet(
                    sourceId: $0["source_id"],
                    page: $0["page"],
                    excerpt: $0["excerpt"],
                    score: $0["score"]
                )
            }
        }
    }


    func upsertSource(
        id: String,
        filePath: String,
        displayName: String,
        url: String? = nil,
        uti: String? = nil,
        fileType: String? = nil,
        pages: Int?,
        chunks: Int
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
              INSERT INTO sources (id, file_path, display_name, url, uti, file_type, pages, chunks, imported_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
              ON CONFLICT(id) DO UPDATE SET
                file_path=excluded.file_path,
                display_name=excluded.display_name,
                url=excluded.url,
                uti=excluded.uti,
                file_type=excluded.file_type,
                pages=excluded.pages,
                chunks=excluded.chunks,
                updated_at=excluded.updated_at
            """, arguments: [id, filePath, displayName, url, uti, fileType, pages, chunks])
        }
    }

    func listSources() throws -> [Source] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
              SELECT id, file_path, display_name, url, uti, file_type, pages, chunks,
                     COALESCE(imported_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) AS imported_at,
                     COALESCE(updated_at, imported_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) AS updated_at
              FROM sources ORDER BY imported_at DESC
            """).map { row in
                Source(
                    id: row["id"], filePath: row["file_path"], displayName: row["display_name"],
                    pages: row["pages"], chunks: row["chunks"], importedAt: row["imported_at"],
                    url: row["url"], uti: row["uti"], fileType: row["file_type"], updatedAt: row["updated_at"]
                )
            }
        }
    }

    func fetchSource(id: String) throws -> Source? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, file_path, display_name, url, uti, file_type, pages, chunks,
                           COALESCE(imported_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) AS imported_at,
                           COALESCE(updated_at, imported_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) AS updated_at
                    FROM sources
                    WHERE id = ?
                    LIMIT 1
                """,
                arguments: [id]
            ).map { row in
                Source(
                    id: row["id"],
                    filePath: row["file_path"],
                    displayName: row["display_name"],
                    pages: row["pages"],
                    chunks: row["chunks"],
                    importedAt: row["imported_at"],
                    url: row["url"],
                    uti: row["uti"],
                    fileType: row["file_type"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    func deleteChunks(forSourceId base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id = ? OR source_id LIKE ?", arguments: [base, "\(base) p.%"])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }

    func deleteSource(id base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id = ? OR source_id LIKE ?", arguments: [base, "\(base) p.%"])
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [base])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }
}

private func appendFilterSQL(_ filter: RetrievalFilter, sql: inout String, args: inout [DatabaseValueConvertible]) {
    if let sourceIds = filter.sourceIds, !sourceIds.isEmpty {
        let ids = sourceIds.sorted()
        sql += " AND d.source_id IN (\(placeholders(count: ids.count)))"
        args.append(contentsOf: ids)
    }

    if let fileTypes = filter.fileTypes, !fileTypes.isEmpty {
        let types = fileTypes.sorted()
        sql += " AND s.file_type IN (\(placeholders(count: types.count)))"
        args.append(contentsOf: types)
    }

    if let pageRange = filter.pageRange {
        sql += " AND d.page BETWEEN ? AND ?"
        args.append(pageRange.lowerBound)
        args.append(pageRange.upperBound)
    }
}

private func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
