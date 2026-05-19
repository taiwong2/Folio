import Foundation

public struct MarkdownDocumentLoader: DocumentLoader {
    private let supportedUTIs: Set<String> = [
        "net.daringfireball.markdown",
        "public.markdown",
        "public.md"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        return supportedUTIs.contains(uti.lowercased())
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, uti, name) = input, supportedUTIs.contains(uti.lowercased()) else {
            throw NSError(domain: "Folio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Not Markdown"])
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Folio", code: 404, userInfo: [NSLocalizedDescriptionKey: "Markdown is not valid UTF-8"])
        }

        return LoadedDocument(name: name ?? "markdown.md", pages: [.init(index: 0, text: normalizeMarkdown(text))])
    }
}

private func normalizeMarkdown(_ s: String) -> String {
    var normalized = s.precomposedStringWithCompatibilityMapping
    normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\u{2028}", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\u{2029}", with: "\n")

    let allowed: Set<UnicodeScalar> = ["\n", "\t"]
    let view = normalized.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
        if CharacterSet.controlCharacters.contains(scalar) {
            return allowed.contains(scalar) ? scalar : nil
        }
        return scalar
    }

    return String(String.UnicodeScalarView(view))
}
