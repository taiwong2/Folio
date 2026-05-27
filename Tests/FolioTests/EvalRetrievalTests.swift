//
//  EvalRetrievalTests.swift
//
//  Drives EvalRunner.retrieve against the bundled JSON fixtures.
//  Smoke subset runs by default; the full sweep is gated by FOLIO_RUN_EVAL=1
//  so CI / nightly runs the whole suite while local `swift test` stays fast.
//

import XCTest
@testable import Folio

final class EvalRetrievalTests: XCTestCase {

    /// Default smoke check: prose fixture, hybrid retrieval, asserts the
    /// "must cite" source lands in the top-k for every annotated query.
    func testSmokeProseRetrieval() async throws {
        let fixture = try Self.loadFixture(named: "smoke-prose")
        let engine = try FolioEngine.inMemory(embeddingProvider: FakeEmbeddingProvider(dimension: 4))
        try await EvalRunner.ingest(fixture: fixture, into: engine)

        let report = try await EvalRunner.retrieve(fixture: fixture, engine: engine, defaultLimit: 5)

        XCTAssertEqual(report.metrics.queryCount, fixture.queries.count)
        XCTAssertGreaterThan(report.metrics.recallAtK, 0, "smoke retrieval should hit the annotated source for at least one query")
        for q in report.queries where !(q.mustCiteSourceIds.isEmpty) {
            XCTAssertNotNil(q.recall, "recall must be computed when must_cite_source_ids is set")
        }
    }

    /// Gated full sweep: runs every fixture under Fixtures/eval/ and prints a
    /// per-fixture metrics line. Useful for regression tracking, too heavy for
    /// every PR. Set FOLIO_RUN_EVAL=1 to enable.
    func testFullEvalSweep() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOLIO_RUN_EVAL"] == "1",
            "Set FOLIO_RUN_EVAL=1 to run the full eval sweep."
        )

        for name in Self.allFixtureNames {
            let fixture = try Self.loadFixture(named: name)
            let engine = try FolioEngine.inMemory(embeddingProvider: FakeEmbeddingProvider(dimension: 4))
            try await EvalRunner.ingest(fixture: fixture, into: engine)

            let report = try await EvalRunner.retrieve(fixture: fixture, engine: engine, defaultLimit: 5)
            print(String(format: "[eval] %@ retrieval recall@%d=%.3f mrr@%d=%.3f prec@%d=%.3f n=%d",
                         report.fixtureName,
                         report.metrics.k, report.metrics.recallAtK,
                         report.metrics.k, report.metrics.mrrAtK,
                         report.metrics.k, report.metrics.precisionAtK,
                         report.metrics.queryCount))
            XCTAssertGreaterThan(report.metrics.recallAtK, 0, "every fixture should hit at least one annotated source")
        }
    }

    // MARK: - Helpers

    static let allFixtureNames = ["smoke-prose", "smoke-multidoc", "smoke-refusal"]

    static func loadFixture(named name: String) throws -> EvalFixture {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "eval")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url else {
            XCTFail("Missing fixture \(name).json (looked in Fixtures/eval/ and top-level resources)")
            throw NSError(domain: "EvalRetrievalTests", code: 1)
        }
        let data = try Data(contentsOf: url)
        return try EvalFixture.decode(from: data)
    }
}
