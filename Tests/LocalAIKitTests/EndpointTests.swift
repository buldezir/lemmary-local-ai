import Foundation
import Testing
@testable import LocalAIKit

private struct FakeConverter: DocumentConverting {
    var outcome: @Sendable (URL, MediaKind) throws -> ConversionOutcome

    func convert(file: URL, kind: MediaKind) async throws -> ConversionOutcome {
        try outcome(file, kind)
    }
}

private func endpoint(ready: Bool = true, _ outcome: @escaping @Sendable (URL, MediaKind) throws -> ConversionOutcome) -> DoclingEndpoint {
    DoclingEndpoint(
        converter: FakeConverter(outcome: outcome),
        isReady: { ready },
        uploadDirectory: FileManager.default.temporaryDirectory.appending(path: "endpoint-tests"),
        version: "test"
    )
}

private func convertRequest(file: Data, type: String = "application/pdf", boundary: String = "B0undary") -> HTTPRequest {
    HTTPRequest(
        head: HTTPRequestHead(method: "POST", target: "/v1/convert/file", version: "HTTP/1.1",
                              headers: HTTPHeaders([("Content-Type", "multipart/form-data; boundary=\(boundary)")])),
        body: lemmaryBody(boundary: boundary, file: file, type: type)
    )
}

private func decode(_ response: HTTPResponse) throws -> ConvertDocumentResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ConvertDocumentResponse.self, from: response.body)
}

@Test func convertAnswersInDoclingsShape() async throws {
    let response = await endpoint { file, kind in
        #expect(kind == .pdf)
        let staged = try Data(contentsOf: file)
        #expect(staged == Data("%PDF-1.7 test".utf8))
        return .converted(markdown: "## Rechnung", pages: 2)
    }.handle(convertRequest(file: Data("%PDF-1.7 test".utf8)))

    #expect(response.status == .ok)
    let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let document = try #require(json["document"] as? [String: Any])
    // The two keys Lemmary's Go client reads, spelled as it reads them.
    #expect(document["md_content"] as? String == "## Rechnung")
    #expect(json["status"] as? String == "success")
    #expect(document["filename"] as? String == "lemmary-doc-1.pdf")
}

@Test func theUploadIsRemovedAfterwards() async throws {
    let seen = Seen()
    _ = await endpoint { file, _ in
        seen.url = file
        return .converted(markdown: "x", pages: 1)
    }.handle(convertRequest(file: Data("%PDF".utf8)))
    let file = try #require(seen.url)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func aDocumentFailureIs200WithErrors() async throws {
    // Lemmary reads errors[] when md_content is empty, so the reason reaches
    // the user instead of "returned empty text".
    let response = await endpoint { _, _ in .failed("the PDF is password-protected") }
        .handle(convertRequest(file: Data("%PDF".utf8)))
    #expect(response.status == .ok)
    let decoded = try decode(response)
    #expect(decoded.status == "failure")
    #expect(decoded.document.mdContent == "")
    #expect(decoded.errors.map(\.errorMessage) == ["the PDF is password-protected"])
}

@Test func aStalledWorkerIsAGatewayTimeout() async {
    let response = await endpoint { _, _ in throw WorkerFailure.stalled(seconds: 60, lastProgress: nil) }
        .handle(convertRequest(file: Data("%PDF".utf8)))
    #expect(response.status == .gatewayTimeout)
}

@Test func unsupportedFormatsAreRefusedBeforeConverting() async {
    let response = await endpoint { _, _ in
        Issue.record("must not convert")
        return .failed("")
    }.handle(convertRequest(file: Data(), type: "application/vnd.openxmlformats-officedocument.presentationml.presentation"))
    #expect(response.status == .unsupportedMediaType)
}

@Test func readyFollowsWarmUp() async {
    let get = HTTPRequest(head: HTTPRequestHead(method: "GET", target: "/ready", version: "HTTP/1.1", headers: HTTPHeaders()), body: Data())
    #expect(await endpoint(ready: false) { _, _ in .failed("") }.handle(get).status == .serviceUnavailable)
    #expect(await endpoint(ready: true) { _, _ in .failed("") }.handle(get).status == .ok)
}

@Test func unknownRoutesAndMethods() async {
    func request(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(head: HTTPRequestHead(method: method, target: path, version: "HTTP/1.1", headers: HTTPHeaders()), body: Data())
    }
    let e = endpoint { _, _ in .failed("") }
    #expect(await e.handle(request("GET", "/nope")).status == .notFound)
    #expect(await e.handle(request("GET", "/v1/convert/file")).status == .methodNotAllowed)
    #expect(await e.handle(request("POST", "/v1/convert/source")).status == .notImplemented)
}

/// The real server on a real socket, with curl as the client: the transport
/// curl -F uses (Expect: 100-continue on a large body) and the multipart it
/// builds, end to end.
@Test func serverAnswersCurl() async throws {
    let ready = PortBox()
    let server = HTTPServer(
        configuration: .init(port: 0, loopbackOnly: true),
        handler: { await endpoint { _, kind in .converted(markdown: "kind=\(kind.rawValue)", pages: 1) }.handle($0) },
        onStateChange: { if case .ready(let port) = $0 { ready.set(port) } }
    )
    try server.start()
    defer { server.stop() }
    let port = try await ready.wait()

    let upload = FileManager.default.temporaryDirectory.appending(path: "curl-\(UUID().uuidString).png")
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(Data(count: 2 << 20))
    try png.write(to: upload)
    defer { try? FileManager.default.removeItem(at: upload) }

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-s", "-F", "to_formats=md", "-F", "files=@\(upload.path);type=image/png", "http://127.0.0.1:\(port)/v1/convert/file"]
    let out = Pipe()
    curl.standardOutput = out
    try curl.run()
    let body = try out.fileHandleForReading.readToEnd() ?? Data()
    curl.waitUntilExit()

    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((json["document"] as? [String: Any])?["md_content"] as? String == "kind=image")
}

private final class Seen: @unchecked Sendable {
    var url: URL?
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?

    func set(_ value: UInt16) { lock.withLock { port = value } }

    func wait() async throws -> UInt16 {
        for _ in 0..<100 {
            if let port = lock.withLock({ port }) { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }
}
