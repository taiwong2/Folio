//
//  EvalHarness.swift
//  Folio
//
//  Drives fixture-based evaluation against a `FolioEngine`. Decodes fixtures
//  in the schema documented at Tests/FolioTests/Fixtures/eval/*.json, ingests
//  the documents, runs each query through retrieval or `answer()`, and
//  aggregates recall@k / MRR@k / citation coverage so later milestones can
//  measure regressions.
//

import Foundation

// MARK: - Fixture schema

public struct EvalDocument: Sendable, Decodable {
    public let name: String
    public let text: String
    public let tags: [String]?
}

public struct EvalQuery: Sendable, Decodable {
    public let question: String
    public let mustCiteSourceIds: [String]?
    public let mustCiteChunkIds: [String]?
    public let expectedAnswerContains: [String]?
    public let mustRefuse: Bool?
    public let limit: Int?

    enum CodingKeys: String, CodingKey {
        case question
        case mustCiteSourceIds = "must_cite_source_ids"
        case mustCiteChunkIds = "must_cite_chunk_ids"
        case expectedAnswerContains = "expected_answer_contains"
        case mustRefuse = "must_refuse"
        case limit
    }
}

public struct EvalFixture: Sendable, Decodable {
    public let name: String
    public let documents: [EvalDocument]
    public let queries: [EvalQuery]

    public static func decode(from data: Data) throws -> EvalFixture {
        try JSONDecoder().decode(EvalFixture.self, from: data)
    }
}

// MARK: - Per-query results

public struct RetrievalQueryResult: Sendable {
    public let question: String
    public let retrievedSourceIds: [String]
    public let mustCiteSourceIds: [String]
    public let recall: Double?
    public let reciprocalRank: Double?
    public let precision: Double?
}

public struct GenerationQueryResult: Sendable {
    public let question: String
    public let answerText: String
    public let citedSourceIds: [String]
    public let confidence: Double
    public let refused: Bool
    public let citationCoverage: Double
    public let expectedContentsHit: Bool?
    public let refusalCorrect: Bool?
}

// MARK: - Aggregated metrics

public struct RetrievalMetrics: Sendable, Hashable {
    public let k: Int
    public let queryCount: Int
    public let recallAtK: Double
    public let mrrAtK: Double
    public let precisionAtK: Double
}

public struct GenerationMetrics: Sendable, Hashable {
    public let queryCount: Int
    public let citationCoverage: Double
    public let expectedContentsHit: Double
    public let refusalCorrect: Double
}

public struct EvalRetrievalReport: Sendable {
    public let fixtureName: String
    public let metrics: RetrievalMetrics
    public let queries: [RetrievalQueryResult]
}

public struct EvalGenerationReport: Sendable {
    public let fixtureName: String
    public let metrics: GenerationMetrics
    public let queries: [GenerationQueryResult]
}

// MARK: - Runner

public enum EvalRunner {
    public static func ingest(fixture: EvalFixture, into engine: FolioEngine) async throws {
        for doc in fixture.documents {
            let tagSet = doc.tags.map { Set($0) }
            _ = try await engine.ingestAsync(
                .text(doc.text, name: doc.name),
                sourceId: doc.name,
                tags: tagSet
            )
        }
    }

    public static func retrieve(
        fixture: EvalFixture,
        engine: FolioEngine,
        defaultLimit: Int = 5
    ) async throws -> EvalRetrievalReport {
        var results: [RetrievalQueryResult] = []
        var recallSum = 0.0
        var mrrSum = 0.0
        var precSum = 0.0
        var counted = 0

        for q in fixture.queries {
            let k = q.limit ?? defaultLimit
            let hits = try await engine.retrieve(q.question, limit: k)
            let retrievedSources = hits.map(\.sourceId)
            let must = Set(q.mustCiteSourceIds ?? [])

            var recall: Double? = nil
            var rr: Double? = nil
            var prec: Double? = nil
            if !must.isEmpty {
                let topK = Array(retrievedSources.prefix(k))
                let hitCount = topK.reduce(into: 0) { acc, sid in if must.contains(sid) { acc += 1 } }
                let uniqueHits = Set(topK).intersection(must).count
                recall = Double(uniqueHits) / Double(must.count)
                prec = Double(hitCount) / Double(k)
                rr = topK.firstIndex(where: { must.contains($0) }).map { 1.0 / Double($0 + 1) } ?? 0
                recallSum += recall!
                mrrSum += rr!
                precSum += prec!
                counted += 1
            }

            results.append(RetrievalQueryResult(
                question: q.question,
                retrievedSourceIds: retrievedSources,
                mustCiteSourceIds: Array(must),
                recall: recall,
                reciprocalRank: rr,
                precision: prec
            ))
        }

        let n = max(counted, 1)
        let metrics = RetrievalMetrics(
            k: defaultLimit,
            queryCount: counted,
            recallAtK: recallSum / Double(n),
            mrrAtK: mrrSum / Double(n),
            precisionAtK: precSum / Double(n)
        )
        return EvalRetrievalReport(fixtureName: fixture.name, metrics: metrics, queries: results)
    }

    public static func answer(
        fixture: EvalFixture,
        engine: FolioEngine,
        defaultLimit: Int = 5,
        template: AnswerTemplate = .default,
        policy: AnswerPolicy = .default
    ) async throws -> EvalGenerationReport {
        var results: [GenerationQueryResult] = []
        var coverageSum = 0.0
        var expectedHits = 0
        var expectedTotal = 0
        var refusalCorrects = 0
        var refusalTotal = 0

        for q in fixture.queries {
            let limit = q.limit ?? defaultLimit
            let ans = try await engine.answer(q.question, limit: limit, template: template, policy: policy)
            let citedSourceIds = Array(Set(ans.citations.map(\.sourceId))).sorted()
            let refused = ans.text.contains("[NO_ANSWER]") || ans.text == policy.refusalText
            let coverage = computeCitationCoverage(ans.text)
            coverageSum += coverage

            var expectedHit: Bool? = nil
            if let expected = q.expectedAnswerContains, !expected.isEmpty {
                expectedHit = expected.allSatisfy { ans.text.localizedCaseInsensitiveContains($0) }
                expectedTotal += 1
                if expectedHit == true { expectedHits += 1 }
            }

            var refusalCorrect: Bool? = nil
            if let must = q.mustRefuse {
                refusalCorrect = (refused == must)
                refusalTotal += 1
                if refusalCorrect == true { refusalCorrects += 1 }
            }

            results.append(GenerationQueryResult(
                question: q.question,
                answerText: ans.text,
                citedSourceIds: citedSourceIds,
                confidence: ans.confidence,
                refused: refused,
                citationCoverage: coverage,
                expectedContentsHit: expectedHit,
                refusalCorrect: refusalCorrect
            ))
        }

        let n = fixture.queries.count
        let metrics = GenerationMetrics(
            queryCount: n,
            citationCoverage: n == 0 ? 0 : coverageSum / Double(n),
            expectedContentsHit: expectedTotal == 0 ? 0 : Double(expectedHits) / Double(expectedTotal),
            refusalCorrect: refusalTotal == 0 ? 0 : Double(refusalCorrects) / Double(refusalTotal)
        )
        return EvalGenerationReport(fixtureName: fixture.name, metrics: metrics, queries: results)
    }
}

// MARK: - Helpers

/// Fraction of sentences in `text` that contain at least one `[N]` citation
/// marker. A sentence is any span terminated by `.`, `!`, or `?`; trailing text
/// without a terminator counts as one sentence. Empty input returns 0.
public func computeCitationCoverage(_ text: String) -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }

    var sentences: [String] = []
    var current = ""
    for ch in trimmed {
        current.append(ch)
        if ch == "." || ch == "!" || ch == "?" {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { sentences.append(t) }
            current = ""
        }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { sentences.append(tail) }
    guard !sentences.isEmpty else { return 0 }

    let regex = /\[(\d+)\]/
    let cited = sentences.filter { $0.contains(regex) }.count
    return Double(cited) / Double(sentences.count)
}
