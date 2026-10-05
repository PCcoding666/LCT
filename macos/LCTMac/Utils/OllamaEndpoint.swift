import Foundation

/// Why an Ollama endpoint configuration was rejected.
enum OllamaEndpointError: LocalizedError, Equatable {
    case invalidHost
    case invalidPort
    case remoteOptInRequired

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Invalid Ollama host. Enter a bare host name without scheme, path, port, or credentials."
        case .invalidPort:
            return "Invalid Ollama port. Enter a number between 1 and 65535."
        case .remoteOptInRequired:
            return "Remote Ollama is disabled. Enable the remote opt-in to connect over HTTPS."
        }
    }
}

/// A validated Ollama endpoint. Loopback endpoints use HTTP; every
/// non-loopback endpoint requires the explicit remote opt-in and is
/// constructed with HTTPS only. Malformed input never produces an endpoint,
/// so no request can be sent.
struct OllamaEndpoint: Equatable {
    let host: String
    let port: Int
    let isLoopback: Bool

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    var scheme: String {
        isLoopback ? "http" : "https"
    }

    var baseURL: URL {
        // IPv6 literals must be bracketed inside a URL authority.
        let urlHost: String
        if host.hasPrefix("[") {
            urlHost = host
        } else if host.contains(":") {
            urlHost = "[\(host)]"
        } else {
            urlHost = host
        }
        guard let url = URL(string: "\(scheme)://\(urlHost):\(port)") else {
            preconditionFailure("Validated endpoint produced an invalid URL: \(host):\(port)")
        }
        return url
    }

    /// Canonical loopback endpoint used for local Ollama by default.
    static let local = OllamaEndpoint(host: "localhost", port: 11434, isLoopback: true)

    /// Parse a raw URL into an endpoint, accepting only well-formed loopback
    /// URLs. Remote endpoints are never derived from URLs; they must be built
    /// from explicit host/port settings via `validated`. Returns nil for
    /// anything malformed or non-loopback, so no request can be sent.
    static func parsedLoopback(from urlString: String) -> OllamaEndpoint? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let rawHost = components.host,
              let port = components.port
        else {
            return nil
        }

        return try? validated(host: rawHost, port: port, remoteOptIn: false)
    }

    /// Validate host/port/opt-in and return an endpoint, or throw
    /// `OllamaEndpointError`. Nothing here performs a network request.
    static func validated(host rawHost: String, port: Int, remoteOptIn: Bool) throws -> OllamaEndpoint {
        guard (1...65_535).contains(port) else {
            throw OllamaEndpointError.invalidPort
        }

        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw OllamaEndpointError.invalidHost
        }

        let isLoopback = loopbackHosts.contains(host.lowercased())

        if !isLoopback {
            // Reject embedded schemes, paths, credentials, ports, and any
            // character outside a conservative hostname charset.
            let forbidden = host.contains("://")
                || host.contains("/")
                || host.contains("@")
                || host.contains(":")
                || host.contains(" ")
            let validCharset = host.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
            }
            guard !forbidden, validCharset else {
                throw OllamaEndpointError.invalidHost
            }
        }

        guard isLoopback || remoteOptIn else {
            throw OllamaEndpointError.remoteOptInRequired
        }

        return OllamaEndpoint(host: host, port: port, isLoopback: isLoopback)
    }
}
