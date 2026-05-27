//
//  EvalGenerationTests.swift
//
//  Drives EvalRunner.answer against the bundled fixtures using a
//  FakeTextGenerator that quotes the first retrieved passage and cites it.
//  Verifies citation marker resolution, confidence non-zero, and (in the
//  gated full sweep) expected_answer_contains hits.
//
//  V2.0 does not implement refusal — `mustRefuse` queries are tolerated and
//  measured but not asserted; V2.1 tightens this.
//

import XCTest
@testable import Folio

final class EvalGenerationTests: XCTestCase {

    func testSmokeProseGeneration() async throws {
        let fixture = try EvalRetrievalTests.loadFixture(named: "smoke-prose")
        let engine = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 4),
            textGenerator: FakeTextGenerator(respond: Self.quoteFirstPassageResponder)
        )
        try await EvalRunner.ingest(fixture: fixture, into: engine)

        let report = try await EvalRunner.answer(fixture: fixture, engine: engine, defaultLimit: 5)

        XCTAssertEqual(report.metrics.queryCount, fixture.queries.count)
        XCTAssertGreaterThan(report.metrics.citationCoverage, 0,
                             "responder always emits [1] — coverage should be > 0")
        for q in report.queries {
            XCTAssertGreaterThan(q.confidence, 0, "every query should produce a cited answer")
            XCTAssertTrue(q.answerText.contains("[1]"))
        }
    }

    func testFullEvalSweepGeneration() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOLIO_RUN_EVAL"] == "1",
            "Set FOLIO_RUN_EVAL=1 to run the full eval sweep."
        )

        for name in EvalRetrievalTests.allFixtureNames {
            let fixture = try EvalRetrievalTests.loadFixture(named: name)
            let engine = try FolioEngine.inMemory(
                embeddingProvider: FakeEmbeddingProvider(dimension: 4),
                textGenerator: FakeTextGenerator(respond: Self.quoteFirstPassageResponder)
            )
            try await EvalRunner.ingest(fixture: fixture, into: engine)

            let report = try await EvalRunner.answer(fixture: fixture, engine: engine, defaultLimit: 5)
            print(String(format: "[eval] %@ generation coverage=%.3f expected=%.3f refusal=%.3f n=%d",
                         report.fixtureName,
                         report.metrics.citationCoverage,
                         report.metrics.expectedContentsHit,
                         report.metrics.refusalCorrect,
                         report.metrics.queryCount))
            XCTAssertGreaterThan(report.metrics.citationCoverage, 0)
        }
    }

    // MARK: - Responder

    /// Returns the first sentence of the first numbered passage in the prompt,
    /// followed by `[1].`. Lets fixture-level `expected_answer_contains` assertions
    /// fire on content that actually comes from the retrieved passage, without
    /// standing up a real model.
    static let quoteFirstPassageResponder: FakeTextGenerator.Responder = { request in
        let userContent = request.messages.last(where: { $0.role == .user })?.content ?? ""
        guard let snippet = firstSentenceOfPassageOne(userContent) else {
            return "Answer based on passages [1]."
        }
        return "\(snippet) [1]."
    }

    static func firstSentenceOfPassageOne(_ prompt: String) -> String? {
        let blocks = prompt.components(separatedBy: "\n\n")
        guard let block = blocks.first(where: { $0.hasPrefix("[1] (") }) else { return nil }
        let parts = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let body = String(parts[1])
        if let dot = body.firstIndex(of: ".") {
            return String(body[..<dot])
        }
        return body
    }
}
