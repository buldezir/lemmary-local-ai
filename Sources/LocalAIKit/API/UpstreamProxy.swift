import Foundation

/// Hands a request to a llama-server on loopback and its answer back. The
/// answer is buffered: a streamed completion arrives whole, at the end.
public struct UpstreamProxy: Sendable {
    let session: URLSession

    /// Long enough for any completion; the client's own timeout ends a request
    /// sooner.
    public init(timeout: TimeInterval = 3600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// Hop-by-hop and framing headers, which belong to each connection, and
    /// Accept-Encoding, which URLSession sets for itself.
    static let notForwarded: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "expect", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-connection", "proxy-authorization", "accept-encoding",
    ]

    /// `service` names the upstream in an error, e.g. "the text model".
    public func forward(_ request: HTTPRequest, path: String, port: Int, service: String) async -> HTTPResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        let query = request.head.target.split(separator: "?", maxSplits: 1).dropFirst().first
        components.percentEncodedQuery = query.map(String.init)
        guard let url = components.url else {
            return .openAIError(.badRequest, "malformed request target")
        }

        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        if !request.body.isEmpty {
            upstream.httpBody = request.body
        }
        for field in request.headers.fields where !Self.notForwarded.contains(field.name.lowercased()) {
            upstream.addValue(field.value, forHTTPHeaderField: field.name)
        }

        do {
            let (body, response) = try await session.data(for: upstream)
            guard let http = response as? HTTPURLResponse else {
                return .openAIError(.badGateway, "\(service) sent no HTTP response", type: "server_error")
            }
            var headers = HTTPHeaders()
            if let type = http.value(forHTTPHeaderField: "Content-Type") {
                headers.set("Content-Type", type)
            }
            return HTTPResponse(status: HTTPStatus(http.statusCode, HTTPStatus.reason(for: http.statusCode)), headers: headers, body: body)
        } catch let error as URLError where error.code == .timedOut {
            return .openAIError(.gatewayTimeout, "\(service) did not answer in time", type: "server_error")
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .openAIError(.serviceUnavailable, "\(service) is not running", type: "server_error")
        } catch {
            return .openAIError(.badGateway, "\(service): \(error.localizedDescription)", type: "server_error")
        }
    }
}

extension HTTPStatus {
    /// The reason phrase for a status passed through from upstream. Clients
    /// read the code; this only keeps the status line conventional.
    static func reason(for code: Int) -> String {
        let known: [HTTPStatus] = [
            .ok, .badRequest, .notFound, .methodNotAllowed, .requestTimeout, .lengthRequired, .payloadTooLarge,
            .unsupportedMediaType, .unprocessable, .headersTooLarge, .internalServerError, .notImplemented,
            .badGateway, .serviceUnavailable, .gatewayTimeout,
        ]
        return known.first { $0.code == code }?.reason ?? (code < 400 ? "OK" : "Error")
    }
}
