//
//  StructuredDataLoaderTests.swift
//
//  Unit tests for StructuredDataLoader (JSON via JSONSerialization, XML via
//  XMLParser, YAML via heuristic flattener) plus an end-to-end ingest+search
//  to catch wiring breaks in FolioEngine.makeIngestInput.
//

import XCTest
@testable import Folio

final class StructuredDataLoaderTests: XCTestCase {

    func testJSONFlattensPathsAndArrays() throws {
        let json = #"{"name":"folio","tags":["search","rag"],"meta":{"version":2}}"#
        let loader = StructuredDataLoader()
        let doc = try loader.load(.data(Data(json.utf8), uti: "public.json", name: "config.json"))

        let text = doc.pages[0].text
        XCTAssertTrue(text.contains("name: folio"), "got: \(text)")
        XCTAssertTrue(text.contains("tags[0]: search"))
        XCTAssertTrue(text.contains("tags[1]: rag"))
        XCTAssertTrue(text.contains("meta.version: 2"))
    }

    func testXMLFlattensElementsAndAttributes() throws {
        let xml = #"<book id="42"><title>RAG Notes</title><author>Tai</author></book>"#
        let loader = StructuredDataLoader()
        let doc = try loader.load(.data(Data(xml.utf8), uti: "public.xml", name: "b.xml"))

        let text = doc.pages[0].text
        XCTAssertTrue(text.contains("book.@id: 42"), "got: \(text)")
        XCTAssertTrue(text.contains("book.title: RAG Notes"))
        XCTAssertTrue(text.contains("book.author: Tai"))
    }

    func testYAMLBasicFlattening() throws {
        let yaml = """
        ---
        # comment
        name: folio
        version: 2
        tags:
          - rag
          - search
        """
        let loader = StructuredDataLoader()
        let doc = try loader.load(.data(Data(yaml.utf8), uti: "public.yaml", name: "c.yaml"))

        let text = doc.pages[0].text
        XCTAssertTrue(text.contains("name: folio"), "got: \(text)")
        XCTAssertTrue(text.contains("version: 2"))
        XCTAssertTrue(text.contains("- rag"))
        XCTAssertFalse(text.contains("comment"))
        XCTAssertFalse(text.contains("---"))
    }

    func testEngineIngestsJSONEndToEnd() throws {
        let json = #"{"note":"findme_json","other":"row"}"#
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.data(Data(json.utf8), uti: "public.json", name: "j.json"), sourceId: "j")

        let hits = try folio.search("findme_json", in: "j", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }
}
