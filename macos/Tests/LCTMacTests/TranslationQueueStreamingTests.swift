import XCTest
@testable import LCTMac

/// Regression tests for the streaming translation path: the final result must
/// contain every streamed token, even when the server delivers the content and
/// the `done` chunk in the same response (the fastest possible stream).
@MainActor
final class TranslationQueueStreamingTests: XCTestCase {

    /// Serves a fixed NDJSON body for `/api/chat`, all at once.
    private final class InstantStreamProtocol: URLProtocol {
        nonisolated(unsafe) static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        InstantStreamProtocol.body = Data()
        super.tearDown()
    }

    private func makeQueue() -> TranslationQueue {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstantStreamProtocol.self]
        var settings = AppSettings()
        settings.ollamaTimeout = 5
        let service = OllamaService(settings: settings, session: URLSession(configuration: config))
        return TranslationQueue(ollamaService: service)
    }

    private func ndjson(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func translate(_ queue: TranslationQueue) async -> TranslationQueueResult? {
        let completed = expectation(description: "translation completes")
        var result: TranslationQueueResult?
        queue.onTranslationComplete = { completedResult in
            result = completedResult
            completed.fulfill()
        }
        queue.enqueue(segmentId: UUID(), text: "你好世界", priority: .high, isFinal: true)
        await fulfillment(of: [completed], timeout: 5)
        return result
    }

    func testStreaming_ContentAndDoneInOneResponse_FinalResultHasFullText() async {
        InstantStreamProtocol.body = ndjson([
            #"{"message":{"role":"assistant","content":"Hello"},"done":false}"#,
            #"{"message":{"role":"assistant","content":", world"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true}"#,
        ])
        let queue = makeQueue()

        let result = await translate(queue)

        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.translatedText, "Hello, world",
                       "every streamed token must be in the final result, not just the ones that landed before completion")
    }

    func testStreaming_SingleChunkWithDone_FinalResultIsNotEmpty() async {
        InstantStreamProtocol.body = ndjson([
            #"{"message":{"role":"assistant","content":"Hi"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true}"#,
        ])
        let queue = makeQueue()

        let result = await translate(queue)

        XCTAssertEqual(result?.translatedText, "Hi")
    }
}
