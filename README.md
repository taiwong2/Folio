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
- On-device EmbeddingGemma via MediaPipe (`MediaPipeTextEmbedderAdapter.embeddingGemma300m`)
- Hybrid retrieval prototype using BM25 candidates, cosine scoring, rank fusion, and neighbor expansion
- OpenAI-compatible chat completions client for local runtimes or hosted providers

## Planned Features

- DOCX ingestion
- Image indexing beyond PDF OCR fallback
- LiteRT-LM Gemma generation integration
- High-level `answer()` orchestration
- Full vector candidate search instead of BM25-first hybrid retrieval
- Citation generation and source attribution helpers

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

### On-device (MediaPipe + EmbeddingGemma)

Bundle the EmbeddingGemma 300M model file (`.task`/`.tflite` from [litert-community/embeddinggemma-300m](https://huggingface.co/litert-community/embeddinggemma-300m)) with your app, then:

```swift
let modelURL = Bundle.main.url(forResource: "embeddinggemma-300m", withExtension: "task")!
let provider = try MediaPipeTextEmbedderAdapter.embeddingGemma300m(modelPath: modelURL)

let engine = try FolioEngine.inMemory(embeddingProvider: provider)
_ = try await engine.ingestAsync(.text(body, name: "note.txt"), sourceId: "note")
try await engine.backfillEmbeddings()

let results = try await engine.searchHybrid(
    "streaming mode",
    in: "note",
    limit: 5,
    expand: 1
)
```

> **Note:** MediaPipe Tasks for iOS only ships via CocoaPods, which cannot be added to a pure SPM `Package.swift`. The factory above is therefore only compiled inside `#if canImport(MediaPipeTasksText)` and is not exercised by Folio's own test suite — it will only type-check inside a host app that installs the `MediaPipeTasksText` pod alongside Folio. End-to-end verification will land via a demo app.

### Local HTTP (Ollama)

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

`Configuration.dimension` is required and must match the model's output size; it gets persisted to the `embedding_indexes` table and validated on every write.

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
