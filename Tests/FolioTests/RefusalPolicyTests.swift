//
//  RefusalPolicyTests.swift
//
//  V2.1 — verifies AnswerPolicy and GroundingChecker behavior end-to-end
//  through FolioEngine.answer and as pure functions.
//

import XCTest
@testable import Folio

final class RefusalPolicyTests: XCTestCase {

    // MARK: - End-to-end through engine.answer

    func testNoAnswerTokenTriggersRefusalRegardlessOfPolicy() async throws {
        let engine = try await makeEngine(responder: { _ in "[NO_ANSWER]" })

        let answer = try await engine.answer("capital of France?", policy: .default)

        XCTAssertEqual(answer.text, AnswerPolicy.default.refusalText)
        XCTAssertEqual(answer.confidence, 0)
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertFalse(answer.usedPassages.isEmpty, "refusal preserves usedPassages for the UI")
    }

    func testDefaultPolicyDoesNotRefuseValidAnswer() async throws {
        let engine = try await makeEngine(responder: { _ in "Paris is the capital [1]." })

        let answer = try await engine.answer("capital of France?")

        XCTAssertEqual(answer.text, "Paris is the capital [1].")
        XCTAssertGreaterThan(answer.confidence, 0)
    }

    func testRequireCitationsBlocksUncitedAnswer() async throws {
        let engine = try await makeEngine(responder: { _ in "Paris is the capital." })

        let answer = try await engine.answer(
            "capital of France?",
            policy: AnswerPolicy(requireCitations: true)
        )

        XCTAssertEqual(answer.text, AnswerPolicy.default.refusalText)
        XCTAssertEqual(answer.confidence, 0)
    }

    func testShouldRefuseFiresOnLowConfidence() {
        // End-to-end the FakeEmbeddingProvider produces ~1.0 cosine for the
        // single seeded chunk, so test the branch via `shouldRefuseAnswer`
        // with explicit values rather than relying on retrieval math.
        let passages = [Self.makePassage(text: "x")]
        let policy = AnswerPolicy(minConfidence: 0.5)
        XCTAssertTrue(shouldRefuseAnswer(
            text: "claim [1].",
            citations: [],
            confidence: 0.3,
            passages: passages,
            policy: policy
        ))
        XCTAssertFalse(shouldRefuseAnswer(
            text: "claim [1].",
            citations: [],
            confidence: 0.6,
            passages: passages,
            policy: policy
        ))
    }

    func testMinQuoteGroundingRefusesFabricatedQuote() async throws {
        let engine = try await makeEngine(
            responder: { _ in #"The text says "Paris was founded in 250 BC" [1]."# }
        )

        let answer = try await engine.answer(
            "Paris facts?",
            policy: AnswerPolicy(minQuoteGrounding: 1.0)
        )

        XCTAssertEqual(answer.text, AnswerPolicy.default.refusalText)
    }

    func testMinQuoteGroundingPassesWithVerbatimQuote() async throws {
        // The fixture doc contains "The capital of France is Paris." — the
        // responder quotes a verbatim span, so grounding == 1.0.
        let engine = try await makeEngine(
            responder: { _ in #""The capital of France is Paris" [1]."# }
        )

        let answer = try await engine.answer(
            "capital of France?",
            policy: AnswerPolicy(minQuoteGrounding: 1.0)
        )

        XCTAssertNotEqual(answer.text, AnswerPolicy.default.refusalText)
        XCTAssertTrue(answer.text.contains("Paris"))
    }

    func testMinNumericConsistencyRefusesFabricatedNumber() async throws {
        let engine = try await makeEngine(responder: { _ in "Population is 9999999 [1]." })

        let answer = try await engine.answer(
            "Paris population?",
            policy: AnswerPolicy(minNumericConsistency: 1.0)
        )

        XCTAssertEqual(answer.text, AnswerPolicy.default.refusalText)
    }

    func testStrictPresetCombinesConfidenceAndCitations() async throws {
        let engine = try await makeEngine(responder: { _ in "Paris is the capital." })

        let answer = try await engine.answer("capital of France?", policy: .strict)

        XCTAssertEqual(answer.text, AnswerPolicy.default.refusalText,
                       "strict preset rejects uncited answers")
    }

    // MARK: - Pure-function tests

    func testQuoteGroundingReturnsOneWhenNoQuotes() {
        let passages = [Self.makePassage(text: "anything")]
        XCTAssertEqual(quoteGrounding(text: "no quotes here", passages: passages), 1.0)
    }

    func testQuoteGroundingHitsVerbatim() {
        let passages = [Self.makePassage(text: "The cat sat on the mat.")]
        let score = quoteGrounding(text: #"The doc says "cat sat on the mat" — and "fabricated" too."#, passages: passages)
        XCTAssertEqual(score, 0.5, accuracy: 1e-9)
    }

    func testNumericConsistencyReturnsOneWhenNoNumbers() {
        let passages = [Self.makePassage(text: "anything")]
        XCTAssertEqual(numericConsistency(text: "no numbers", passages: passages), 1.0)
    }

    func testNumericConsistencyDetectsFabricatedNumber() {
        let passages = [Self.makePassage(text: "Founded in 1985. Population 2,148,000.")]
        let score = numericConsistency(text: "Founded 1985 with 9999 people.", passages: passages)
        XCTAssertEqual(score, 0.5, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeEngine(
        responder: @escaping FakeTextGenerator.Responder
    ) async throws -> FolioEngine {
        let engine = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 4),
            textGenerator: FakeTextGenerator(respond: responder)
        )
        _ = try await engine.ingestAsync(
            .text("The capital of France is Paris. It has a population of about 2 million.",
                  name: "paris.txt"),
            sourceId: "paris.txt"
        )
        return engine
    }

    static func makePassage(text: String) -> RetrievedResult {
        RetrievedResult(
            sourceId: "s1",
            startPage: nil,
            excerpt: "",
            text: text,
            bm25: 0,
            cosine: nil,
            score: 1.0,
            citations: []
        )
    }
}
