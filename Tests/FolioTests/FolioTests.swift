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

    func testSearchHybridReturnsCosineScoredResults() async throws {
        let provider = FakeEmbeddingProvider(dimension: 4)
        let folio = try FolioEngine.inMemory(embeddingProvider: provider)
        _ = try await folio.ingestAsync(.text("retrieval keeps results grounded in source text", name: "rag.txt"), sourceId: "rag")

        let results = try await folio.searchHybrid("retrieval", in: "rag", limit: 1)
        let hit = try XCTUnwrap(results.first)
        XCTAssertNotNil(hit.cosine)
    }
}
