import XCTest
@testable import Folio

/// Live end-to-end check of `GemmaCoreMLGenerator`. Actually downloads a
/// multi-GB Core ML bundle to `CoreMLLLM`'s managed cache on first run,
/// loads it on the Apple Neural Engine, and runs real generation.
///
/// Skipped by default because the first run is very slow + network-bound
/// (multiple gigabytes). Enable with:
///
///     FOLIO_LIVE_GEMMA_GEN_TEST=1 swift test --filter GemmaCoreMLGeneratorLiveTests
///
/// Defaults to `Size.e2b` to keep the warmup as small as the available
/// Gemma 4 bundles allow. Override with `FOLIO_LIVE_GEMMA_GEN_SIZE=e4b`.
@available(iOS 18.0, macOS 15.0, *)
final class GemmaCoreMLGeneratorLiveTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOLIO_LIVE_GEMMA_GEN_TEST"] == "1",
            "Set FOLIO_LIVE_GEMMA_GEN_TEST=1 to run this live test (first run downloads several GB)."
        )
    }

    func testGenerateProducesNonEmptyResponse() async throws {
        let generator = GemmaCoreMLGenerator(size: chosenSize(), defaultMaxTokens: 32)
        let request = GenerationRequest(
            messages: [
                ChatMessage(role: .system, content: "Reply with one short sentence."),
                ChatMessage(role: .user, content: "Name a primary colour.")
            ],
            maxTokens: 32
        )
        let text = try await generator.generate(request)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Gemma should produce some text; got empty response")
    }

    func testStreamEmitsAtLeastOneChunk() async throws {
        let generator = GemmaCoreMLGenerator(size: chosenSize(), defaultMaxTokens: 32)
        let request = GenerationRequest(
            messages: [ChatMessage(role: .user, content: "Say hi.")],
            maxTokens: 16
        )
        var chunkCount = 0
        var accumulated = ""
        for try await chunk in generator.stream(request) {
            chunkCount += 1
            accumulated += chunk
        }
        XCTAssertGreaterThan(chunkCount, 0, "Stream should emit at least one chunk")
        XCTAssertFalse(accumulated.isEmpty, "Stream should accumulate non-empty text")
    }

    private func chosenSize() -> GemmaCoreMLGenerator.Size {
        let env = ProcessInfo.processInfo.environment["FOLIO_LIVE_GEMMA_GEN_SIZE"]?.lowercased()
        return env == "e4b" ? .e4b : .e2b
    }
}
