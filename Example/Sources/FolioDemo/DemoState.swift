import Foundation
import UniformTypeIdentifiers
import Folio

/// Holds the demo's engine, settings, and visible state. Built as a class because
/// `FolioEngine` is reference-typed and we need stable identity across SwiftUI updates.
///
/// `@unchecked Sendable` because: SwiftUI captures this from main-actor view code
/// and passes it into a `Task` (cross-actor send), but `FolioEngine` itself isn't
/// `Sendable`, so we can't be `@MainActor`. The UI gates concurrent calls with
/// `isBusy`, so the trade-off is acceptable for a demo.
@Observable
final class DemoState: @unchecked Sendable {
    enum Backend: String, CaseIterable, Identifiable {
        case openAI = "OpenAI (cloud)"
        case foundation = "Apple Foundation Models (on-device)"
        var id: String { rawValue }
    }

    // MARK: - Settings (user-editable)
    var backend: Backend = .openAI
    var openAIModel: String = "gpt-4o-mini"
    var openAIKey: String = ""

    // MARK: - Conversation
    var question: String = "What is an actor in Swift?"
    var streamedAnswer: String = ""
    var citations: [Citation] = []
    var usedPassages: [RetrievedResult] = []

    // MARK: - Lifecycle / status
    var status: String = "Idle — ingest a document, then ask a question."
    var isIngested: Bool = false
    var isBusy: Bool = false

    /// `sourceId` of the most recently ingested document. Used by `ask()` to scope
    /// retrieval and by the UI to display the active document.
    var currentSourceId: String?

    /// Snapshot of all chunks for the current source. Populated by `loadChunks()`
    /// for the inspector sheet; not refreshed automatically.
    var inspectedChunks: [InspectableChunk] = []

    /// Tracks the most recent ingest so `rebuildEngineIfNeeded()` can replay it
    /// when the user switches backends mid-session.
    private enum LastIngest {
        case sample
        case file(URL)
    }

    private var lastIngest: LastIngest?
    private var engine: FolioEngine?

    // MARK: - Ingest entry points

    func ingestSample() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await rebuild(with: .sample)
            isIngested = true
            currentSourceId = SampleDocument.sourceId
            status = Self.ingestSummary(name: SampleDocument.name, result: result)
        } catch {
            engine = nil
            isIngested = false
            currentSourceId = nil
            lastIngest = nil
            status = "Ingest failed: \(error.localizedDescription)"
        }
    }

    /// Ingests a real file picked through SwiftUI's `fileImporter`. Dispatches by
    /// the file's UTI into the right `IngestInput` case and wraps URL access in
    /// `startAccessingSecurityScopedResource` so the same code works when this
    /// demo is later run on iOS with sandboxing.
    func ingestPickedFile(url: URL) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await rebuild(with: .file(url))
            isIngested = true
            currentSourceId = url.lastPathComponent
            status = Self.ingestSummary(name: url.lastPathComponent, result: result)
        } catch {
            engine = nil
            isIngested = false
            currentSourceId = nil
            lastIngest = nil
            status = "Ingest failed: \(error.localizedDescription)"
        }
    }

    private static func ingestSummary(name: String, result: (pages: Int, chunks: Int)) -> String {
        if result.chunks == 0 {
            return "⚠ Indexed \(name) but produced 0 chunks. The document likely contains no extractable text (scanned/image-only PDF, or empty file). Retrieval will return nothing."
        }
        return "Indexed \(name) — \(result.pages) page(s), \(result.chunks) chunk(s). Ready to ask."
    }

    // MARK: - Ask

    func ask() async {
        guard let sourceId = currentSourceId else {
            status = "Ingest a document first."
            return
        }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Type a question first."
            return
        }
        guard makeGeneratorIfPossible() != nil else {
            status = "Backend not configured — \(backend == .openAI ? "enter an OpenAI API key" : "Foundation Models unavailable here")."
            return
        }

        isBusy = true
        streamedAnswer = ""
        citations = []
        usedPassages = []
        status = "Retrieving and asking the model…"

        defer { isBusy = false }

        do {
            // Rebuild every time so backend / key changes take effect immediately.
            try await rebuildEngineIfNeeded()
            guard let engine else { return }

            let stream = try await engine.answerStream(question, in: sourceId)
            for try await event in stream {
                switch event {
                case .passages(let p):
                    usedPassages = p
                    status = "Got \(p.count) candidate passage(s). Streaming answer…"
                case .text(let delta):
                    streamedAnswer += delta
                case .done(let answer):
                    citations = answer.citations
                    status = "Done. \(answer.citations.count) citation(s)."
                }
            }
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    /// Fetches every chunk for the current source so the inspector sheet can
    /// display the actual text Folio stored. Diagnoses "the model can't find X"
    /// scenarios: if X isn't in any chunk's text here, extraction or chunking is
    /// the problem; if X is here cleanly, retrieval or the model is the problem.
    func loadChunks() async {
        guard let sourceId = currentSourceId, let engine else {
            inspectedChunks = []
            status = "Ingest a document first."
            return
        }
        do {
            inspectedChunks = try engine.chunks(forSourceId: sourceId)
        } catch {
            inspectedChunks = []
            status = "Failed to load chunks: \(error.localizedDescription)"
        }
    }

    // MARK: - Internals

    private func rebuildEngineIfNeeded() async throws {
        guard let lastIngest else {
            throw NSError(
                domain: "FolioDemo",
                code: 700,
                userInfo: [NSLocalizedDescriptionKey: "No document has been ingested yet"]
            )
        }
        _ = try await rebuild(with: lastIngest)
    }

    @discardableResult
    private func rebuild(with ingest: LastIngest) async throws -> (pages: Int, chunks: Int) {
        let generator = makeGeneratorIfPossible()
        let fresh = try FolioEngine.inMemory(textGenerator: generator)

        let result: (pages: Int, chunks: Int)

        switch ingest {
        case .sample:
            result = try await fresh.ingestAsync(
                .text(SampleDocument.text, name: SampleDocument.name),
                sourceId: SampleDocument.sourceId
            )

        case .file(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            let ext = url.pathExtension.lowercased()
            let isMarkdown = ext == "md" || ext == "markdown"

            if contentType?.conforms(to: .pdf) == true {
                result = try await fresh.ingestAsync(
                    .pdf(url),
                    sourceId: url.lastPathComponent
                )
            } else if isMarkdown {
                let data = try Data(contentsOf: url)
                result = try await fresh.ingestAsync(
                    .data(data, uti: "public.markdown", name: url.lastPathComponent),
                    sourceId: url.lastPathComponent
                )
            } else if contentType?.conforms(to: .text) == true {
                let content = try String(contentsOf: url, encoding: .utf8)
                result = try await fresh.ingestAsync(
                    .text(content, name: url.lastPathComponent),
                    sourceId: url.lastPathComponent
                )
            } else {
                throw NSError(
                    domain: "FolioDemo",
                    code: 701,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported file type: \(contentType?.identifier ?? "unknown")"]
                )
            }
        }

        engine = fresh
        lastIngest = ingest
        return result
    }

    private func makeGeneratorIfPossible() -> TextGenerator? {
        switch backend {
        case .openAI:
            let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return OpenAIStyleGenerator.cloud(.openAI(model: openAIModel, apiKey: key))

        case .foundation:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return FoundationTextGenerator()
            } else {
                return nil
            }
            #else
            return nil
            #endif
        }
    }
}
