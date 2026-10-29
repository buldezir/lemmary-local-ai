import Foundation

/// Hands a request to a llama-server on loopback and its answer back. A
/// streamed completion (server-sent events) is passed on as it arrives, and a
/// client that hangs up cancels the upstream request, which stops llama-server
/// generating. Any other answer is read whole first.
public struct UpstreamProxy: Sendable {
    let timeout: TimeInterval

    /// Long enough for any completion; the client's own timeout ends a request
    /// sooner.
    public init(timeout: TimeInterval = 3600) {
        self.timeout = timeout
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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil

        do {
            let (http, body) = try await StreamingFetch().start(upstream, configuration: configuration)
            var headers = HTTPHeaders()
            if let type = http.value(forHTTPHeaderField: "Content-Type") {
                headers.set("Content-Type", type)
            }
            let status = HTTPStatus(http.statusCode, HTTPStatus.reason(for: http.statusCode))
            if headers["Content-Type"]?.lowercased().hasPrefix("text/event-stream") == true {
                headers.set("Cache-Control", "no-cache")
                return .streaming(status: status, headers: headers, body)
            }
            var whole = Data()
            for try await chunk in body {
                whole.append(chunk)
            }
            return HTTPResponse(status: status, headers: headers, body: whole)
        } catch let error as URLError where error.code == .timedOut {
            return .openAIError(.gatewayTimeout, "\(service) did not answer in time", type: "server_error")
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .openAIError(.serviceUnavailable, "\(service) is not running", type: "server_error")
        } catch {
            return .openAIError(.badGateway, "\(service): \(error.localizedDescription)", type: "server_error")
        }
    }
}

/// One upstream request whose body is read as it arrives. URLSession's async
/// `bytes(for:)` hands a body over a byte at a time; a delegate gets the chunks
/// as the network delivered them.
final class StreamingFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var head: CheckedContinuation<HTTPURLResponse, Error>?
    /// Only the writing end. The session holds this object until the request
    /// ends, and holding the stream itself would keep it alive after its reader
    /// had gone, so a client that hung up would never cancel the request.
    private var chunks: AsyncThrowingStream<Data, Error>.Continuation?

    /// Sends the request and returns once the response's head is in, with the
    /// body to follow. Releasing that body, or cancelling its reader, cancels
    /// the request: that is how a client hanging up stops llama-server.
    func start(_ request: URLRequest, configuration: URLSessionConfiguration)
        async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        // The session holds its delegate until it is invalidated, at the end.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let (body, chunks) = AsyncThrowingStream<Data, Error>.makeStream()
        chunks.onTermination = { _ in task.cancel() }
        lock.withLock { self.chunks = chunks }
        let http = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { head = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (http, body)
    }

    private func resumeHead(_ result: Result<HTTPURLResponse, Error>) {
        let waiting = lock.withLock {
            defer { head = nil }
            return head
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            resumeHead(.success(http))
        } else {
            resumeHead(.failure(URLError(.badServerResponse)))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = lock.withLock { chunks }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Only still waiting if no head ever came.
        resumeHead(.failure(error ?? URLError(.badServerResponse)))
        let chunks = lock.withLock {
            defer { self.chunks = nil }
            return self.chunks
        }
        if let error {
            chunks?.finish(throwing: error)
        } else {
            chunks?.finish()
        }
        session.finishTasksAndInvalidate()
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
