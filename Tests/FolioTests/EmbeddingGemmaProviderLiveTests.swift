import XCTest
@testable import Folio

/// Live end-to-end check of `EmbeddingGemmaProvider`. Actually downloads the
/// Core ML model bundle (~300 MB) to `~/Library/Application Support/Folio/models/`
/// on first run, loads it on the Apple Neural Engine, and runs real embeddings.
///
/// Skipped by default because the first run is slow + network-bound. Enable with:
///
///     FOLIO_LIVE_GEMMA_TEST=1 swift test --filter EmbeddingGemmaProviderLiveTests
@available(iOS 18.0, macOS 15.0, *)
final class EmbeddingGemmaProviderLiveTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOLIO_LIVE_GEMMA_TEST"] == "1",
            "Set FOLIO_LIVE_GEMMA_TEST=1 to run this live test (first run downloads ~300 MB)."
        )
    }

    func testEmbedReturns768DimUnitNormVector() async throws {
        let provider = EmbeddingGemmaProvider()
        let vec = try await provider.embed("the quick brown fox jumps over the lazy dog")

        XCTAssertEqual(vec.count, 768, "EmbeddingGemma 300M should output 768-dim vectors")

        // Provider's underlying model L2-normalises the output (per HF model card).
        var sumSq: Float = 0
        for x in vec { sumSq += x * x }
        let norm = sqrtf(sumSq)
        XCTAssertEqual(norm, 1.0, accuracy: 0.01, "Output should be L2-unit-normalised; got \(norm)")
    }

    func testSameInputProducesIdenticalVectors() async throws {
        let provider = EmbeddingGemmaProvider()
        let a = try await provider.embed("hello world from EmbeddingGemma")
        let b = try await provider.embed("hello world from EmbeddingGemma")
        XCTAssertEqual(a, b, "Same input must produce identical vectors (deterministic Core ML inference)")
    }

    func testRelatedTextsAreCloserThanUnrelatedTexts() async throws {
        let provider = EmbeddingGemmaProvider()
        let cat = try await provider.embed("Cats are small carnivorous mammals often kept as pets.")
        let dog = try await provider.embed("Dogs are loyal domesticated mammals descended from wolves.")
        let finance = try await provider.embed("Federal Reserve sets interest rates to manage inflation.")

        let catDog = cosine(cat, dog)
        let catFinance = cosine(cat, finance)

        XCTAssertGreaterThan(
            catDog,
            catFinance,
            "Cats vs dogs should be semantically closer than cats vs Fed policy: catDog=\(catDog), catFinance=\(catFinance)"
        )
        // Loose absolute floor — EmbeddingGemma's task-prefixed embeddings are
        // more discriminative than raw similarity, so even related sentences
        // typically cosine in the 0.4–0.7 range, not the 0.7+ you'd see from
        // older sentence-transformer baselines. The relative ordering above is
        // the real correctness signal.
        XCTAssertGreaterThan(catDog, 0.3, "Semantically related pair should be at least mildly correlated, got \(catDog)")
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        // Vectors are L2-unit norm; dot product equals cosine similarity.
        var dot: Float = 0
        for (x, y) in zip(a, b) { dot += x * y }
        return dot
    }
}
