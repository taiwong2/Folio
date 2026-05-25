import Foundation
#if canImport(CoreMLLLM)
import CoreMLLLM
import CoreML

/// All-in-one, in-process Gemma 4 text generator backed by Core ML.
///
/// Wraps `CoreMLLLM`'s prebuilt Gemma 4 bundles (hosted by `mlboydaisuke`
/// on Hugging Face) so Folio consumers get on-device RAG answers without
/// CocoaPods, an external server, or hand-rolling a tokenizer + KV-cache
/// loop.
///
/// On first `generate`/`stream`/`prepare`, the provider downloads the
/// model bundle (multi-GB — see `Size`) into `CoreMLLLM`'s managed cache
/// and loads it. Subsequent calls reuse the loaded model.
///
/// **Cost note:** first call is slow (multi-GB download + ANE compile,
/// minutes on first run). Call `prepare()` at app launch from a
/// background `Task` so the first user-facing call returns at warm-cache
/// latency.
///
/// **Opt-in:** this provider is *not* wired as a default generator in
/// `FolioEngine` — callers must instantiate it explicitly. This avoids
/// surprise multi-GB downloads on first `answer()` invocation.
///
/// **Temperature:** `CoreMLLLM` does not currently expose a temperature
/// parameter; `GenerationRequest.temperature` is ignored. `maxTokens`
/// is honoured (default 512 when unspecified).
///
/// **Tool role:** `ChatMessage.role == .tool` has no analogue in
/// `CoreMLLLM`; it is mapped to `.user` so tool-call traces still reach
/// the model as text.
@available(iOS 18.0, macOS 15.0, *)
public actor GemmaCoreMLGenerator: TextGenerator {
    /// Which Gemma 4 size to load.
    ///
    /// `e4b` (4B effective params) is the higher-quality default;
    /// `e2b` (2B effective) is the lower-latency choice for older
    /// devices or quicker answers. Both download to CoreMLLLM's cache
    /// directory on first use.
    public enum Size: Sendable {
        case e2b
        case e4b

        var modelID: String {
            switch self {
            case .e2b: return "gemma4-e2b-3way"
            case .e4b: return "gemma4-e4b"
            }
        }

        var displayName: String {
            switch self {
            case .e2b: return "Gemma 4 E2B"
            case .e4b: return "Gemma 4 E4B"
            }
        }

        var huggingFaceURL: String {
            switch self {
            case .e2b: return "https://huggingface.co/mlboydaisuke/gemma-4-E2B-coreml/resolve/main"
            case .e4b: return "https://huggingface.co/mlboydaisuke/gemma-4-E4B-coreml/resolve/main"
            }
        }

        var approximateSize: String {
            switch self {
            case .e2b: return "5.4 GB"
            case .e4b: return "5.5 GB"
            }
        }
    }

    private let size: Size
    private let computeUnits: MLComputeUnits
    private let defaultMaxTokens: Int
    private let onProgress: (@Sendable (String) -> Void)?
    private var llm: CoreMLLLM?

    public init(
        size: Size = .e4b,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        defaultMaxTokens: Int = 512,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) {
        self.size = size
        self.computeUnits = computeUnits
        self.defaultMaxTokens = defaultMaxTokens
        self.onProgress = onProgress
    }

    public func generate(_ request: GenerationRequest) async throws -> String {
        let llm = try await ensureLoaded()
        let messages = Self.convert(request.messages)
        let max = request.maxTokens ?? defaultMaxTokens
        return try await llm.generate(messages, maxTokens: max)
    }

    public nonisolated func stream(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = try await self.openStream(request)
                    for await chunk in inner {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Eagerly downloads, loads, and warms the model. Idempotent. Call
    /// once at app launch (e.g. inside a background `Task`) so the first
    /// user-facing call returns at warm-cache latency.
    public func prepare() async throws {
        _ = try await ensureLoaded()
    }

    /// `true` once the model has been loaded into memory.
    public var isReady: Bool { llm != nil }

    private func openStream(_ request: GenerationRequest) async throws -> AsyncStream<String> {
        let llm = try await ensureLoaded()
        let messages = Self.convert(request.messages)
        let max = request.maxTokens ?? defaultMaxTokens
        return try await llm.stream(messages, maxTokens: max)
    }

    private func ensureLoaded() async throws -> CoreMLLLM {
        if let llm { return llm }
        let info = ModelDownloader.ModelInfo(
            id: size.modelID,
            name: size.displayName,
            size: size.approximateSize,
            downloadURL: size.huggingFaceURL,
            folderName: size.modelID
        )
        let loaded = try await CoreMLLLM.load(
            model: info,
            computeUnits: computeUnits,
            onProgress: onProgress
        )
        self.llm = loaded
        return loaded
    }

    private static func convert(_ messages: [ChatMessage]) -> [CoreMLLLM.Message] {
        messages.map { m in
            let role: CoreMLLLM.Message.Role
            switch m.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: role = .user
            }
            return CoreMLLLM.Message(role: role, content: m.content)
        }
    }
}

#endif // canImport(CoreMLLLM)
