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
}
