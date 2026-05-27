//
//  HTMLDocumentLoader.swift
//  Folio
//
//  Loader for HTML and RTF. HTML is stripped to plain text by a self-contained
//  regex pipeline (script/style block removal, tag stripping, entity decoding,
//  whitespace collapsing) so it works on any thread without going through
//  NSAttributedString's HTML-rendering quirks. RTF uses NSAttributedString
//  with the `.rtf` document type, which is well-supported off the main thread.
//

import Foundation

public struct HTMLDocumentLoader: DocumentLoader {
    private let supportedUTIs: Set<String> = [
        "public.html",
        "public.rtf"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        return supportedUTIs.contains(uti.lowercased())
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, uti, name) = input, supportedUTIs.contains(uti.lowercased()) else {
            throw NSError(domain: "Folio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Not HTML/RTF"])
        }

        let text: String
        if uti.lowercased() == "public.rtf" {
            text = try Self.stripRTF(data)
        } else {
            text = try Self.stripHTML(data)
        }

        return LoadedDocument(name: name ?? "untitled.html", pages: [.init(index: 0, text: text)])
    }

    // MARK: - HTML

    static func stripHTML(_ data: Data) throws -> String {
        guard var content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Folio", code: 404, userInfo: [NSLocalizedDescriptionKey: "HTML must be UTF-8"])
        }

        // Remove <script> and <style> blocks entirely (case-insensitive, dot matches newlines).
        let blockOptions: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        for tag in ["script", "style"] {
            let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: blockOptions) {
                let range = NSRange(content.startIndex..., in: content)
                content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: " ")
            }
        }

        // Strip every remaining tag.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: " ")
        }

        content = Self.decodeEntities(content)
        content = content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes the named entities most HTML in the wild actually uses, plus
    /// `&#NN;` / `&#xHH;` numeric character references. Not a full HTML4 entity
    /// table — that's overkill for a search index.
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'")
        ]
        for (k, v) in named {
            out = out.replacingOccurrences(of: k, with: v)
        }

        // Numeric refs: &#NN; and &#xHH;
        let numericRegex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: [])
        if let numericRegex {
            let nsString = out as NSString
            let matches = numericRegex.matches(in: out, options: [], range: NSRange(location: 0, length: nsString.length))
            var result = ""
            var cursor = 0
            for match in matches {
                let prefix = nsString.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(prefix)
                let isHex = nsString.substring(with: match.range(at: 1)) == "x"
                let digits = nsString.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10),
                   let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                }
                cursor = match.range.location + match.range.length
            }
            result.append(nsString.substring(from: cursor))
            out = result
        }
        return out
    }

    // MARK: - RTF

    static func stripRTF(_ data: Data) throws -> String {
        let attr = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attr.string
    }
}
