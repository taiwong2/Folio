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

    /// Refusal smoke: must_refuse queries paired with a refusal-aware responder
    /// and strict policy should produce refusal_correct == 1.0 across all queries.
    func testSmokeRefusal() async throws {
        let fixture = try EvalRetrievalTests.loadFixture(named: "smoke-refusal")
        let engine = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 4),
            textGenerator: FakeTextGenerator(respond: Self.refusalAwareResponder(for: fixture))
        )
        try await EvalRunner.ingest(fixture: fixture, into: engine)

        let report = try await EvalRunner.answer(
            fixture: fixture,
            engine: engine,
            defaultLimit: 5,
            template: .strict,
            policy: .strict
        )

        XCTAssertEqual(report.metrics.refusalCorrect, 1.0,
                       "every must_refuse query should refuse, every other should not")
        for q in report.queries where q.refused {
            XCTAssertEqual(q.answerText, AnswerPolicy.default.refusalText)
            XCTAssertEqual(q.confidence, 0)
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
                textGenerator: FakeTextGenerator(respond: Self.refusalAwareResponder(for: fixture))
            )
            try await EvalRunner.ingest(fixture: fixture, into: engine)

            let report = try await EvalRunner.answer(
                fixture: fixture,
                engine: engine,
                defaultLimit: 5,
                template: .strict,
                policy: .strict
            )
            print(String(format: "[eval] %@ generation coverage=%.3f expected=%.3f refusal=%.3f n=%d",
                         report.fixtureName,
                         report.metrics.citationCoverage,
                         report.metrics.expectedContentsHit,
                         report.metrics.refusalCorrect,
                         report.metrics.queryCount))
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

    /// Wraps `quoteFirstPassageResponder` but returns `[NO_ANSWER]` when the
    /// fixture has marked the parsed question as `must_refuse: true`. Lets the
    /// generation sweep exercise refusal end-to-end without coupling fixtures
    /// to test code.
    static func refusalAwareResponder(for fixture: EvalFixture) -> FakeTextGenerator.Responder {
        let refuseSet = Set(fixture.queries.filter { $0.mustRefuse == true }.map(\.question))
        return { request in
            let userContent = request.messages.last(where: { $0.role == .user })?.content ?? ""
            for line in userContent.split(separator: "\n") {
                if line.hasPrefix("Question: ") {
                    let q = String(line.dropFirst("Question: ".count))
                    if refuseSet.contains(q) {
                        return "[NO_ANSWER]"
                    }
                    break
                }
            }
            return quoteFirstPassageResponder(request)
        }
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
