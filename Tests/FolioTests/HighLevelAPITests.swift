//
//  HighLevelAPITests.swift
//

import XCTest
@testable import Folio

final class ConvenienceAPITests: XCTestCase {

    func testIngestTextWrapperUsesNameAsSourceId() throws {
        let folio = try FolioEngine.inMemory()
        let id = try folio.ingest(text: "convenience body", name: "note.txt")
        XCTAssertEqual(id, "note.txt")

        let sources = try folio.listSources()
        XCTAssertTrue(sources.contains(where: { $0.id == "note.txt" }))
    }

    func testIngestURLDerivesSourceIdFromLastPathComponent() throws {
        let folio = try FolioEngine.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("rag-notes.md")
        try "# Notes\n\nbody about retrieval".data(using: .utf8)?.write(to: url)

        let id = try folio.ingest(url: url)
        XCTAssertEqual(id, "rag-notes.md")

        let hits = try folio.search("retrieval", in: id, limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }

    func testRetrieveUsesHybridWhenProviderConfigured() async throws {
        let provider = FakeEmbeddingProvider(dimension: 4)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("retrieval anchor", name: "rag.txt"), sourceId: "rag")

        let results = try await folio.retrieve("retrieval", in: "rag")
        let first = try XCTUnwrap(results.first)
        XCTAssertNotNil(first.cosine, "hybrid path should produce a cosine when a provider is configured")
    }

    func testRetrieveFallsBackToLexicalWhenNoProvider() async throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("retrieval anchor", name: "rag.txt"), sourceId: "rag")

        let results = try await folio.retrieve("retrieval", in: "rag")
        let first = try XCTUnwrap(results.first)
        XCTAssertNil(first.cosine, "lexical fallback should not invent a cosine")
        XCTAssertEqual(first.score, first.bm25)
    }
}

final class AnswerConfidenceTests: XCTestCase {

    private func makePassage(score: Double, n: Int = 1) -> RetrievedResult {
        RetrievedResult(
            sourceId: "s\(n)",
            startPage: nil,
            excerpt: "",
            text: "",
            bm25: 0,
            cosine: nil,
            score: score,
            citations: []
        )
    }

    func testNoCitationsYieldsZeroConfidence() {
        let passages = [makePassage(score: 0.9, n: 1), makePassage(score: 0.7, n: 2)]
        let c = computeAnswerConfidence(in: "no markers here", passages: passages)
        XCTAssertEqual(c, 0)
    }

    func testSingleCitationUsesThatPassageScore() {
        let passages = [makePassage(score: 0.8)]
        let c = computeAnswerConfidence(in: "Some claim [1].", passages: passages)
        XCTAssertEqual(c, 0.8, accuracy: 1e-9)
    }

    func testMultipleCitationsAreAveragedAndDeduped() {
        let passages = [makePassage(score: 0.9, n: 1), makePassage(score: 0.5, n: 2)]
        // Repeated marker [1] should not double-count.
        let c = computeAnswerConfidence(in: "A [1]. B [1][2].", passages: passages)
        XCTAssertEqual(c, 0.7, accuracy: 1e-9)
    }

    func testOutOfBoundsMarkersAreIgnored() {
        let passages = [makePassage(score: 0.6)]
        let c = computeAnswerConfidence(in: "claim [1] and bogus [99].", passages: passages)
        XCTAssertEqual(c, 0.6, accuracy: 1e-9)
    }

    func testEmptyPassagesYieldsZero() {
        let c = computeAnswerConfidence(in: "claim [1].", passages: [])
        XCTAssertEqual(c, 0)
    }

    func testEngineAnswerPopulatesConfidence() async throws {
        let folio = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 4),
            textGenerator: FakeTextGenerator()
        )
        _ = try await folio.ingestAsync(.text("retrieval grounds the answer", name: "rag.txt"), sourceId: "rag")

        let answer = try await folio.answer("retrieval?", in: "rag")
        XCTAssertTrue(answer.text.contains("[1]"))
        XCTAssertGreaterThan(answer.confidence, 0, "FakeTextGenerator emits a [1] marker — confidence should be > 0")
    }
}
