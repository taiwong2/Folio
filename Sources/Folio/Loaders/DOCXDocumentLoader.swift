//
//  DOCXDocumentLoader.swift
//  Folio
//

import Foundation

public struct DOCXDocumentLoader: DocumentLoader {
    private let supportedUTIs: Set<String> = [
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.docx"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        return supportedUTIs.contains(uti.lowercased())
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, uti, name) = input, supportedUTIs.contains(uti.lowercased()) else {
            throw NSError(domain: "Folio", code: 405, userInfo: [NSLocalizedDescriptionKey: "Not DOCX"])
        }

        let xml: Data
        do {
            xml = try ZipExtractor.extract("word/document.xml", from: data)
        } catch {
            throw NSError(domain: "Folio", code: 406, userInfo: [
                NSLocalizedDescriptionKey: "Could not read word/document.xml from DOCX: \(error)"
            ])
        }

        let text = DOCXTextExtractor.extract(xml)
        return LoadedDocument(name: name ?? "document.docx", pages: [.init(index: 0, text: text)])
    }
}

/// Pulls visible text out of WordprocessingML by tracking `<w:t>` text runs and
/// emitting paragraph/line breaks for `<w:p>`/`<w:br>`. DOCX has no native
/// "page" concept until the document is laid out by Word, so we collapse the
/// whole document into a single `LoadedPage(index: 0)` — neighbor expansion still
/// works because chunks remain ordered.
enum DOCXTextExtractor {
    static func extract(_ xml: Data) -> String {
        let parser = XMLParser(data: xml)
        let delegate = DOCXParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.finished()
    }
}

private final class DOCXParserDelegate: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var capturing = false
    private var paragraphHasContent = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        switch elementName {
        case "w:t":
            capturing = true
        case "w:br", "w:cr":
            buffer.append("\n")
        case "w:tab":
            buffer.append("\t")
        case "w:p":
            paragraphHasContent = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing {
            buffer.append(string)
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphHasContent = true
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            capturing = false
        case "w:p":
            // Blank-line separation between paragraphs preserves the structure the
            // chunker uses to decide section boundaries. Empty `<w:p/>` elements
            // (Word emits these for trailing whitespace) collapse to a single break.
            if paragraphHasContent {
                buffer.append("\n\n")
            } else if !buffer.isEmpty, !buffer.hasSuffix("\n") {
                buffer.append("\n")
            }
            paragraphHasContent = false
        case "w:tc":
            // Table cell separator — keep adjacent cells from running together.
            if !buffer.hasSuffix("\n") && !buffer.hasSuffix("\t") {
                buffer.append("\t")
            }
        default:
            break
        }
    }

    func finished() -> String {
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
