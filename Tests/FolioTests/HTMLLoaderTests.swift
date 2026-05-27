//
//  HTMLLoaderTests.swift
//
//  Unit tests for HTMLDocumentLoader (HTML stripping + RTF via NSAttributedString)
//  plus an end-to-end ingest+search to catch wiring breaks in FolioEngine.makeIngestInput.
//

import XCTest
@testable import Folio

final class HTMLLoaderTests: XCTestCase {

    func testSupportsHTMLandRTFOnly() {
        let loader = HTMLDocumentLoader()
        let empty = Data()
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.html", name: nil)))
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.rtf", name: nil)))
        XCTAssertFalse(loader.supports(.data(empty, uti: "public.json", name: nil)))
        XCTAssertFalse(loader.supports(.text("hi", name: nil)))
    }

    func testStripsTagsScriptStyleAndDecodesEntities() throws {
        let html = """
        <html><head><style>p { color: red; }</style><script>alert(1)</script></head>
        <body><p>Hello &amp; goodbye &#39;world&#39; &#x2014; done.</p></body></html>
        """
        let data = Data(html.utf8)
        let loader = HTMLDocumentLoader()
        let doc = try loader.load(.data(data, uti: "public.html", name: "page.html"))

        XCTAssertEqual(doc.pages.count, 1)
        let text = doc.pages[0].text
        XCTAssertTrue(text.contains("Hello & goodbye 'world' — done."), "got: \(text)")
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("<"))
    }

    func testStripRTFViaNSAttributedString() throws {
        let rtf = #"{\rtf1\ansi {\b Bold} normal text.}"#
        let data = Data(rtf.utf8)
        let loader = HTMLDocumentLoader()
        let doc = try loader.load(.data(data, uti: "public.rtf", name: "memo.rtf"))

        XCTAssertEqual(doc.pages.count, 1)
        let text = doc.pages[0].text
        XCTAssertTrue(text.contains("Bold"))
        XCTAssertTrue(text.contains("normal text"))
    }

    func testEngineIngestsHTMLEndToEnd() throws {
        let html = "<html><body><h1>Title</h1><p>findme html body</p></body></html>"
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.data(Data(html.utf8), uti: "public.html", name: "p.html"), sourceId: "h")

        let hits = try folio.search("findme", in: "h", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }
}
