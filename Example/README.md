# Folio Demo

Multi-platform SwiftUI app that exercises Folio end-to-end: ingest a bundled
document, ask a question, see the streamed answer with resolved citations.

## Run on macOS (fastest loop)

The demo is wired into Folio's own `Package.swift` as a non-exported executable
target, so you can run it from the repo root without any extra setup:

```bash
swift run FolioDemo
```

Open `Package.swift` in Xcode and you'll also see `FolioDemo` as a runnable scheme
alongside the `Folio` library and `FolioTests`.

A window appears with backend / API key fields, an "Ingest sample" button, and
a question field. Steps:

1. Pick a backend.
   - **OpenAI (cloud):** paste an API key and (optionally) change the model.
   - **Apple Foundation Models (on-device):** no key required; needs macOS 26+.
2. Press **Ingest sample**. Folio ingests the bundled Swift concurrency notes
   into an in-memory index.
3. Type a question and press **Ask**. `engine.answerStream()` retrieves passages,
   prompts the model with numbered markers, and streams the answer token by token.
   Citations appear below the answer.

## Move it to iOS

The sources in `Sources/FolioDemo/` are platform-agnostic SwiftUI. To run on iOS:

1. In Xcode 26: **File → New → Project → Multiplatform → App**.
2. Set both iOS 26 and macOS 26 deployment targets.
3. **File → Add Package Dependencies → Add Local…** and point at the Folio repo root.
4. Drag the four `.swift` files from this folder's `Sources/FolioDemo/` into the
   new app target.
5. Build and run on simulator or device.

## What this verifies

End-to-end paths that the package's own tests can only mock:

- `OpenAIStyleGenerator.cloud(.openAI(...))` against real OpenAI servers (response
  shape, SSE streaming).
- `FoundationTextGenerator` running an actual `LanguageModelSession.respond(...)`
  inside the `#if canImport(FoundationModels)` branch that never compiled before.
- `engine.answerStream()` end-to-end, including citation marker resolution from
  real model output.

## What this *doesn't* verify

- A real document corpus larger than the bundled sample (the inspector view lets you
  pick any PDF / text / markdown via the iOS Files picker once running).
- Stress testing under heavy concurrent load — the demo serialises one ask at a time
  by design so the UI stays predictable.
