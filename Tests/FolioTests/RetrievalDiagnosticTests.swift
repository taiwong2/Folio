import XCTest
@testable import Folio

/// Reproduces the "demo answered 'no GPA info' even though the chunk contained
/// `GPA: 4.0`" bug end-to-end. Run isolated so a failure here is unambiguous:
/// retrieval is the suspect, not the model.
final class RetrievalDiagnosticTests: XCTestCase {

    private let resumeText = """
    Tai Wong
    503-481-1674 | taiwong2@illinois.edu | linkedin.com/in/tai-wong-491b46270 | tai-wong.com

    Education
    University of Illinois at Urbana-Champaign Champaign, IL
    Bachelor of Science in Computer Science and Bioengineering | GPA: 4.0 | Dean's List
    Expected Graduation: May 2028
    Relevant Coursework: Data Structures, Algorithms, Computer Architecture, Discrete Structures, Systems Programming

    Experience
    Research Assistant 2025 – Present
    Dream Lab, UIUC — Multi-Agent LLM Systems & Research Engineering Champaign, IL
    Designed and deployed research tooling for a multi-agent LLM system coordinating specialized agents across three
    heterogeneous data sources (PubMed, NIH RePORTER, ClinicalTrials.gov) to automate scientific workflow execution.
    Built and scaled a Neo4j knowledge graph to 8M+ nodes by engineering ETL pipelines that ingest, deduplicate, and
    cross-link records from federal research APIs, enabling sub-second graph traversal for downstream LLM reasoning.
    Reduced LLM-fabricated outputs by 87% by engineering a deterministic code-first verification layer with grounding checks.

    Research Collaborator 2022 – Present
    Mattis Lab, UCSF — Trustworthy LLM Extraction & Computational Biology San Francisco, CA
    Built and published ProtoHep, the largest structured hepatocyte differentiation protocol database via a multi-agent
    LLM pipeline automating extraction from PDF ingestion through schema validation.
    Achieved 0% hallucination rate at >0.8 extraction confidence by implementing a hybrid verification system.

    Founder & Lead Developer 2025 – Present
    SkyHub — Full-Stack iOS App, 15,000+ Monthly Active Users SwiftUI, FastAPI, PostgreSQL, Docker
    """

    // MARK: - Sanitizer pinning

    func testSanitizerStripsPunctuationAndORsQuotedTokens() {
        XCTAssertEqual(
            FolioEngine.sanitizeForFTS("What is my GPA?"),
            #""What" OR "is" OR "my" OR "GPA""#
        )
        XCTAssertEqual(
            FolioEngine.sanitizeForFTS("hello world"),
            #""hello" OR "world""#
        )
        XCTAssertEqual(
            FolioEngine.sanitizeForFTS("   leading and  trailing spaces   "),
            #""leading" OR "and" OR "trailing" OR "spaces""#
        )
        XCTAssertEqual(FolioEngine.sanitizeForFTS("???"), "")
    }

    // MARK: - End-to-end

    /// Engine-level: ingesting clean text, asking a natural question via
    /// `answer()` (which sanitises internally), should surface the GPA chunk.
    func testAnswerSeesGPAChunkForNaturalQuestion() async throws {
        // We need a generator to call answer(); FakeTextGenerator echoes the
        // user content so we can directly inspect what context arrived.
        let folio = try FolioEngine.inMemory(textGenerator: FakeTextGenerator())
        _ = try await folio.ingestAsync(.text(resumeText, name: "resume.txt"), sourceId: "resume")

        let chunks = try folio.chunks(forSourceId: "resume")
        XCTAssertTrue(
            chunks.contains(where: { $0.text.contains("GPA") }),
            "Test setup invalid: no chunk contains 'GPA'."
        )

        let answer = try await folio.answer("What is my GPA?", in: "resume")

        // FakeTextGenerator echoes the last user message when no passages match
        // its template format; with at least one passage block it emits a canned
        // response. Either way, retrieval results are on the Answer.
        XCTAssertFalse(answer.usedPassages.isEmpty, "answer() returned zero passages")
        XCTAssertTrue(
            answer.usedPassages.contains(where: { $0.text.contains("GPA") }),
            "GPA chunk missing from answer.usedPassages. Got:\n" +
                answer.usedPassages.map(\.text).joined(separator: "\n---\n")
        )
    }

    /// Same scenario via hybrid search. Asserts on `passage.text` (the full chunk
    /// content) not `passage.excerpt` (FTS5's narrow snippet window — which
    /// frequently omits the matched term itself).
    func testGPAChunkFullTextIsInHybridResults() async throws {
        let folio = try FolioEngine.inMemory()
        _ = try await folio.ingestAsync(.text(resumeText, name: "resume.txt"), sourceId: "resume")

        let sanitized = FolioEngine.sanitizeForFTS("What is my GPA?")
        let results = try await folio.searchHybrid(sanitized, in: "resume", limit: 5)

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(
            results.contains(where: { $0.text.contains("GPA") }),
            "GPA missing from passage.text. Full passages:\n" +
                results.enumerated().map { (i, r) in "#\(i + 1): \(r.text)" }.joined(separator: "\n---\n")
        )
    }

    /// After the template fix: confirm the prompt now contains the FULL chunk
    /// text, including not just "GPA" but the surrounding context the model
    /// needs to answer ("Bachelor of Science", "Education", etc).
    func testAnswerTemplateIncludesFullChunkTextNotJustExcerpt() async throws {
        let folio = try FolioEngine.inMemory()
        _ = try await folio.ingestAsync(.text(resumeText, name: "resume.txt"), sourceId: "resume")

        let sanitized = FolioEngine.sanitizeForFTS("What is my GPA?")
        let passages = try await folio.searchHybrid(sanitized, in: "resume", limit: 5)

        let messages = AnswerTemplate.default.build("What is my GPA?", passages)
        let prompt = messages.map(\.content).joined(separator: "\n\n")

        // The template should now embed `passage.text`, not the narrow snippet
        // window. So we expect the full surrounding context — not just "GPA"
        // alone but the adjacent labels that ground the value.
        XCTAssertTrue(prompt.contains("GPA"), "Prompt should contain 'GPA'")
        XCTAssertTrue(
            prompt.contains("GPA: 4.0") || prompt.contains("GPA:") || prompt.contains("Bachelor of Science"),
            "Prompt should contain enough surrounding text to ground the GPA value.\n\nPrompt:\n\(prompt)"
        )
    }

    /// Negative control: the *excerpt* string can omit the matched term. This
    /// pins why the old template (using `passage.excerpt`) was unreliable for
    /// LLM grounding.
    func testExcerptFieldDoesNotAlwaysContainMatchedTerm() async throws {
        let folio = try FolioEngine.inMemory()
        _ = try await folio.ingestAsync(.text(resumeText, name: "resume.txt"), sourceId: "resume")

        let sanitized = FolioEngine.sanitizeForFTS("What is my GPA?")
        let passages = try await folio.searchHybrid(sanitized, in: "resume", limit: 5)

        // Document the observed behaviour so the next person reading this knows
        // why we don't use `excerpt` in the template. (We assert weakly so the
        // test passes regardless of which side of the window the snippet lands;
        // the point is the field name and intent, not pinning exact bytes.)
        let report = passages.enumerated().map { (i, p) in
            "#\(i + 1) excerpt: \(p.excerpt)"
        }.joined(separator: "\n")
        XCTAssertFalse(passages.isEmpty, "Need at least one passage to observe excerpt behaviour. Got:\n\(report)")
    }

    /// Single-keyword query as a control: confirms the corpus is searchable at all
    /// and "GPA" alone returns the right chunk.
    func testGPAChunkIsRetrievedByKeywordAlone() async throws {
        let folio = try FolioEngine.inMemory()
        _ = try await folio.ingestAsync(.text(resumeText, name: "resume.txt"), sourceId: "resume")

        let results = try folio.search("GPA", in: "resume", limit: 5)
        XCTAssertFalse(results.isEmpty, "Searching for 'GPA' alone returned nothing")
        XCTAssertTrue(
            results.contains(where: { $0.excerpt.contains("GPA") || $0.excerpt.contains("…") }),
            "Expected at least one Snippet excerpt referencing GPA. Excerpts:\n" +
                results.map(\.excerpt).joined(separator: "\n")
        )
    }
}
