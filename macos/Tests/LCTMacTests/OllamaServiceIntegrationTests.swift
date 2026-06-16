import Foundation
import XCTest
@testable import LCTMac

@MainActor
final class OllamaServiceIntegrationTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTranslate_ModelMissing_ThrowsModelNotLoaded() async throws {
        let service = makeService { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await service.translate(text: "Hello")
            XCTFail("Expected modelNotLoaded")
        } catch OllamaError.modelNotLoaded {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranslate_Timeout_ThrowsTimeout() async throws {
        let service = makeService { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await service.translate(text: "Hello")
            XCTFail("Expected timeout")
        } catch OllamaError.timeout {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranslateStreaming_ConnectionLost_ThrowsServerNotRunning() async throws {
        let service = makeService { _ in
            throw URLError(.networkConnectionLost)
        }

        do {
            _ = try await service.translateStreaming(text: "Hello") { _ in }
            XCTFail("Expected serverNotRunning")
        } catch OllamaError.serverNotRunning {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPrewarmModel_Success_ReturnsLatency() async throws {
        let service = makeService { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"message":{"role":"assistant","content":"ok"},"done":true}"#
            return (response, Data(body.utf8))
        }

        let latency = try await service.prewarmModel()
        XCTAssertGreaterThanOrEqual(latency, 0)
    }

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> OllamaService {
        MockURLProtocol.requestHandler = handler

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        var settings = AppSettings()
        settings.ollamaHost = "mock.local"
        settings.ollamaPort = 80
        settings.ollamaModel = "missing-model"
        settings.ollamaTimeout = 1

        let session = URLSession(configuration: config)
        return OllamaService(settings: settings, session: session)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
