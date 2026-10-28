import Foundation

public struct MultipartPart: Sendable {
    public var headers: HTTPHeaders
    public var body: Data

    public var name: String? { disposition?.parameters["name"] }
    public var filename: String? { disposition?.parameters["filename"] }
    public var contentType: String? { headers["Content-Type"] }

    public var text: String { String(decoding: body, as: UTF8.self) }

    private var disposition: HeaderValue? {
        headers["Content-Disposition"].map(HeaderValue.parse)
    }
}

public enum MultipartError: Error, Equatable, CustomStringConvertible {
    case notMultipart
    case missingBoundary
    case malformed(String)

    public var description: String {
        switch self {
        case .notMultipart: "expected a multipart/form-data body"
        case .missingBoundary: "multipart Content-Type has no boundary"
        case .malformed(let why): "malformed multipart body: \(why)"
        }
    }
}

/// `multipart/form-data` (RFC 7578) over a body that is already fully in memory.
public enum Multipart {
    public static func boundary(contentType: String?) throws -> String {
        guard let contentType else { throw MultipartError.notMultipart }
        let parsed = HeaderValue.parse(contentType)
        guard parsed.value.lowercased() == "multipart/form-data" else { throw MultipartError.notMultipart }
        guard let boundary = parsed.parameters["boundary"], !boundary.isEmpty else {
            throw MultipartError.missingBoundary
        }
        return boundary
    }

    public static func parse(_ body: Data, boundary: String) throws -> [MultipartPart] {
        let delimiter = Data("--\(boundary)".utf8)
        // Every delimiter after the first sits on its own line, so the CRLF
        // before it belongs to the delimiter and not to the part's content.
        let separator = Data("\r\n--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let blankLine = Data("\r\n\r\n".utf8)

        guard let first = body.range(of: delimiter) else {
            throw MultipartError.malformed("no opening boundary")
        }
        var cursor = first.upperBound
        var parts: [MultipartPart] = []

        while true {
            if body[cursor...].starts(with: Data("--".utf8)) {
                return parts
            }
            guard body[cursor...].starts(with: crlf) else {
                throw MultipartError.malformed("boundary not followed by a line break")
            }
            let partStart = cursor + crlf.count
            guard let next = body.range(of: separator, in: partStart..<body.endIndex) else {
                throw MultipartError.malformed("no closing boundary")
            }
            parts.append(try part(body[partStart..<next.lowerBound], blankLine: blankLine))
            cursor = next.upperBound
        }
    }

    private static func part(_ raw: Data, blankLine: Data) throws -> MultipartPart {
        // A part with no headers at all starts directly with the blank line.
        if raw.starts(with: Data("\r\n".utf8)) {
            return MultipartPart(headers: HTTPHeaders(), body: Data(raw.dropFirst(2)))
        }
        guard let split = raw.range(of: blankLine) else {
            throw MultipartError.malformed("part has no header terminator")
        }
        let headText = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self)
        var headers = HTTPHeaders()
        for line in headText.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw MultipartError.malformed("part header without a colon")
            }
            headers.add(String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return MultipartPart(headers: headers, body: Data(raw[split.upperBound...]))
    }
}
