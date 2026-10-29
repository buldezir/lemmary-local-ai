import Foundation

public enum HTTPHeadParse: Sendable, Equatable {
    case needMore
    /// `length` is the head's size including the blank line, i.e. where the body
    /// starts in the buffer.
    case head(HTTPRequestHead, length: Int, contentLength: Int)
    case invalid(HTTPStatus, String)
}

/// Request-head parsing for HTTP/1.1. Deliberately narrow: bodies must carry a
/// `Content-Length`, because every client this serves (Go's net/http with a
/// byte buffer, curl -F, Python requests) sends one, and refusing chunked bodies
/// keeps "is the request complete?" a comparison of two integers.
public enum HTTPParser {
    public static let maxHeadBytes = 64 * 1024
    private static let terminator = Data("\r\n\r\n".utf8)

    public static func parseHead(_ buffer: Data) -> HTTPHeadParse {
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeadBytes ? .invalid(.headersTooLarge, "request head too large") : .needMore
        }
        let headLength = end.upperBound - buffer.startIndex
        if headLength > maxHeadBytes {
            return .invalid(.headersTooLarge, "request head too large")
        }
        // Lenient decoding: a stray non-UTF-8 byte becomes U+FFFD instead of
        // failing the whole request.
        let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .invalid(.badRequest, "malformed request line")
        }

        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.first!.isWhitespace else {
                return .invalid(.badRequest, "malformed header line")
            }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.add(name, value)
        }

        if headers["Transfer-Encoding"] != nil {
            return .invalid(.lengthRequired, "chunked request bodies are not supported; send Content-Length")
        }
        let lengths = Set(headers.values("Content-Length"))
        guard lengths.count <= 1 else {
            return .invalid(.badRequest, "conflicting Content-Length headers")
        }
        var contentLength = 0
        if let raw = lengths.first {
            guard let n = Int(raw), n >= 0 else {
                return .invalid(.badRequest, "invalid Content-Length")
            }
            contentLength = n
        }

        let head = HTTPRequestHead(method: String(parts[0]), target: String(parts[1]),
                                   version: String(parts[2]), headers: headers)
        return .head(head, length: headLength, contentLength: contentLength)
    }
}
