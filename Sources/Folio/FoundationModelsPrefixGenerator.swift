import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
public actor FoundationModelsPrefixGenerator {
    public struct Configuration: Sendable {
        public var instructions: String
        public var locale: String?
        public var maximumResponseTokens: Int?
        public var temperature: Double?

        public init(
            instructions: String = FoundationModelsPrefixGenerator.defaultInstructions,
            locale: String? = nil,
            maximumResponseTokens: Int? = LLMPrefixPrompter.maxOutputTokens,
            temperature: Double? = nil
        ) {
            self.instructions = instructions
            self.locale = locale
            self.maximumResponseTokens = maximumResponseTokens
            self.temperature = temperature
        }
    }

    public static let defaultInstructions: String = """
    You generate dense retrieval prefixes for document chunks. The prefix is
    prepended to the chunk before indexing, so it must make the chunk findable
    by surfacing every distinct topic, named entity, key fact, and specific
    value (numbers, dates, identifiers) the chunk contains.

    Rules:
    - Cover ALL major sections present in the chunk. If a chunk spans, say,
      Education AND Experience AND Skills, name each one explicitly.
    - Use only facts that literally appear in the chunk. Never invent.
    - One line, no newlines. Semicolon-separated phrases.
    - Aim for 20–40 words. Prefer concrete nouns and proper names over verbs.
    - No leading "Answer:", no numbering, no trailing punctuation.
    """

    private var session: LanguageModelSession
    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.session = LanguageModelSession(instructions: configuration.instructions)
    }

    public func prefix(
        for doc: LoadedDocument,
        page: LoadedPage,
        chunk: String,
        context: ChunkContext? = nil
    ) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw UnavailableError.state(String(describing: SystemLanguageModel.default.availability))
        }

        let header = page.text
            .split(separator: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.range(of: #"^page\s*\d+$"#, options: .regularExpression) == nil }

        let ctx = context ?? ChunkContext(
            docName: doc.name,
            pageIndex: page.index,
            sectionHeader: header,
            chunkText: chunk,
            localeHint: configuration.locale
        )
        
        let prompt = LLMPrefixPrompter.build(ctx)
        let raw = try await session.respond(to: prompt, options: configuration.generationOptions)
        let sanitized = LLMPrefixPrompter.sanitize(raw.content)

        guard !sanitized.isEmpty else {
            throw GenerationError.empty
        }

        return sanitized
    }

    public func prefixWithFallback(
        for doc: LoadedDocument,
        page: LoadedPage,
        chunk: String,
        context: ChunkContext? = nil
    ) async -> String {
        do {
            return try await prefix(for: doc, page: page, chunk: chunk, context: context)
        } catch {
            return Contextualizer.prefix(doc: doc, page: page, chunk: chunk)
        }
    }

    public func makeContextFunction() -> @Sendable (LoadedDocument, LoadedPage, String) async throws -> String {
        { doc, page, chunk in
            try await self.prefix(for: doc, page: page, chunk: chunk)
        }
    }

    public nonisolated func makeFallbackContextFunction() -> @Sendable (LoadedDocument, LoadedPage, String) async -> String {
        { doc, page, chunk in
            await self.prefixWithFallback(for: doc, page: page, chunk: chunk)
        }
    }

    public enum GenerationError: Error, Sendable {
        case empty
    }

    public enum UnavailableError: Error, Sendable {
        case state(String)
    }
}

@available(iOS 26.0, macOS 26.0, *)
private extension FoundationModelsPrefixGenerator.Configuration {
    var generationOptions: GenerationOptions {
        var options = GenerationOptions()
        options.maximumResponseTokens = maximumResponseTokens
        if let temperature {
            options.temperature = temperature
        }
        return options
    }
}

@available(iOS 26.0, macOS 26.0, *)
public extension IndexingConfig {
    static func foundationModelPrefixes(
        configuration: FoundationModelsPrefixGenerator.Configuration = .init()
    ) -> IndexingConfig {
        var config = IndexingConfig()
        config.useContextualPrefix = true
        let generator = FoundationModelsPrefixGenerator(configuration: configuration)
        config.contextFn = { doc, page, chunk in
            try await generator.prefix(for: doc, page: page, chunk: chunk)
        }
        return config
    }

    mutating func useFoundationModelPrefixes(
        configuration: FoundationModelsPrefixGenerator.Configuration = .init()
    ) {
        useContextualPrefix = true
        let generator = FoundationModelsPrefixGenerator(configuration: configuration)
        contextFn = { doc, page, chunk in
            try await generator.prefix(for: doc, page: page, chunk: chunk)
        }
    }
}

#endif // canImport(FoundationModels)
