import Foundation

/// `URLProtocol` that intercepts every request a `URLSession` makes, captures it for
/// inspection, and returns whatever `(Data, HTTPURLResponse)` the test's `stub`
/// closure yields. Reset state between tests via `reset()`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stub: (@Sendable (URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var captured: URLRequest?

    static func reset() {
        stub = nil
        captured = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        guard let handler = Self.stub else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// Reads the request body whether it's stored as `httpBody` or `httpBodyStream`
    /// (URLSession sometimes converts one to the other before delivering to a
    /// `URLProtocol`). Returns an empty Data if no body is present.
    func bodyData() -> Data {
        if let data = httpBody { return data }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}

func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}
