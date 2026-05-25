// Tests/FolioTests/FolioSmokeTests.swift
import XCTest
@testable import Folio

final class FolioSmokeTests: XCTestCase {
    func testTextIngestAndSearch() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("hello world from folio", name: "note.txt"), sourceId: "T1")
        let hits = try folio.search("hello", in: "T1", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }

    func testNormalizeRemovesHyphenWraps() throws {
        let loader = TextDocumentLoader()
        let document = try loader.load(.text("multi-\nline\nre-entry", name: "mock.pdf"))

        guard let text = document.pages.first?.text else {
            XCTFail("Missing normalized text")
            return
        }

        XCTAssertEqual(text, "multiline\nre-entry")
    }

    func testOpenAIStyleClientDefaultURLDoesNotDuplicateV1() {
        let client = OpenAIStyleClient()
        XCTAssertEqual(client.chatCompletionsURL.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testOpenAIStyleEmbedderDefaultURLDoesNotDuplicateV1() {
        let embedder = OpenAIStyleEmbedder(configuration: .init(model: "text-embedding-3-small", dimension: 1536))
        XCTAssertEqual(embedder.embeddingsURL.absoluteString, "http://127.0.0.1:11434/v1/embeddings")
        XCTAssertEqual(embedder.model.id, "text-embedding-3-small")
        XCTAssertEqual(embedder.model.dimension, 1536)
    }

    func testReingestingSameSourceKeepsStableChunkIds() throws {
        let folio = try FolioEngine.inMemory()
        let text = "First paragraph about stable chunks. Second paragraph about citations."

        _ = try folio.ingest(.text(text, name: "note.txt"), sourceId: "stable")
        let first = try folio.fetchDocument(sourceId: "stable")

        _ = try folio.ingest(.text(text, name: "note.txt"), sourceId: "stable")
        let second = try folio.fetchDocument(sourceId: "stable")

        XCTAssertFalse(first.chunkIds.isEmpty)
        XCTAssertEqual(first.chunkIds, second.chunkIds)
    }

    func testTextSourceStoresV1Metadata() throws {
        let folio = try FolioEngine.inMemory()

        _ = try folio.ingest(.text("metadata matters", name: "note.txt"), sourceId: "meta")

        let source = try XCTUnwrap(folio.listSources().first { $0.id == "meta" })
        XCTAssertEqual(source.displayName, "note.txt")
        XCTAssertEqual(source.filePath, "note.txt")
        XCTAssertEqual(source.uti, "public.plain-text")
        XCTAssertEqual(source.fileType, "text")
        XCTAssertEqual(source.pages, 1)
        XCTAssertEqual(source.chunks, 1)
        XCTAssertFalse(source.importedAt.isEmpty)
        XCTAssertFalse(source.updatedAt.isEmpty)
    }

    func testMarkdownIngestStoresHeadingCitations() throws {
        let folio = try FolioEngine.inMemory()
        let markdown = """
        # Guide

        Intro text.

        ## Installation

        Use retrieval carefully for cited passages.
        """
        let data = try XCTUnwrap(markdown.data(using: .utf8))

        _ = try folio.ingest(.data(data, uti: "public.markdown", name: "guide.md"), sourceId: "guide")

        let source = try XCTUnwrap(folio.listSources().first { $0.id == "guide" })
        XCTAssertEqual(source.fileType, "markdown")
        XCTAssertEqual(source.uti, "public.markdown")

        let passages = try folio.searchWithContext("retrieval", in: "guide", limit: 1, expand: 0)
        let passage = try XCTUnwrap(passages.first)
        XCTAssertEqual(passage.citations.first?.sourceName, "guide.md")
        XCTAssertEqual(passage.citations.first?.sectionTitle, "Guide > Installation")
        XCTAssertEqual(passage.citations.first?.fileType, "markdown")
        XCTAssertFalse(passage.citations.first?.parentId?.isEmpty ?? true)
        XCTAssertFalse(passage.citations.first?.excerpt?.isEmpty ?? true)
        XCTAssertFalse(passage.citations.first?.chunkId.isEmpty ?? true)
    }

    func testRetrievalFiltersByFileType() throws {
        let folio = try FolioEngine.inMemory()
        let markdown = try XCTUnwrap("# Notes\n\nshared target phrase".data(using: .utf8))

        _ = try folio.ingest(.text("shared target phrase", name: "note.txt"), sourceId: "text")
        _ = try folio.ingest(.data(markdown, uti: "public.markdown", name: "note.md"), sourceId: "markdown")

        let markdownOnly = try folio.searchWithContext(
            "target",
            filter: .init(fileTypes: ["markdown"]),
            limit: 10,
            expand: 0
        )

        XCTAssertEqual(Set(markdownOnly.map(\.sourceId)), ["markdown"])
        XCTAssertEqual(markdownOnly.first?.citations.first?.fileType, "markdown")
    }

    func testIngestAsyncWithProviderRegistersIndex() async throws {
        let provider = FakeEmbeddingProvider(id: "fake-v1", dimension: 3)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("hello vector world", name: "note.txt"), sourceId: "vec")

        let info = try XCTUnwrap(folio.embeddingIndexInfo())
        XCTAssertEqual(info.id, "fake-v1")
        XCTAssertEqual(info.dimension, 3)
    }

    func testDimensionMismatchThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-mismatch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let providerA = FakeEmbeddingProvider(id: "fake-v1", dimension: 3)
        let providerB = FakeEmbeddingProvider(id: "fake-v2", dimension: 4)

        let loaders: [DocumentLoader] = [TextDocumentLoader()]

        do {
            let folioA = try FolioEngine(databaseURL: url, loaders: loaders, chunker: UniversalChunker(), embeddingProvider: providerA)
            _ = try await folioA.ingestAsync(.text("first source content", name: "a.txt"), sourceId: "A")
            let info = try XCTUnwrap(folioA.embeddingIndexInfo())
            XCTAssertEqual(info.id, "fake-v1")
        }

        let folioB = try FolioEngine(databaseURL: url, loaders: loaders, chunker: UniversalChunker(), embeddingProvider: providerB)
        // sync ingest doesn't embed, so chunk needs backfilling — and provider B's model conflicts with the registered index.
        _ = try folioB.ingest(.text("second source content", name: "b.txt"), sourceId: "B")

        do {
            try await folioB.backfillEmbeddings(for: "B")
            XCTFail("Expected dimension mismatch to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Folio")
            XCTAssertEqual(error.code, 530)
        }
    }

    func testEmbeddingGemma300mModelInfoIsPinned() {
        let info = EmbeddingModelInfo.embeddingGemma300m
        XCTAssertEqual(info.id, "embedding-gemma-300m")
        XCTAssertEqual(info.dimension, 768)
    }

    func testIngestAsyncProgressReportsLoadingChunkingAndEmbedding() async throws {
        let provider = FakeEmbeddingProvider(dimension: 4)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)

        // Two paragraphs → chunker emits more than one chunk, so we see >1 .embedding event.
        let body = String(repeating: "Paragraph about retrieval. ", count: 40)
            + "\n\n"
            + String(repeating: "Paragraph about chunking. ", count: 40)

        actor Sink {
            var events: [IngestProgress] = []
            func append(_ p: IngestProgress) { events.append(p) }
            func snapshot() -> [IngestProgress] { events }
        }
        let sink = Sink()

        _ = try await folio.ingestAsync(.text(body, name: "progress.txt"), sourceId: "prog") { p in
            Task { await sink.append(p) }
        }

        // Drain the actor so the Task closures land.
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await sink.snapshot()

        XCTAssertTrue(events.contains(where: { $0.phase == .loading }))
        XCTAssertTrue(events.contains(where: { $0.phase == .chunking }))
        let embeddingEvents = events.filter { $0.phase == .embedding }
        XCTAssertFalse(embeddingEvents.isEmpty, "expected at least one .embedding progress event")

        // The final .embedding event should report completed == total.
        if let last = embeddingEvents.last {
            XCTAssertEqual(last.completed, last.total)
        }
    }

    func testIngestAsyncRespectsCancellation() async throws {
        // SlowEmbedder gives us a guaranteed suspension point inside the chunk loop so
        // the outer task has time to flip `isCancelled` before the loop runs to completion.
        struct SlowEmbedder: EmbeddingProvider {
            let model = EmbeddingModelInfo(id: "slow", dimension: 4)
            func embed(_ text: String) async throws -> [Float] {
                try await Task.sleep(nanoseconds: 100_000_000)
                return [0, 0, 0, 0]
            }
            func embedBatch(_ texts: [String]) async throws -> [[Float]] {
                try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
                    for (i, t) in texts.enumerated() {
                        group.addTask { (i, try await self.embed(t)) }
                    }
                    var out = Array(repeating: [Float](), count: texts.count)
                    for try await (i, v) in group { out[i] = v }
                    return out
                }
            }
        }

        let folio = try FolioEngine.inMemory(embeddingProvider: SlowEmbedder())

        let body = String(repeating: "First passage about cancellation.\n\nSecond passage about cancellation.\n\n", count: 20)

        let task = Task {
            try await folio.ingestAsync(.text(body, name: "cancel.txt"), sourceId: "cancel")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testSearchHybridReturnsCosineScoredResults() async throws {
        let provider = FakeEmbeddingProvider(dimension: 4)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("retrieval keeps results grounded in source text", name: "rag.txt"), sourceId: "rag")

        let results = try await folio.searchHybrid("retrieval", in: "rag", limit: 1)
        let hit = try XCTUnwrap(results.first)
        XCTAssertNotNil(hit.cosine)
    }
}
