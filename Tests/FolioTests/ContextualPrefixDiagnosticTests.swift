import XCTest
@testable import Folio
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Live diagnostics for the contextual-prefix pipeline. Prints every chunk's
/// prefix + raw text + chars to stdout so we can see what `FoundationModelsPrefixGenerator`
/// (or the rule-based fallback) actually produced.
///
/// Skipped by default; enable with:
///
///     FOLIO_LIVE_PREFIX_TEST=1 swift test --filter ContextualPrefixDiagnosticTests
///
/// The second test additionally requires the user's actual resume at
///     ~/Documents/Personal Knowledge/Applications/amazon_agi_intern/tai_wong_resume.pdf
/// and is auto-skipped if absent.
@available(iOS 26.0, macOS 26.0, *)
final class ContextualPrefixDiagnosticTests: XCTestCase {

    private let resumeText = """
    Tai Wong
    503-481-1674 | taiwong2@illinois.edu | linkedin.com/in/tai-wong-491b46270

    Education
    University of Illinois at Urbana-Champaign Champaign, IL
    Bachelor of Science in Computer Science and Bioengineering | GPA: 4.0 | Dean's List
    Expected Graduation: May 2028
    Relevant Coursework: Data Structures, Algorithms, Computer Architecture, Discrete Structures, Systems Programming

    Experience
    Research Assistant 2025 – Present
    Dream Lab, UIUC — Multi-Agent LLM Systems & Research Engineering Champaign, IL
    Designed and deployed research tooling for a multi-agent LLM system coordinating specialized agents.
    Built and scaled a Neo4j knowledge graph to 8M+ nodes by engineering ETL pipelines.
    Reduced LLM-fabricated outputs by 87% by engineering a deterministic code-first verification layer.

    Founder & Lead Developer 2025 – Present
    SkyHub — Full-Stack iOS App, 15,000+ Monthly Active Users SwiftUI, FastAPI, PostgreSQL, Docker
    """

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FOLIO_LIVE_PREFIX_TEST"] == "1",
            "Set FOLIO_LIVE_PREFIX_TEST=1 to run live prefix diagnostics."
        )
    }

    // MARK: - Synthetic resume

    func testGeneratedPrefixesForSyntheticResume() async throws {
        let config = makeConfigWithPrefixes()

        let folio = try FolioEngine.inMemory()
        _ = try await folio.ingestAsync(
            .text(resumeText, name: "tai_wong_resume.txt"),
            sourceId: "resume",
            config: config
        )

        let chunks = try folio.chunks(forSourceId: "resume")
        print("\n========== SYNTHETIC RESUME ==========")
        printChunks(chunks)

        XCTAssertFalse(chunks.isEmpty, "Expected at least one chunk")
        XCTAssertTrue(
            chunks.allSatisfy { !$0.contextPrefix.isEmpty },
            "Every chunk should have a non-empty prefix when contextual prefixes are enabled"
        )
    }

    // MARK: - Real PDF

    func testGeneratedPrefixesForRealResumePDF() async throws {
        let url = URL(fileURLWithPath: NSString(string: "~/Documents/Personal Knowledge/Applications/amazon_agi_intern/tai_wong_resume.pdf").expandingTildeInPath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Resume PDF not at \(url.path); skipping."
        )

        let config = makeConfigWithPrefixes()
        let folio = try FolioEngine.inMemory()
        let result = try await folio.ingestAsync(.pdf(url), sourceId: "resume-pdf", config: config)

        let chunks = try folio.chunks(forSourceId: "resume-pdf")
        print("\n========== REAL RESUME PDF (\(result.pages) page(s), \(result.chunks) chunk(s)) ==========")
        printChunks(chunks)

        // Diagnostics: ratio of prefix size to chunk size, per chunk.
        for (i, chunk) in chunks.enumerated() {
            let ratio = Double(chunk.contextPrefix.count) / Double(max(chunk.text.count, 1))
            print(String(format: "Chunk %d: prefix=%d chars, text=%d chars, ratio=%.2f%%",
                         i + 1, chunk.contextPrefix.count, chunk.text.count, ratio * 100))
        }
    }

    // MARK: - Helpers

    private func makeConfigWithPrefixes() -> FolioConfig {
        var config = FolioConfig()
        config.indexing.useContextualPrefix = true
        #if canImport(FoundationModels)
        let generator = FoundationModelsPrefixGenerator()
        config.indexing.contextFn = { doc, page, chunk in
            await generator.prefixWithFallback(for: doc, page: page, chunk: chunk)
        }
        #endif
        return config
    }

    private func printChunks(_ chunks: [InspectableChunk]) {
        for (i, chunk) in chunks.enumerated() {
            print("--- Chunk \(i + 1) (\(chunk.text.count) chars) ---")
            if let section = chunk.sectionTitle {
                print("section: \(section)")
            }
            print("PREFIX (\(chunk.contextPrefix.count) chars):")
            print("    \(chunk.contextPrefix)")
            print("TEXT:")
            for line in chunk.text.split(separator: "\n").prefix(10) {
                print("    \(line)")
            }
            if chunk.text.split(separator: "\n").count > 10 {
                print("    … (truncated)")
            }
            print()
        }
    }
}
