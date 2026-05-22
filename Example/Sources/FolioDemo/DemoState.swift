import Foundation
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
    var status: String = "Idle — ingest the sample, then ask a question."
    var isIngested: Bool = false
    var isBusy: Bool = false

    private var engine: FolioEngine?

    func ingestSample() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let generator = makeGeneratorIfPossible()
            engine = try FolioEngine.inMemory(textGenerator: generator)
            guard let engine else { return }
            let result = try engine.ingest(
                .text(SampleDocument.text, name: SampleDocument.name),
                sourceId: SampleDocument.sourceId
            )
            isIngested = true
            status = "Ingested \(result.pages) page(s), \(result.chunks) chunk(s). Ready to ask."
        } catch {
            status = "Ingest failed: \(error.localizedDescription)"
            engine = nil
            isIngested = false
        }
    }

    func ask() async {
        guard let engine else {
            status = "Ingest the sample first."
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
            // Rebuild engine if backend changed mid-session — engine retains its
            // configured generator at construction.
            try rebuildEngineIfNeeded()
            let stream = try await engine.answerStream(question, in: SampleDocument.sourceId)
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

    private func rebuildEngineIfNeeded() throws {
        // The simplest correctness story: rebuild from scratch every time we ask,
        // so backend / key changes always take effect.
        let generator = makeGeneratorIfPossible()
        let fresh = try FolioEngine.inMemory(textGenerator: generator)
        _ = try fresh.ingest(.text(SampleDocument.text, name: SampleDocument.name), sourceId: SampleDocument.sourceId)
        engine = fresh
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
