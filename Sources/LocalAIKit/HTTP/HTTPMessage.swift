import Foundation

public struct HTTPStatus: Sendable, Equatable {
    public var code: Int
    public var reason: String

    public init(_ code: Int, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let ok = HTTPStatus(200, "OK")
    public static let badRequest = HTTPStatus(400, "Bad Request")
    public static let notFound = HTTPStatus(404, "Not Found")
    public static let methodNotAllowed = HTTPStatus(405, "Method Not Allowed")
    public static let requestTimeout = HTTPStatus(408, "Request Timeout")
    public static let lengthRequired = HTTPStatus(411, "Length Required")
    public static let payloadTooLarge = HTTPStatus(413, "Content Too Large")
    public static let unsupportedMediaType = HTTPStatus(415, "Unsupported Media Type")
    public static let unprocessable = HTTPStatus(422, "Unprocessable Content")
    public static let headersTooLarge = HTTPStatus(431, "Request Header Fields Too Large")
    public static let internalServerError = HTTPStatus(500, "Internal Server Error")
    public static let notImplemented = HTTPStatus(501, "Not Implemented")
    public static let serviceUnavailable = HTTPStatus(503, "Service Unavailable")
    public static let gatewayTimeout = HTTPStatus(504, "Gateway Timeout")
}

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: HTTPHeaders

    public var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    public var expectsContinue: Bool {
        headers["Expect"]?.lowercased() == "100-continue"
    }
}

public struct HTTPRequest: Sendable {
    public var head: HTTPRequestHead
    public var body: Data

    public init(head: HTTPRequestHead, body: Data) {
        self.head = head
        self.body = body
    }

    public var method: String { head.method }
    public var path: String { head.path }
    public var headers: HTTPHeaders { head.headers }
}

public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: HTTPStatus, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: HTTPStatus = .ok) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: HTTPHeaders([("Content-Type", "application/json")]), body: body)
    }

    /// FastAPI's error shape, which docling-serve answers every HTTP-level
    /// failure with and which clients print verbatim.
    public static func detail(_ status: HTTPStatus, _ message: String) -> HTTPResponse {
        json(["detail": message], status: status)
    }

    /// Every response closes its connection. One request at a time is all a
    /// client of this server ever sends, and it keeps the connection state to
    /// "reading a request" or "done".
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
        var headers = self.headers
        headers.set("Content-Length", String(body.count))
        headers.set("Connection", "close")
        if headers["Server"] == nil {
            headers.set("Server", "LemmaryLocalAI")
        }
        for field in headers.fields {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static let continueInterim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
}
