import XCTest
@testable import LCTMac

/// Tests for OllamaService error types
final class OllamaErrorTests: XCTestCase {

    func testOllamaError_InvalidURL_ErrorDescription() {
        let error = OllamaError.invalidURL
        XCTAssertEqual(error.errorDescription, "Invalid Ollama API URL")
    }

    func testOllamaError_NetworkError_ErrorDescription() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        let error = OllamaError.networkError(underlyingError)

        XCTAssertTrue(error.errorDescription?.contains("Network error") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("Connection refused") ?? false)
    }

    func testOllamaError_InvalidResponse_ErrorDescription() {
        let error = OllamaError.invalidResponse
        XCTAssertEqual(error.errorDescription, "Invalid response from Ollama")
    }

    func testOllamaError_HTTPError_ErrorDescription() {
        let error = OllamaError.httpError(404)
        XCTAssertEqual(error.errorDescription, "HTTP error: 404")
    }

    func testOllamaError_DecodingError_ErrorDescription() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        let error = OllamaError.decodingError(underlyingError)

        XCTAssertTrue(error.errorDescription?.contains("Failed to decode") ?? false)
    }

    func testOllamaError_Timeout_ErrorDescription() {
        let error = OllamaError.timeout
        XCTAssertEqual(error.errorDescription, "Request timed out")
    }

    func testOllamaError_ServerNotRunning_ErrorDescription() {
        let error = OllamaError.serverNotRunning
        XCTAssertEqual(error.errorDescription, "Ollama server is not running")
    }

    func testOllamaError_ModelNotLoaded_ErrorDescription() {
        let error = OllamaError.modelNotLoaded
        XCTAssertEqual(error.errorDescription, "Model not loaded")
    }
}

/// Tests for Ollama API Codable structures
final class OllamaAPIStructsTests: XCTestCase {

    func testOllamaMessage_Codable() throws {
        let message = OllamaMessage(role: "user", content: "Hello")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OllamaMessage.self, from: data)

        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Hello")
    }

    func testOllamaChatRequest_Codable() throws {
        let request = OllamaChatRequest(
            model: "qwen2.5:3b",
            messages: [OllamaMessage(role: "user", content: "Test")],
            stream: false,
            temperature: 0.3,
            keepAlive: "5m",
            think: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)

        let jsonString = String(data: data, encoding: .utf8)!

        // Verify snake_case encoding
        XCTAssertTrue(jsonString.contains("keep_alive"))

        // Verify values
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OllamaChatRequest.self, from: data)

        XCTAssertEqual(decoded.model, "qwen2.5:3b")
        XCTAssertEqual(decoded.stream, false)
        XCTAssertEqual(decoded.temperature, 0.3)
        XCTAssertEqual(decoded.keepAlive, "5m")
        XCTAssertEqual(decoded.think, false)
    }

    func testOllamaChatResponse_Codable() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "Hello!"},
            "done": true,
            "total_duration": 1000000000,
            "load_duration": 100000000,
            "prompt_eval_count": 10,
            "prompt_eval_duration": 200000000,
            "eval_count": 20,
            "eval_duration": 500000000
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(OllamaChatResponse.self, from: data)

        XCTAssertEqual(response.message?.role, "assistant")
        XCTAssertEqual(response.message?.content, "Hello!")
        XCTAssertTrue(response.done)
        XCTAssertEqual(response.totalDuration, 1000000000)
        XCTAssertEqual(response.evalCount, 20)
    }

    func testOllamaChatResponse_PartialResponse() throws {
        let json = """
        {
            "done": false
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(OllamaChatResponse.self, from: data)

        XCTAssertNil(response.message)
        XCTAssertFalse(response.done)
    }
}
