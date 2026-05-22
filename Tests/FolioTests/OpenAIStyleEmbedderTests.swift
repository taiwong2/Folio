import XCTest
@testable import Folio

final class OpenAIStyleEmbedderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        makeStubbedSession()
    }

    private func makeEmbedder(apiKey: String? = "test-key", session: URLSession) -> OpenAIStyleEmbedder {
        OpenAIStyleEmbedder(
            configuration: .init(
                baseURL: URL(string: "https://api.openai.com")!,
                model: "text-embedding-3-small",
                dimension: 4,
                apiKey: apiKey
            ),
            session: session
        )
    }

    func testRequestShapeAndDecoding() async throws {
        StubURLProtocol.stub = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            { "data": [ { "embedding": [0.5, 1.5, 2.5, 3.5], "index": 0 } ] }
            """.data(using: .utf8)!
            return (body, response)
        }

        let session = makeSession()
        let embedder = makeEmbedder(session: session)
        let vector = try await embedder.embed("hello")

        XCTAssertEqual(vector, [0.5, 1.5, 2.5, 3.5])

        let captured = try XCTUnwrap(StubURLProtocol.captured)
        XCTAssertEqual(captured.url?.absoluteString, "https://api.openai.com/v1/embeddings")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let bodyData = captured.bodyData()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "text-embedding-3-small")
        XCTAssertEqual(json["input"] as? [String], ["hello"])
    }

    func testEmbedBatchSortsResponseByIndex() async throws {
        StubURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            { "data": [
                { "embedding": [9, 9, 9, 9], "index": 2 },
                { "embedding": [0, 0, 0, 0], "index": 0 },
                { "embedding": [1, 1, 1, 1], "index": 1 }
            ] }
            """.data(using: .utf8)!
            return (body, response)
        }

        let session = makeSession()
        let embedder = makeEmbedder(session: session)
        let vectors = try await embedder.embedBatch(["a", "b", "c"])

        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(vectors[0], [0, 0, 0, 0])
        XCTAssertEqual(vectors[1], [1, 1, 1, 1])
        XCTAssertEqual(vectors[2], [9, 9, 9, 9])

        let captured = try XCTUnwrap(StubURLProtocol.captured)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured.bodyData()) as? [String: Any])
        XCTAssertEqual(json["input"] as? [String], ["a", "b", "c"])
    }

    func testServerErrorPropagatesStatusCode() async {
        StubURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return ("upstream timeout".data(using: .utf8)!, response)
        }

        let session = makeSession()
        let embedder = makeEmbedder(session: session)
        do {
            _ = try await embedder.embed("hello")
            XCTFail("Expected error to be thrown")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Folio")
            XCTAssertEqual(error.code, 502)
        }
    }

    func testNoAuthHeaderWhenApiKeyMissing() async throws {
        StubURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            { "data": [ { "embedding": [0, 0, 0, 0], "index": 0 } ] }
            """.data(using: .utf8)!
            return (body, response)
        }

        let session = makeSession()
        let embedder = makeEmbedder(apiKey: nil, session: session)
        _ = try await embedder.embed("hello")

        let captured = try XCTUnwrap(StubURLProtocol.captured)
        XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
    }

    func testEmptyBatchSkipsRequest() async throws {
        StubURLProtocol.stub = { _ in
            XCTFail("Empty batch should not perform a network request")
            return (Data(), HTTPURLResponse())
        }

        let session = makeSession()
        let embedder = makeEmbedder(session: session)
        let vectors = try await embedder.embedBatch([])
        XCTAssertEqual(vectors, [])
        XCTAssertNil(StubURLProtocol.captured)
    }
}

