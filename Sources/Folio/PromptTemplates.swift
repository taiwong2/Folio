import Foundation

public enum ChunkKind: Sendable {
    case prose
    case code
    case table
    case figure
    case list
}

public struct ChunkContext: Sendable {
    public let docName: String?
    public let pageIndex: Int?
    public let sectionHeader: String?
    public let leftContext: String?
    public let chunkText: String
    public let rightContext: String?
    public let kind: ChunkKind
    public let localeHint: String?

    public init(docName: String? = nil, pageIndex: Int? = nil, sectionHeader: String? = nil, leftContext: String? = nil, chunkText: String, rightContext: String? = nil, kind: ChunkKind = .prose, localeHint: String? = nil) {
        self.docName = docName
        self.pageIndex = pageIndex
        self.sectionHeader = sectionHeader
        self.leftContext = leftContext
        self.chunkText = chunkText
        self.rightContext = rightContext
        self.kind = kind
        self.localeHint = localeHint
    }
}

public enum LLMPrefixPrompter {
    public static let maxOutputTokens: Int = 160
    public static let stop: [String] = ["\n\n", "\n", "###", "---", "```"]

    public static func build(_ ctx: ChunkContext) -> String {
        let name   = ctx.docName ?? "Document"
        let page   = ctx.pageIndex.map { "p.\($0)" } ?? "p.?"
        let header = (ctx.sectionHeader?.isEmpty == false) ? ctx.sectionHeader! : "—"
        let left   = (ctx.leftContext ?? "").prefix(800)
        let right  = (ctx.rightContext ?? "").prefix(800)
        let chunk  = ctx.chunkText.prefix(1600)
        let locale = ctx.localeHint ?? "en"

        return """
        <document>
        \(name) — \(header) — \(page)
        </document>

        <left>
        \(left)
        </left>

        <chunk>
        \(chunk)
        </chunk>

        <right>
        \(right)
        </right>

        Write a single dense retrieval prefix for the chunk above. The prefix is
        prepended to the chunk before indexing, so it should make the chunk
        findable by listing its main topics, named entities, key facts, sections,
        and any specific values (numbers, dates, identifiers) that appear in it.

        Requirements:
        - Cover ALL distinct topics/sections present in the chunk. If the chunk
          spans multiple sections (e.g. "Education" AND "Experience"), name each.
        - Use ONLY facts that literally appear in the chunk. Do not invent.
        - Prefer concrete nouns and proper names over verbs and generalities.
        - One line, semicolon-separated phrases. Aim for 20–40 words total
          (~60–120 tokens). No trailing punctuation. No reasoning or explanation.
        - Language: \(locale).

        Your single line:
        """
    }

    public static func sanitize(_ s: String, maxChars: Int = 600) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxChars { t = String(t.prefix(maxChars)) }
        if t.lowercased().hasPrefix("answer:") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
