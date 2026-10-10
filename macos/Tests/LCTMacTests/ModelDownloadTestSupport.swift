import Foundation
import XCTest

/// Thread-safe record of requests captured by a mock URL protocol.
final class RecordedRequestLog: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private var records: [Recorded] = []

    func append(method: String, path: String, body: Data?) {
        lock.lock()
        records.append(Recorded(method: method, path: path, body: body))
        lock.unlock()
    }

    var snapshot: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func reset() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }
}

/// How the stub answers a request: a full immediate response, or a stream
/// that delivers its bytes but never finishes (for cancellation tests).
enum PullStubResponse {
    case respond(Int, Data)
    case hang
}

/// Offline stand-in for the Ollama HTTP API. Registered via
/// `URLSessionConfiguration.protocolClasses`; no request leaves the process.
final class PullMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> PullStubResponse)?
    nonisolated(unsafe) static var log: RecordedRequestLog?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.log?.append(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            body: Self.readBody(of: request)
        )

        guard let response = Self.requestHandler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch response {
        case .respond(let statusCode, let data):
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case .hang:
            // Report success headers so bytes(for:) starts streaming, then
            // stay open forever — only a cancellation (stopLoading) ends it.
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() {}

    /// The URL loading system may hand the body to the protocol either inline
    /// or as a stream; accept both.
    static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

extension XCTestCase {
    /// Poll until `condition` holds or the deadline passes; returns the final value.
    @MainActor
    func waitForCondition(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
