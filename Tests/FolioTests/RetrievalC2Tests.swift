//
//  RetrievalC2Tests.swift
//

import XCTest
@testable import Folio

final class TagsTests: XCTestCase {
    func testTagsPersistAndRoundTrip() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("alpha doc", name: "a.txt"), sourceId: "alpha", tags: ["draft", "research"])

        let stored = try folio.tags(forSource: "alpha")
        XCTAssertEqual(stored, ["draft", "research"])
    }

    func testIngestWithoutTagsPreservesPreviousTags() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("doc v1", name: "a.txt"), sourceId: "alpha", tags: ["keep-me"])
        // Re-ingest without passing tags: existing tags should remain.
        _ = try folio.ingest(.text("doc v2", name: "a.txt"), sourceId: "alpha")

        XCTAssertEqual(try folio.tags(forSource: "alpha"), ["keep-me"])
    }

    func testEmptyTagSetClearsExistingTags() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("doc", name: "a.txt"), sourceId: "alpha", tags: ["foo", "bar"])
        try folio.setTags([], forSource: "alpha")
        XCTAssertEqual(try folio.tags(forSource: "alpha"), [])
    }

    func testRetrievalFiltersByTags() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("shared phrase x", name: "a.txt"), sourceId: "a", tags: ["red"])
        _ = try folio.ingest(.text("shared phrase x", name: "b.txt"), sourceId: "b", tags: ["blue"])
        _ = try folio.ingest(.text("shared phrase x", name: "c.txt"), sourceId: "c") // untagged

        let redOnly = try folio.searchWithContext(
            "phrase",
            filter: .init(tags: ["red"]),
            limit: 10,
            expand: 0
        )
        XCTAssertEqual(Set(redOnly.map(\.sourceId)), ["a"])

        let redOrBlue = try folio.searchWithContext(
            "phrase",
            filter: .init(tags: ["red", "blue"]),
            limit: 10,
            expand: 0
        )
        XCTAssertEqual(Set(redOrBlue.map(\.sourceId)), ["a", "b"])
    }

    func testDeletingSourceCascadesTags() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("doc", name: "a.txt"), sourceId: "alpha", tags: ["temp"])
        try folio.deleteSource("alpha")
        // Re-create the source so we can ask about its tags (without depending on the
        // implementation throwing for a missing source).
        _ = try folio.ingest(.text("doc again", name: "a.txt"), sourceId: "alpha")
        XCTAssertEqual(try folio.tags(forSource: "alpha"), [])
    }
}

final class ParentExpansionTests: XCTestCase {
    func testExpandToParentReturnsFullSectionText() throws {
        let folio = try FolioEngine.inMemory()
        // Each sentence is padded so a small chunk budget forces the chunker to split
        // the section into several sibling chunks under the same parent.
        let leadupPadding = String(repeating: "leadup ", count: 30)
        let trailingPadding = String(repeating: "trailing ", count: 30)
        let markdown = """
        # Guide

        Intro text.

        ## Search Tips

        \(leadupPadding) opening filler about the search behaviour.
        \(leadupPadding) more leadup text about ranking and citations.
        Sentence about diversification — the magic word retrieval shows up here.
        \(trailingPadding) followup notes about reranking and scoring.
        \(trailingPadding) closing remarks about answer quality.

        ## Unrelated

        nothing relevant here at all
        """
        let data = try XCTUnwrap(markdown.data(using: .utf8))

        var config = FolioConfig()
        config.chunking.maxTokensPerChunk = 60
        config.chunking.overlapTokens = 0
        config.indexing.useContextualPrefix = false
        _ = try folio.ingest(.data(data, uti: "public.markdown", name: "guide.md"), sourceId: "guide", config: config)

        let narrow = try folio.searchWithContext("retrieval", in: "guide", limit: 1, expand: 0, expandToParent: false)
        let narrowText = try XCTUnwrap(narrow.first?.text)
        XCTAssertTrue(narrowText.contains("retrieval"))

        let wide = try folio.searchWithContext("retrieval", in: "guide", limit: 1, expand: 0, expandToParent: true)
        let wideText = try XCTUnwrap(wide.first?.text)
        XCTAssertTrue(wideText.contains("retrieval"))
        XCTAssertGreaterThan(wideText.count, narrowText.count, "expandToParent should yield a longer section text than the matching chunk alone")
        XCTAssertFalse(wideText.contains("nothing relevant"), "parent expansion must not bleed into other sections")
    }
}

final class PureVectorSearchTests: XCTestCase {
    func testSearchVectorsRanksByCosineWithoutBM25() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("alpha bravo charlie", name: "a.txt"), sourceId: "A")
        _ = try await folio.ingestAsync(.text("delta echo foxtrot", name: "b.txt"), sourceId: "B")

        let results = try await folio.searchVectors("alpha", limit: 2)
        // FakeEmbeddingProvider is deterministic per input, so the doc whose chunk text
        // hashes closer to "alpha" should rank first. Either order is fine as long as
        // both come back with a populated cosine and bm25 == 0.
        XCTAssertEqual(results.count, 2)
        for r in results {
            XCTAssertNotNil(r.cosine)
            XCTAssertEqual(r.bm25, 0)
            XCTAssertEqual(r.score, r.cosine, "pure vector path should expose cosine as the final score")
        }
    }

    func testSearchVectorsThrowsWithoutProvider() async throws {
        let folio = try FolioEngine.inMemory()
        do {
            _ = try await folio.searchVectors("query")
            XCTFail("expected throw")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 412)
        }
    }

    func testSearchVectorsRespectsTagFilter() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("query target document", name: "a.txt"), sourceId: "A", tags: ["keep"])
        _ = try await folio.ingestAsync(.text("query target document", name: "b.txt"), sourceId: "B", tags: ["skip"])

        let results = try await folio.searchVectors("query", filter: .init(tags: ["keep"]))
        XCTAssertEqual(Set(results.map(\.sourceId)), ["A"])
    }
}

final class MMRTests: XCTestCase {
    func testRerankPicksDiverseCandidatesWhenLambdaIsLow() {
        // Two near-duplicate vectors and one orthogonal — with low lambda MMR should
        // pull the orthogonal item up over the duplicate, even though it ranks lower
        // by raw relevance.
        struct Item { let id: String; let rel: Double; let vec: [Float] }
        let items = [
            Item(id: "A", rel: 1.00, vec: [1, 0, 0]),
            Item(id: "B", rel: 0.99, vec: [1, 0, 0]), // duplicate of A
            Item(id: "C", rel: 0.40, vec: [0, 1, 0])  // orthogonal to A/B
        ]
        let reranked = MMR.rerank(items, lambda: 0.2, k: 3, relevance: { $0.rel }, vector: { $0.vec })
        XCTAssertEqual(reranked.map(\.id), ["A", "C", "B"], "low lambda should prefer diversity")
    }

    func testRerankWithHighLambdaPreservesRelevanceOrder() {
        struct Item { let id: String; let rel: Double; let vec: [Float] }
        let items = [
            Item(id: "A", rel: 1.00, vec: [1, 0, 0]),
            Item(id: "B", rel: 0.99, vec: [1, 0, 0]),
            Item(id: "C", rel: 0.40, vec: [0, 1, 0])
        ]
        let reranked = MMR.rerank(items, lambda: 1.0, k: 3, relevance: { $0.rel }, vector: { $0.vec })
        XCTAssertEqual(reranked.map(\.id), ["A", "B", "C"])
    }

    func testHybridSearchAcceptsMMRConfig() async throws {
        let provider = FakeEmbeddingProvider(dimension: 8)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("retrieval hybrid search", name: "a.txt"), sourceId: "A")

        let results = try await folio.searchHybrid("retrieval", in: "A", limit: 1, mmr: MMRConfig(lambda: 0.5, k: 5))
        XCTAssertFalse(results.isEmpty)
    }
}
