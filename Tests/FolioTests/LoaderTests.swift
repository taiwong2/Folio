//
//  LoaderTests.swift
//

import XCTest
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
@testable import Folio

final class DOCXLoaderTests: XCTestCase {

    func testExtractsTextFromStoredAndDeflatedDOCX() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>First paragraph about retrieval.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Second </w:t><w:t>paragraph</w:t><w:r/></w:r><w:r><w:t> with multiple runs.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Line one.</w:t><w:br/><w:t>Line two.</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let xmlData = Data(xml.utf8)

        for stored in [true, false] {
            let zip = makeMinimalDOCX(payload: xmlData, stored: stored)
            let loader = DOCXDocumentLoader()
            let doc = try loader.load(.data(zip, uti: "org.openxmlformats.wordprocessingml.document", name: "test.docx"))

            XCTAssertEqual(doc.pages.count, 1, "stored=\(stored)")
            let text = doc.pages[0].text
            XCTAssertTrue(text.contains("First paragraph about retrieval."), "stored=\(stored), text=\(text)")
            XCTAssertTrue(text.contains("Second paragraph with multiple runs."), "stored=\(stored), text=\(text)")
            XCTAssertTrue(text.contains("Line one.\nLine two."), "stored=\(stored), text=\(text)")
        }
    }

    func testEngineIngestsDOCXEndToEnd() throws {
        let xml = "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>findme docx body</w:t></w:r></w:p></w:body></w:document>"
        let zip = makeMinimalDOCX(payload: Data(xml.utf8), stored: false)

        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.data(zip, uti: "org.openxmlformats.wordprocessingml.document", name: "doc.docx"), sourceId: "docx")

        let source = try XCTUnwrap(folio.listSources().first { $0.id == "docx" })
        XCTAssertEqual(source.fileType, "docx")

        let hits = try folio.search("findme", in: "docx", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }

    // MARK: - Minimal docx builder

    /// Builds a one-entry ZIP archive containing `word/document.xml`. Optionally
    /// stores (compression method 0) or deflates (method 8) the payload so the
    /// ZipExtractor can be exercised on both codepaths without a binary fixture.
    private func makeMinimalDOCX(payload: Data, stored: Bool) -> Data {
        let name = "word/document.xml"
        let nameBytes = Array(name.utf8)
        let crc = crc32(payload)
        let uncompressedSize = UInt32(payload.count)

        let stream: Data
        let compressedSize: UInt32
        let method: UInt16
        if stored {
            stream = payload
            compressedSize = uncompressedSize
            method = 0
        } else {
            stream = deflate(payload)
            compressedSize = UInt32(stream.count)
            method = 8
        }

        var archive = Data()

        // Local file header
        let lfhOffset = UInt32(archive.count)
        appendUInt32(&archive, 0x04034b50)         // signature
        appendUInt16(&archive, 20)                 // version needed
        appendUInt16(&archive, 0)                  // general purpose bit flag
        appendUInt16(&archive, method)             // compression method
        appendUInt16(&archive, 0)                  // last mod time
        appendUInt16(&archive, 0)                  // last mod date
        appendUInt32(&archive, crc)                // crc32
        appendUInt32(&archive, compressedSize)
        appendUInt32(&archive, uncompressedSize)
        appendUInt16(&archive, UInt16(nameBytes.count))
        appendUInt16(&archive, 0)                  // extra length
        archive.append(contentsOf: nameBytes)
        archive.append(stream)

        // Central directory header
        let cdOffset = UInt32(archive.count)
        appendUInt32(&archive, 0x02014b50)         // signature
        appendUInt16(&archive, 20)                 // version made by
        appendUInt16(&archive, 20)                 // version needed
        appendUInt16(&archive, 0)                  // gp bit flag
        appendUInt16(&archive, method)
        appendUInt16(&archive, 0)                  // time
        appendUInt16(&archive, 0)                  // date
        appendUInt32(&archive, crc)
        appendUInt32(&archive, compressedSize)
        appendUInt32(&archive, uncompressedSize)
        appendUInt16(&archive, UInt16(nameBytes.count))
        appendUInt16(&archive, 0)                  // extra length
        appendUInt16(&archive, 0)                  // comment length
        appendUInt16(&archive, 0)                  // disk number start
        appendUInt16(&archive, 0)                  // internal attrs
        appendUInt32(&archive, 0)                  // external attrs
        appendUInt32(&archive, lfhOffset)
        archive.append(contentsOf: nameBytes)
        let cdSize = UInt32(archive.count) - cdOffset

        // EOCD
        appendUInt32(&archive, 0x06054b50)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, 1)
        appendUInt16(&archive, 1)
        appendUInt32(&archive, cdSize)
        appendUInt32(&archive, cdOffset)
        appendUInt16(&archive, 0)
        return archive
    }

    private func deflate(_ data: Data) -> Data {
        let destCapacity = max(data.count * 2 + 64, 64)
        var dest = Data(count: destCapacity)
        let produced = dest.withUnsafeMutableBytes { destBuf -> Int in
            data.withUnsafeBytes { srcBuf -> Int in
                guard let d = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(d, destCapacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(produced > 0, "test deflate failed")
        dest.removeSubrange(produced..<dest.count)
        return dest
    }

    private func appendUInt16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
    }
    private func appendUInt32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 24) & 0xff))
    }

    private func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

final class ImageLoaderTests: XCTestCase {

    func testSupportsCommonImageUTIs() {
        let loader = ImageDocumentLoader()
        let empty = Data([0, 0, 0])
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.png", name: nil)))
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.jpeg", name: nil)))
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.heic", name: nil)))
        XCTAssertTrue(loader.supports(.data(empty, uti: "public.image", name: nil)))
        XCTAssertFalse(loader.supports(.data(empty, uti: "public.plain-text", name: nil)))
        XCTAssertFalse(loader.supports(.text("hello", name: nil)))
    }

    #if canImport(AppKit)
    func testOCRsRenderedText() throws {
        let png = try renderTextPNG("Folio OCR", width: 400, height: 100)
        let loader = ImageDocumentLoader()
        let doc = try loader.load(.data(png, uti: "public.png", name: "img.png"))

        let recognised = doc.pages.first?.text.lowercased() ?? ""
        // Vision usually reads "Folio" cleanly; OCR isn't deterministic so we assert on a
        // substring rather than exact equality.
        XCTAssertTrue(recognised.contains("folio") || recognised.contains("ocr"),
            "expected OCR to surface part of the rendered text, got: \(recognised)")
    }

    private func renderTextPNG(_ text: String, width: Int, height: Int) throws -> Data {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 25), withAttributes: attrs)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG render failed"])
        }
        return png
    }
    #endif
}
