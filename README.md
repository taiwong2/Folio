# Folio

Folio is an early Swift Package for building retrieval-augmented generation cores on Apple platforms. It currently focuses on ingestion, chunking, local SQLite search, optional contextual prefixes, vector storage, and an OpenAI-compatible chat client.

The package targets iOS 26+ for apps and macOS 26+ so the package can build and test on local macOS hosts.

## Current Features

- PDF, plain text, Markdown, DOCX, and image ingestion
- PDF text extraction with Vision OCR fallback; standalone image OCR via Vision
- Universal text chunking with markdown heading awareness and header/footer cleanup
- Parent-section retrieval (`expandToParent`) so a small chunk match can return the full enclosing section
- Document-level tags (`source_tags`) and a `RetrievalFilter.tags` clause
- Async ingestion with cooperative cancellation and `IngestProgress` callbacks
- SQLite storage with FTS5 BM25 search
- Contextual prefix hooks and prefix cache
- Apple Foundation Models prefix helper when `FoundationModels` is available on iOS 26+ or macOS 26+
- Vector storage for embedded chunks with model-id + dimension validation
- **All-in-one on-device EmbeddingGemma 300M (`EmbeddingGemmaProvider`)** — in-process Core ML inference on the Apple Neural Engine, auto-downloads + caches the model on first use, zero CocoaPods
- Local-server EmbeddingGemma via Ollama (`EmbeddingGemmaEmbedder`)
- OpenAI-compatible embedding adapter (`OpenAIStyleEmbedder`) for hosted providers or local servers
- Public `FakeEmbeddingProvider` for consumer-side tests
- BM25 search (`search`), pure vector search (`searchVectors`), and hybrid retrieval (`searchHybrid`) — all support neighbor expansion, parent-section expansion, metadata filters, and optional MMR diversification
- OpenAI-compatible chat completions client (with SSE streaming) for local runtimes or hosted providers
- Pluggable `TextGenerator` protocol with backends for OpenAI-compatible cloud (`OpenAIStyleGenerator.cloud(...)`), Apple Foundation Models (`FoundationTextGenerator`), all-in-one on-device Gemma 4 via Core ML (`GemmaCoreMLGenerator`), and a `FakeTextGenerator` for tests
- High-level `engine.answer(_:)` / `engine.answerStream(_:)` that retrieve, prompt, generate, and resolve inline citation markers in one call — returning `Answer.text`, `.citations`, `.usedPassages`, and a heuristic `.confidence`
- One-line ingest helpers: `engine.ingest(url:)`, `engine.ingest(text:name:)`, `engine.retrieve(_:)`

## Planned Features

- More file types (HTML/RTF/CSV/XLSX/PPTX/ZIP)
- Native (non-OpenAI-compat) Anthropic and Gemini generators for provider-specific features
- Reranking, HyDE, query rewriting, refusal/confidence policy helpers
- Eval fixtures and retrieval metrics

## Installation

Add Folio with Swift Package Manager:

```swift
.dependencies = [
    .package(url: "https://github.com/lolbigtime/Folio", .upToNextMinor(from: "0.1.0"))
]
```

Then add the library product to your target:

```swift
.product(name: "Folio", package: "Folio")
```

SPM resources are configured for the bundled SQL migrations.

## Quick Start

```swift
import Folio

let folio = try FolioEngine.inMemory()

// One-liner convenience: derives sourceId from name.
let id = try folio.ingest(text: "hello world from folio", name: "note.txt")

let hits = try folio.search("hello", in: id, limit: 5)
for hit in hits {
    print("\(hit.sourceId): \(hit.excerpt)")
}

// `ingest(url:)` accepts a file URL and picks the right loader by extension:
let id2 = try folio.ingest(url: URL(fileURLWithPath: "/path/to/notes.pdf"))

// `retrieve(_:)` picks hybrid when an embedding provider is configured, lexical otherwise:
let results = try await folio.retrieve("hello", in: id)
```

## Ingestion Formats

`engine.ingest(url:)` reads the file and picks a loader by extension:

| Extension | Loader |
|-----------|--------|
| `.pdf` | `PDFDocumentLoader` (PDFKit + Vision OCR fallback) |
| `.md`, `.markdown` | `MarkdownDocumentLoader` |
| `.docx` | `DOCXDocumentLoader` (in-process unzip + WordprocessingML walk) |
| `.png` / `.jpg` / `.heic` / `.tiff` / `.gif` / `.webp` | `ImageDocumentLoader` (Vision OCR) |
| `.txt`, `.log`, anything else | `TextDocumentLoader` |

You can also pass raw bytes via `.data(Data, uti: …, name: …)` and matching loaders will pick them up by UTI. Long ingests can be cancelled by cancelling the enclosing task and report progress with a `progress:` closure:

```swift
let task = Task {
    try await folio.ingestAsync(.pdf(url), sourceId: "manual") { p in
        print("phase: \(p.phase), \(p.completed)/\(p.total ?? -1)")
    }
}
// task.cancel()  // stops the loop between chunks
```

## PDF Ingestion

```swift
let engine = try FolioEngine.inMemory()
try engine.ingest(.pdf(pdfURL), sourceId: "manual")

let passages = try engine.searchWithContext(
    "optimizer settings",
    in: "manual",
    limit: 3,
    expand: 1
)
```

PDF text is extracted with PDFKit. If a page has no extractable text, Folio attempts Vision OCR on platforms where Vision text recognition is available.

## Contextual Prefixes

Folio can prepend a short context line to each chunk before indexing. By default it uses the built-in `Contextualizer`. For async ingestion, you can provide your own LLM-backed prefix function:

```swift
var config = FolioConfig()
config.indexing.useContextualPrefix = true
config.indexing.contextFn = { doc, page, chunk in
    let prompt = LLMPrefixPrompter.build(
        ChunkContext(
            docName: doc.name,
            pageIndex: page.index,
            chunkText: chunk
        )
    )

    let raw = try await MyLocalLLM.generate(
        prompt: prompt,
        maxTokens: LLMPrefixPrompter.maxOutputTokens,
        stop: LLMPrefixPrompter.stop
    )

    return LLMPrefixPrompter.sanitize(raw)
}

let engine = try FolioEngine.inMemory()
_ = try await engine.ingestAsync(.pdf(pdfURL), sourceId: "Doc1", config: config)
```

### Apple Foundation Models Prefixes

When the `FoundationModels` framework is available, Folio exposes helpers for iOS 26+ and macOS 26+:

```swift
if #available(iOS 26.0, macOS 26.0, *) {
    var config = FolioConfig()
    config.indexing.useFoundationModelPrefixes()

    _ = try await engine.ingestAsync(
        .pdf(pdfURL),
        sourceId: "Doc1",
        config: config
    )
}
```

Configuration stays within Folio's wrapper type:

```swift
if #available(iOS 26.0, macOS 26.0, *) {
    var config = FolioConfig()
    config.indexing = .foundationModelPrefixes(
        configuration: .init(
            instructions: "Keep prefixes under 8 words.",
            locale: "en",
            temperature: 0.1
        )
    )
}
```

## Tags

Tag a source at ingest time or after the fact, then filter retrieval by tag:

```swift
_ = try folio.ingest(.text(body, name: "note.md"), sourceId: "note", tags: ["draft", "research"])
try folio.setTags(["published"], forSource: "note")
let stored = try folio.tags(forSource: "note")

let drafts = try folio.searchWithContext(
    "retrieval",
    filter: .init(tags: ["draft"]),
    limit: 10
)
```

Tags are document-level, OR-matched against the requested set, and dropped automatically when the source is deleted.

## Hybrid Retrieval

Pass an `EmbeddingProvider` to `FolioEngine`, ingest with `ingestAsync`, and backfill missing vectors when needed. Each provider declares its `EmbeddingModelInfo` (id + dimension) so Folio refuses to mix vectors from incompatible models in the same index.

### On-device (EmbeddingGemma 300M, Core ML, Apple Neural Engine)

The recommended path. Zero CocoaPods, zero manual model download — `EmbeddingGemmaProvider()` is one line, and on first `embed()` it auto-fetches the Core ML bundle (~300 MB) to `~/Library/Application Support/Folio/models/` and runs every subsequent call on the Apple Neural Engine.

```swift
if #available(iOS 18, macOS 15, *) {
    let provider = EmbeddingGemmaProvider()
    let engine = try FolioEngine.inMemory(embeddingProvider: provider)

    _ = try await engine.ingestAsync(.text(body, name: "note.txt"), sourceId: "note")

    let results = try await engine.searchHybrid("streaming mode", in: "note", limit: 5, expand: 1)
}
```

Backed by [`john-rocky/CoreML-LLM`](https://github.com/john-rocky/CoreML-LLM) (MIT). The first `embed()` typically takes 30–60 s wall-clock (download + compile + ANE warm-up); subsequent calls are millisecond-scale. Output is 768-dim L2-normalised vectors; the underlying model supports Matryoshka truncation to 512/256/128 if you need smaller storage.

### Local HTTP (Ollama, native API)

For workflows that already run an embedding server on `localhost`:

```swift
let provider = EmbeddingGemmaEmbedder(
    configuration: .init(
        baseURL: URL(string: "http://127.0.0.1:11434")!,
        model: "embeddinggemma",
        dimension: 768
    )
)

let engine = try FolioEngine.inMemory(embeddingProvider: provider)
_ = try await engine.ingestAsync(.text(body, name: "note.txt"), sourceId: "note")
try await engine.backfillEmbeddings()
```

### OpenAI-compatible HTTP

For OpenAI itself or any provider mirroring the `/v1/embeddings` shape (including Ollama's OpenAI-compat mode):

```swift
let provider = OpenAIStyleEmbedder(
    configuration: .init(
        baseURL: URL(string: "https://api.openai.com")!,
        model: "text-embedding-3-small",
        dimension: 1536,
        apiKey: apiKey
    )
)

let engine = try FolioEngine.inMemory(embeddingProvider: provider)
_ = try await engine.ingestAsync(.text(body, name: "note.txt"), sourceId: "note")
try await engine.backfillEmbeddings()
```

`Configuration.dimension` is required and must match the model's output size; it gets persisted to the `embedding_indexes` table and validated on every write.

### Pure vector search

When you want vector-only ranking (paraphrase queries, cross-lingual recall, or anything where BM25 contributes noise), call `searchVectors` — it skips FTS entirely and scores every chunk in the configured embedding index by cosine:

```swift
let results = try await folio.searchVectors(
    "how do I configure retries?",
    in: "manual",
    limit: 5,
    expand: 1
)
```

`searchVectors` accepts the same `RetrievalFilter`, `expandToParent`, and `mmr:` options as `searchHybrid`. It throws code 412 if no `EmbeddingProvider` is wired.

### MMR diversification

Pass an `MMRConfig` to either `searchHybrid` or `searchVectors` to re-rank the top candidates so near-duplicates don't crowd the result list:

```swift
let results = try await folio.searchHybrid(
    "retries",
    in: "manual",
    limit: 5,
    mmr: MMRConfig(lambda: 0.5, k: 20)
)
```

`lambda` trades relevance (1.0) against novelty (0.0); `k` is the candidate pool MMR re-ranks before the top `limit` are returned.

### Parent-section expansion

When the chunker has produced a parent/child layout (e.g. markdown headings), `expandToParent: true` returns the full enclosing section instead of just the matched chunk plus a small neighbour window. Useful when you retrieve on a small chunk but want to feed the model the full context:

```swift
let results = try folio.searchWithContext(
    "retries",
    in: "manual",
    limit: 3,
    expand: 0,
    expandToParent: true
)
```

### Tests without a real embedder

`FakeEmbeddingProvider` produces deterministic vectors from a hash of the input. Use it in your own tests so retrieval paths can run without standing up a model:

```swift
let provider = FakeEmbeddingProvider(dimension: 8)
let engine = try FolioEngine.inMemory(embeddingProvider: provider)
```

## Generation: `answer()`

Once a `FolioEngine` is wired with both an `EmbeddingProvider` and a `TextGenerator`, the engine can run the full retrieval → prompt → generate → cite loop:

```swift
let engine = try FolioEngine.inMemory(
    embeddingProvider: provider,
    textGenerator: OpenAIStyleGenerator.cloud(.openAI(model: "gpt-4o-mini", apiKey: openAIKey))
)
_ = try await engine.ingestAsync(.pdf(pdfURL), sourceId: "manual")

let result = try await engine.answer("how do I configure retries?", in: "manual")
print(result.text)             // model's answer, with [1], [2], … markers preserved
print(result.citations)        // resolved Citation list in the order the markers appear
print(result.usedPassages)     // RetrievedResult list with BM25 + cosine + fused scores
print(result.confidence)       // heuristic in [0, 1]: mean fused score of cited passages
```

`confidence` is a heuristic, not a calibrated probability — it's the mean fused score of the passages the model actually cited, clamped to `[0, 1]`. Answers without any `[N]` markers (or with no retrieved passages) return `0`, which is the strongest signal that the answer isn't grounded. Treat thresholds as policy, not statistics.

Streaming uses the same shape but yields an `AnswerStreamEvent` stream — `.passages(...)` first, then `.text(delta)` fragments, then `.done(Answer)`:

```swift
let stream = try await engine.answerStream("how do I configure retries?", in: "manual")
for try await event in stream {
    switch event {
    case .passages(let passages):
        print("retrieved \(passages.count) candidates")
    case .text(let delta):
        print(delta, terminator: "")
    case .done(let answer):
        print("\n[citations: \(answer.citations.count)]")
    }
}
```

### Cloud generators (one-line setup)

`OpenAIStyleGenerator.cloud(...)` accepts a `CloudProvider` enum that pre-configures each provider's OpenAI-compatible endpoint and authentication:

```swift
.openAI(model: "gpt-4o-mini", apiKey: openAIKey)
.anthropic(model: "claude-sonnet-4-6", apiKey: anthropicKey)
.gemini(model: "gemini-2.0-flash", apiKey: googleKey)
.ollama(model: "llama3")                                  // localhost, no key
.custom(model: "router-1", baseURL: routerURL, apiKey: routerKey)
```

> Anthropic and Gemini are reached via each provider's OpenAI-compatible layer, which covers chat completion well. Provider-native features (Claude prompt caching, Gemini multimodal, etc.) require a dedicated `TextGenerator` conformance — not built in yet.

### On-device generation (Apple Foundation Models)

When the `FoundationModels` framework is available (iOS 26+/macOS 26+), `FoundationTextGenerator` runs answers entirely on-device with no network:

```swift
if #available(iOS 26, macOS 26, *) {
    let engine = try FolioEngine.inMemory(
        embeddingProvider: provider,
        textGenerator: FoundationTextGenerator()
    )
}
```

### On-device generation (Gemma 4, Core ML)

`GemmaCoreMLGenerator` wraps `CoreMLLLM`'s prebuilt Gemma 4 bundles (hosted by `mlboydaisuke` on Hugging Face). On first use it auto-downloads the model bundle (multi-GB) into `CoreMLLLM`'s managed cache and runs every subsequent call on the Apple Neural Engine. Opt-in only — never wired automatically — so callers never trigger an unexpected gigabyte download.

```swift
if #available(iOS 18, macOS 15, *) {
    // .e4b (default) is higher quality; .e2b is lower latency on older devices.
    let generator = GemmaCoreMLGenerator(size: .e4b)
    let engine = try FolioEngine.inMemory(
        embeddingProvider: provider,
        textGenerator: generator
    )

    // Optional: absorb the multi-GB warmup in the background at launch.
    Task.detached { try? await generator.prepare() }
}
```

`GenerationRequest.temperature` is ignored (CoreMLLLM does not expose it); `maxTokens` is honoured. The provider downloads model files via `CoreMLLLM.ModelDownloader`, so the cache location is whatever that downloader uses on the host platform.

### Tests without a real model

`FakeTextGenerator` returns deterministic responses and emits a `[1]` citation marker when at least one passage is present, so end-to-end retrieval/citation tests can run without standing up a model:

```swift
let engine = try FolioEngine.inMemory(
    embeddingProvider: FakeEmbeddingProvider(dimension: 8),
    textGenerator: FakeTextGenerator()
)
```

## OpenAI-Compatible Chat

`OpenAIStyleClient` posts to `v1/chat/completions`. By default it uses `http://127.0.0.1:11434`, which matches Ollama's OpenAI-compatible endpoint without duplicating `/v1`.

```swift
let client = OpenAIStyleClient()

let completion = try await client.chatCompletion(
    model: "gpt-4o-mini",
    messages: [
        .init(role: .system, content: "You are a concise assistant."),
        .init(role: .user, content: "Summarize this: ...")
    ],
    temperature: 0.3,
    maxTokens: 256
)

print(completion.choices.first?.message.content ?? "")
```

For hosted providers, pass a custom base URL and API key:

```swift
let client = OpenAIStyleClient(
    configuration: .init(
        baseURL: URL(string: "https://api.openai.com")!,
        apiKey: apiKey
    )
)
```

## Development

```bash
swift test
```

## Schema

Migrations are bundled as SPM resources and applied at runtime:

- `001_core.sql`: `sources`, `doc_chunks`
- `002_fts.sql`: `doc_chunks_fts`
- `003_indexes.sql`: indexes
- `004_prefix_cache.sql`: contextual prefix cache
- `005_embeddings.sql`: vector storage
- `006_tags.sql`: document-level `source_tags`

## License

MIT
