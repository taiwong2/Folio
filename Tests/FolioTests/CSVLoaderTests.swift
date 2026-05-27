//
//  CSVLoaderTests.swift
//
//  Unit tests for CSVDocumentLoader (RFC-4180 parsing for CSV and TSV)
//  plus an end-to-end ingest+search to catch wiring breaks in
//  FolioEngine.makeIngestInput.
//

import XCTest
@testable import Folio

final class CSVLoaderTests: XCTestCase {

    func testHeaderPrefixedRows() throws {
        let csv = "name,city,role\nAlice,Paris,engineer\nBob,Tokyo,designer\n"
        let loader = CSVDocumentLoader()
        let doc = try loader.load(.data(Data(csv.utf8), uti: "public.comma-separated-values-text", name: "people.csv"))

        XCTAssertEqual(doc.pages.count, 2)
        XCTAssertEqual(doc.pages[0].index, 1)
        XCTAssertEqual(doc.pages[0].text, "name: Alice, city: Paris, role: engineer")
        XCTAssertEqual(doc.pages[1].text, "name: Bob, city: Tokyo, role: designer")
    }

    func testRFC4180Quoting() {
        let csv = "a,b,c\n\"hello, world\",\"line1\nline2\",\"He said \"\"hi\"\"\"\n"
        let rows = CSVDocumentLoader.parse(csv, delimiter: ",")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["hello, world", "line1\nline2", "He said \"hi\""])
    }

    func testTSVDelimiter() throws {
        let tsv = "a\tb\n1\t2\n"
        let loader = CSVDocumentLoader()
        let doc = try loader.load(.data(Data(tsv.utf8), uti: "public.tab-separated-values-text", name: "tab.tsv"))
        XCTAssertEqual(doc.pages.count, 1)
        XCTAssertEqual(doc.pages[0].text, "a: 1, b: 2")
    }

    func testEngineIngestsCSVEndToEnd() throws {
        let csv = "name,note\nAlice,findme_csv\nBob,other_row\n"
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.data(Data(csv.utf8), uti: "public.comma-separated-values-text", name: "rows.csv"), sourceId: "c")

        let hits = try folio.search("findme_csv", in: "c", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }
}
