import XCTest
@testable import Folio

final class TextGeneratorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - OpenAIStyleGenerator unary

    func testOpenAIStyleGeneratorReturnsFirstChoiceContent() async throws {
        StubURLProtocol.stub = { request in
            let body = """
            {
              "id": "id-1",
              "choices": [
                { "index": 0, "message": { "role": "assistant", "content": "hi there" }, "finish_reason": "stop" }
              ],
              "usage": null
            }
            """.data(using: .utf8)!
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let session = makeStubbedSession()
        let generator = OpenAIStyleGenerator(
            model: "gpt-4o-mini",
            client: OpenAIStyleClient(
                configuration: .init(baseURL: URL(string: "https://api.openai.com")!, apiKey: "sk-test"),
                session: session
            )
        )

        let response = try await generator.generate(GenerationRequest(messages: [
            ChatMessage(role: .system, content: "be brief"),
            ChatMessage(role: .user, content: "say hi")
        ]))
        XCTAssertEqual(response, "hi there")

        let captured = try XCTUnwrap(StubURLProtocol.captured)
        XCTAssertEqual(captured.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured.bodyData()) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
        XCTAssertNil(json["stream"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "say hi")
    }

    // MARK: - OpenAIStyleGenerator streaming

    func testStreamParsesSSEDeltasInOrderAndFinishesOnDone() async throws {
        let sse = [
            #"data: {"choices":[{"index":0,"delta":{"content":"hello"}}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"content":" world"}}]}"#,
            "",
            "data: [DONE]",
            ""
        ].joined(separator: "\n")

        StubURLProtocol.stub = { request in
            return (
                sse.data(using: .utf8)!,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            )
        }

        let session = makeStubbedSession()
        let generator = OpenAIStyleGenerator(
            model: "gpt-4o-mini",
            client: OpenAIStyleClient(
                configuration: .init(baseURL: URL(string: "https://api.openai.com")!, apiKey: "sk-test"),
                session: session
            )
        )

        var collected: [String] = []
        for try await chunk in generator.stream(GenerationRequest(messages: [
            ChatMessage(role: .user, content: "say hi")
        ])) {
            collected.append(chunk)
        }

        XCTAssertEqual(collected, ["hello", " world"])

        let captured = try XCTUnwrap(StubURLProtocol.captured)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured.bodyData()) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testStreamPropagatesNon200WithStatusCode() async {
        StubURLProtocol.stub = { request in
            return (
                "rate limited".data(using: .utf8)!,
                HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            )
        }

        let session = makeStubbedSession()
        let generator = OpenAIStyleGenerator(
            model: "gpt-4o-mini",
            client: OpenAIStyleClient(
                configuration: .init(baseURL: URL(string: "https://api.openai.com")!, apiKey: "sk-test"),
                session: session
            )
        )

        do {
            for try await _ in generator.stream(GenerationRequest(messages: [
                ChatMessage(role: .user, content: "say hi")
            ])) {
                XCTFail("Stream should not yield before error")
            }
            XCTFail("Stream should have thrown")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Folio")
            XCTAssertEqual(error.code, 429)
        }
    }

    // MARK: - CloudProvider factory

    func testCloudFactoryProducesCorrectEndpointsForEachProvider() async throws {
        let cases: [(CloudProvider, String, String?, String)] = [
            (.openAI(model: "gpt-4o-mini", apiKey: "key"),
             "https://api.openai.com/v1/chat/completions",
             "Bearer key",
             "gpt-4o-mini"),
            (.anthropic(model: "claude-sonnet-4-6", apiKey: "anthropic-key"),
             "https://api.anthropic.com/v1/chat/completions",
             "Bearer anthropic-key",
             "claude-sonnet-4-6"),
            (.gemini(model: "gemini-2.0-flash", apiKey: "gemini-key"),
             "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
             "Bearer gemini-key",
             "gemini-2.0-flash"),
            (.ollama(model: "llama3"),
             "http://127.0.0.1:11434/v1/chat/completions",
             nil,
             "llama3"),
            (.custom(model: "router-1", baseURL: URL(string: "https://router.example.com")!, apiKey: "rk"),
             "https://router.example.com/v1/chat/completions",
             "Bearer rk",
             "router-1")
        ]

        for (provider, expectedURL, expectedAuth, expectedModel) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.stub = { request in
                let body = """
                {"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":null}
                """.data(using: .utf8)!
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            let session = makeStubbedSession()
            let generator = OpenAIStyleGenerator.cloud(provider, session: session)
            XCTAssertEqual(generator.model, expectedModel)

            _ = try await generator.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "ping")]))
            let captured = try XCTUnwrap(StubURLProtocol.captured, "captured for \(expectedURL)")
            XCTAssertEqual(captured.url?.absoluteString, expectedURL)
            XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), expectedAuth)
        }
    }

    // MARK: - engine.answer() integration

    func testEngineAnswerThrowsWithoutTextGenerator() async throws {
        let folio = try FolioEngine.inMemory(embeddingProvider: FakeEmbeddingProvider(dimension: 3))
        _ = try await folio.ingestAsync(.text("hello world from folio", name: "note.txt"), sourceId: "T")

        do {
            _ = try await folio.answer("hello")
            XCTFail("Expected throw without text generator")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Folio")
            XCTAssertEqual(error.code, 600)
        }
    }

    func testEngineAnswerReturnsTextAndCitations() async throws {
        let folio = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 3),
            textGenerator: FakeTextGenerator()
        )
        _ = try await folio.ingestAsync(.text("the quick brown fox jumps over the lazy dog", name: "fox.txt"), sourceId: "fox")

        let result = try await folio.answer("what jumps over the dog?", in: "fox")

        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.text.contains("[1]"), "Fake generator should emit [1] when passages are present")
        XCTAssertFalse(result.usedPassages.isEmpty)
        XCTAssertFalse(result.citations.isEmpty)
        XCTAssertEqual(result.citations.first?.sourceId, "fox")
    }

    func testEngineAnswerStreamYieldsPassagesThenTextThenDone() async throws {
        let folio = try FolioEngine.inMemory(
            embeddingProvider: FakeEmbeddingProvider(dimension: 3),
            textGenerator: FakeTextGenerator(canned: "Synthesised reply [1] based on the source.")
        )
        _ = try await folio.ingestAsync(.text("the quick brown fox jumps over the lazy dog", name: "fox.txt"), sourceId: "fox")

        let stream = try await folio.answerStream("what jumps over the dog?", in: "fox")

        var events: [AnswerStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }

        guard events.count >= 3 else {
            XCTFail("Expected at least passages, one text chunk, and done; got \(events.count) events")
            return
        }

        if case .passages(let p) = events.first! {
            XCTAssertFalse(p.isEmpty)
        } else {
            XCTFail("First event should be .passages")
        }

        if case .done(let answer) = events.last! {
            XCTAssertTrue(answer.text.contains("Synthesised reply"))
            XCTAssertFalse(answer.citations.isEmpty)
            XCTAssertEqual(answer.citations.first?.sourceId, "fox")
        } else {
            XCTFail("Last event should be .done")
        }

        let textEvents = events.compactMap { event -> String? in
            if case .text(let t) = event { return t }
            return nil
        }
        XCTAssertFalse(textEvents.isEmpty)
    }

    // MARK: - Citation marker resolution

    func testCitationResolverDedupesAndPreservesOrder() {
        let passages: [RetrievedResult] = (1...3).map { i in
            RetrievedResult(
                sourceId: "src-\(i)",
                startPage: nil,
                excerpt: "excerpt-\(i)",
                text: "text-\(i)",
                bm25: 0,
                cosine: nil,
                score: 0,
                citations: [Citation(
                    sourceId: "src-\(i)",
                    sourceName: "doc-\(i)",
                    fileType: "text",
                    page: nil,
                    sectionTitle: nil,
                    chunkId: "chunk-\(i)",
                    parentId: nil,
                    excerpt: nil
                )]
            )
        }

        let text = "First [2], then [1] and again [2], finally [3]."
        let resolved = resolveCitationMarkers(in: text, passages: passages)

        XCTAssertEqual(resolved.map { $0.chunkId }, ["chunk-2", "chunk-1", "chunk-3"])
    }

    func testCitationResolverIgnoresOutOfBoundMarkers() {
        let passages: [RetrievedResult] = [
            RetrievedResult(
                sourceId: "a",
                startPage: nil,
                excerpt: "e",
                text: "t",
                bm25: 0,
                cosine: nil,
                score: 0,
                citations: [Citation(
                    sourceId: "a",
                    sourceName: "doc",
                    fileType: "text",
                    page: nil,
                    sectionTitle: nil,
                    chunkId: "only",
                    parentId: nil,
                    excerpt: nil
                )]
            )
        ]

        let text = "answer [42] uses a missing marker but [1] is valid"
        let resolved = resolveCitationMarkers(in: text, passages: passages)
        XCTAssertEqual(resolved.map { $0.chunkId }, ["only"])
    }
}
