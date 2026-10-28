import Foundation
import Testing
@testable import LocalAIKit

// MARK: - request head

@Test func parsesARequestHead() throws {
    let raw = Data("POST /v1/convert/file?x=1 HTTP/1.1\r\nHost: mac:5001\r\nContent-Length: 12\r\nContent-Type: multipart/form-data; boundary=abc\r\n\r\nbody".utf8)
    guard case .head(let head, let length, let contentLength) = HTTPParser.parseHead(raw) else {
        Issue.record("expected a head")
        return
    }
    #expect(head.method == "POST")
    #expect(head.path == "/v1/convert/file")
    #expect(head.headers["content-type"] == "multipart/form-data; boundary=abc")
    #expect(contentLength == 12)
    #expect(String(decoding: raw[length...], as: UTF8.self) == "body")
}

@Test func waitsForTheBlankLine() {
    #expect(HTTPParser.parseHead(Data("GET /health HTTP/1.1\r\nHost: x\r\n".utf8)) == .needMore)
}

@Test func refusesChunkedBodies() {
    let raw = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    guard case .invalid(let status, _) = HTTPParser.parseHead(raw) else {
        Issue.record("expected a refusal")
        return
    }
    #expect(status == .lengthRequired)
}

@Test func refusesConflictingLengths() {
    let raw = Data("POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n".utf8)
    guard case .invalid(let status, _) = HTTPParser.parseHead(raw) else {
        Issue.record("expected a refusal")
        return
    }
    #expect(status == .badRequest)
}

@Test func refusesAnOversizedHead() {
    let raw = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeadBytes + 1)).utf8)
    guard case .invalid(let status, _) = HTTPParser.parseHead(raw) else {
        Issue.record("expected a refusal")
        return
    }
    #expect(status == .headersTooLarge)
}

@Test func serializesWithLengthAndClose() {
    let text = String(decoding: HTTPResponse.json(["status": "ok"]).serialized(), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(text.contains("Content-Length: 15\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"status\":\"ok\"}"))
}

// MARK: - header values

@Test func headerParametersHandleQuotesAndSemicolons() {
    let value = HeaderValue.parse(#"form-data; name="files"; filename="a;b \"c\".pdf""#)
    #expect(value.value == "form-data")
    #expect(value.parameters["name"] == "files")
    #expect(value.parameters["filename"] == #"a;b "c".pdf"#)
}

// MARK: - multipart

/// The exact shape Lemmary's DoclingProvider sends: fields first, then the
/// file with its type set by hand (Go's CreatePart, not CreateFormFile).
func lemmaryBody(boundary: String, file: Data, type: String = "application/pdf") -> Data {
    var body = Data()
    for (name, value) in [("to_formats", "md"), ("do_ocr", "true"), ("image_export_mode", "placeholder")] {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"lemmary-doc-1.pdf\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
    body.append(file)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

@Test func parsesLemmarysRequest() throws {
    let pdf = Data("%PDF-1.7\r\n\r\n--not-a-boundary\r\nbinary".utf8)
    let parts = try Multipart.parse(lemmaryBody(boundary: "XyZ", file: pdf), boundary: "XyZ")
    #expect(parts.map(\.name) == ["to_formats", "do_ocr", "image_export_mode", "files"])
    #expect(parts[0].text == "md")
    #expect(parts[3].filename == "lemmary-doc-1.pdf")
    #expect(parts[3].contentType == "application/pdf")
    #expect(parts[3].body == pdf)
}

@Test func boundaryComesFromTheContentType() throws {
    #expect(try Multipart.boundary(contentType: "multipart/form-data; boundary=\"q w\"") == "q w")
    #expect(throws: MultipartError.notMultipart) { try Multipart.boundary(contentType: "application/json") }
    #expect(throws: MultipartError.missingBoundary) { try Multipart.boundary(contentType: "multipart/form-data") }
}

@Test func anUnterminatedBodyIsMalformed() {
    let body = Data("--b\r\nContent-Disposition: form-data; name=\"files\"\r\n\r\nabc".utf8)
    #expect(throws: MultipartError.self) { try Multipart.parse(body, boundary: "b") }
}

// MARK: - media type

@Test func declaredTypeWinsOverTheName() {
    // Lemmary names uploads itself; the declared type is the truth.
    let media = MediaType.resolve(declared: "image/png", filename: "lemmary-doc-1.pdf", data: Data())
    #expect(media.kind == .image)
}

@Test func octetStreamFallsThroughToExtensionThenBytes() {
    #expect(MediaType.resolve(declared: "application/octet-stream", filename: "scan.JPG", data: Data()).mimeType == "image/jpeg")
    #expect(MediaType.resolve(declared: nil, filename: "upload", data: Data("%PDF-1.4".utf8)).kind == .pdf)
    #expect(MediaType.resolve(declared: nil, filename: nil, data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])).mimeType == "image/png")
}

@Test func officeFormatsWithoutAReaderAreUnsupported() {
    let pptx = MediaType.resolve(declared: "application/vnd.openxmlformats-officedocument.presentationml.presentation", filename: "a.pptx", data: Data())
    #expect(pptx.kind == nil)
    #expect(MediaType.resolve(declared: "text/csv; charset=utf-8", filename: nil, data: Data()).kind == .text)
}
