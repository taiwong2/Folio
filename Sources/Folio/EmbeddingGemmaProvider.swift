import Foundation
#if canImport(CoreMLLLM)
import CoreMLLLM
import CoreML

/// All-in-one, in-process EmbeddingGemma 300M provider.
///
/// Wraps [`CoreML-LLM`](https://github.com/john-rocky/CoreML-LLM)'s Core ML
/// build of EmbeddingGemma (768-dim, L2-normalised) so Folio consumers get
/// genuinely on-device, in-process retrieval embeddings without depending on
/// CocoaPods, an external server, or extra setup.
///
/// On first construction-and-`embed`, the provider downloads the model bundle
/// from Hugging Face (`mlboydaisuke/embeddinggemma-300m-coreml`, ~300 MB) into
/// `modelsDir` and caches it. Subsequent calls reuse the loaded model.
///
/// **Cost note:** first `embed(_:)` call typically takes 10–60 seconds wall-clock
/// (download + compile + ANE warm-up). Subsequent calls run on the Apple Neural
/// Engine and are millisecond-scale.
///
/// **Task prefixing:** EmbeddingGemma was trained with task-specific prefixes
/// (per Google's model card). For RAG you typically want chunks embedded with
/// `.retrievalDocument` and queries embedded with `.retrievalQuery`. Folio's
/// current `EmbeddingProvider` protocol uses a single `embed(_:)` method, so
/// this provider defaults to `.retrievalDocument` for chunk ingestion. If you
/// need separate query-side embedding, instantiate a second provider configured
/// with `.retrievalQuery` and pass it where appropriate.
@available(iOS 18.0, macOS 15.0, *)
public actor EmbeddingGemmaProvider: EmbeddingProvider {
    nonisolated public let model: EmbeddingModelInfo = .embeddingGemma300m

    private let modelsDir: URL
    private let task: EmbeddingGemma.Task?
    private let computeUnits: MLComputeUnits
    private let hfToken: String?
    private var loaded: EmbeddingGemma?

    public init(
        modelsDir: URL = EmbeddingGemmaProvider.defaultModelsDir,
        task: EmbeddingGemma.Task? = .retrievalDocument,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        hfToken: String? = nil
    ) {
        self.modelsDir = modelsDir
        self.task = task
        self.computeUnits = computeUnits
        self.hfToken = hfToken
    }

    /// Default cache location: `~/Library/Application Support/Folio/models/`.
    /// Created on first access. Override via the `modelsDir:` initializer
    /// parameter if you want to share a cache across apps or pre-stage the
    /// bundle inside an app group container.
    public static var defaultModelsDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("Folio", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func embed(_ text: String) async throws -> [Float] {
        let model = try await ensureLoaded()
        return try model.encode(text: text, task: task)
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let model = try await ensureLoaded()
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try model.encode(text: text, task: task))
        }
        return out
    }

    private func ensureLoaded() async throws -> EmbeddingGemma {
        if let loaded { return loaded }
        let eg = try await EmbeddingGemma.downloadAndLoad(
            modelsDir: modelsDir,
            hfToken: hfToken,
            computeUnits: computeUnits
        )
        loaded = eg
        return eg
    }
}

#endif // canImport(CoreMLLLM)
