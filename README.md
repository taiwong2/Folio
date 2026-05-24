# Folio

Folio is an early Swift Package for building retrieval-augmented generation cores on Apple platforms. It currently focuses on ingestion, chunking, local SQLite search, optional contextual prefixes, vector storage, and an OpenAI-compatible chat client.

The package targets iOS 26+ for apps and macOS 26+ so the package can build and test on local macOS hosts.

## Current Features

- PDF and plain text ingestion
- PDF text extraction with Vision OCR fallback when available
- Universal text chunking
- Header and footer cleanup
- SQLite storage with FTS5 BM25 search
- Contextual prefix hooks and prefix cache
- Apple Foundation Models prefix helper when `FoundationModels` is available on iOS 26+ or macOS 26+
- Vector storage for embedded chunks with model-id + dimension validation
- **All-in-one on-device EmbeddingGemma 300M (`EmbeddingGemmaProvider`)** — in-process Core ML inference on the Apple Neural Engine, auto-downloads + caches the model on first use, zero CocoaPods
- Local-server EmbeddingGemma via Ollama (`EmbeddingGemmaEmbedder`)
- OpenAI-compatible embedding adapter (`OpenAIStyleEmbedder`) for hosted providers or local servers
- Public `FakeEmbeddingProvider` for consumer-side tests
- Hybrid retrieval prototype using BM25 candidates, cosine scoring, rank fusion, and neighbor expansion
- OpenAI-compatible chat completions client (with SSE streaming) for local runtimes or hosted providers
- Pluggable `TextGenerator` protocol with backends for OpenAI-compatible cloud (`OpenAIStyleGenerator.cloud(...)`), Apple Foundation Models (`FoundationTextGenerator`), and a `FakeTextGenerator` for tests
- High-level `engine.answer(_:)` / `engine.answerStream(_:)` that retrieve, prompt, generate, and resolve inline citation markers in one call

## Planned Features

- DOCX ingestion
- Image indexing beyond PDF OCR fallback
- On-device LLM generation (Gemma / Qwen / etc.) — currently best served through `OpenAIStyleGenerator.cloud(.ollama(...))` against a local Ollama; an in-process Core ML generator is potential future work
- Full vector candidate search instead of BM25-first hybrid retrieval
- Native (non-OpenAI-compat) Anthropic and Gemini generators for provider-specific features
- MMR diversification, reranking, and confidence-policy helpers

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

try folio.ingest(
    .text("hello world from folio", name: "note.txt"),
    sourceId: "T1"
)

let hits = try folio.search("hello", in: "T1", limit: 5)
for hit in hits {
    print("\(hit.sourceId): \(hit.excerpt)")
}
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
```

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

## License

MIT
