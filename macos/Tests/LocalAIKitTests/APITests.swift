import Foundation
import Testing
@testable import LocalAIKit

private struct FakeConverter: DocumentConverting {
    var outcome: @Sendable (URL, MediaKind) throws -> ConversionOutcome
    var models: ModelLog? = nil

    func convert(file: URL, kind: MediaKind, model: OCRModel?) async throws -> ConversionOutcome {
        models?.append(model)
        return try outcome(file, kind)
    }
}

private let uploads = FileManager.default.temporaryDirectory.appending(path: "api-tests")

private func ocr(_ outcome: @escaping @Sendable (URL, MediaKind) throws -> ConversionOutcome) -> OCRChatEndpoint {
    OCRChatEndpoint(converter: FakeConverter(outcome: outcome), uploadDirectory: uploads)
}

private func router(embeddingsPort: Int? = nil, text: APIRouter.TextUpstream? = nil,
                    _ outcome: @escaping @Sendable (URL, MediaKind) throws -> ConversionOutcome = { _, _ in .converted(markdown: "", pages: 1) }) -> APIRouter {
    APIRouter(
        docling: DoclingEndpoint(converter: FakeConverter(outcome: outcome), isReady: { true }, uploadDirectory: uploads, version: "test"),
        ocr: ocr(outcome),
        embeddingsModel: "BAAI/bge-m3",
        upstreams: { .init(embeddingsPort: embeddingsPort, embeddingsContext: 8192, text: text) }
    )
}

private func request(_ method: String, _ target: String, json: Any? = nil) -> HTTPRequest {
    let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    return HTTPRequest(head: HTTPRequestHead(method: method, target: target, version: "HTTP/1.1",
                                             headers: HTTPHeaders([("Content-Type", "application/json")])), body: body)
}

/// The request Lemmary's LLM OCR provider sends (internal/ocr/llm.go): a system
/// message, then the prompt and the document as one user message.
private func lemmaryOCRRequest(part: [String: Any]) -> [String: Any] {
    [
        "model": "apple-vision-ocr",
        "temperature": 0,
        "messages": [
            ["role": "system", "content": "You transcribe documents for an archive. Return only the extracted text."],
            ["role": "user", "content": [
                ["type": "text", "text": "Extract all text from this document."],
                part,
            ]],
        ],
    ]
}

private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private func errorMessage(_ response: HTTPResponse) throws -> String? {
    (try object(response)["error"] as? [String: Any])?["message"] as? String
}

// MARK: - attachments

@Test func dataURLsDecode() throws {
    let png = try Attachment.decodeDataURL("data:image/png;base64,iVBORw0KGgo=")
    #expect(png.mimeType == "image/png")
    #expect(png.data == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    #expect(try Attachment.decodeDataURL("data:application/pdf;name=a.pdf;base64,JVBERg==").mimeType == "application/pdf")
    #expect(try Attachment.decodeDataURL("data:;base64,JVBERg==").mimeType == "application/octet-stream")
    #expect(throws: Attachment.Problem.notADataURL) { try Attachment.decodeDataURL("https://example.com/a.png") }
    #expect(throws: Attachment.Problem.notADataURL) { try Attachment.decodeDataURL("data:text/plain,hello") }
}

@Test func attachmentsComeFromImageAndFileParts() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "messages": [
            ["role": "system", "content": "plain text is skipped"],
            ["role": "user", "content": [
                ["type": "text", "text": "read these"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,/9j/"]],
                ["type": "file", "file": ["filename": "scan.pdf", "file_data": "data:application/pdf;base64,JVBERg=="]],
            ]],
        ],
    ])
    let found = try Attachment.all(inChatRequest: body)
    #expect(found.map(\.mimeType) == ["image/jpeg", "application/pdf"])
    #expect(found.map(\.filename) == [nil, "scan.pdf"])
    #expect(found[1].data == Data("%PDF".utf8))
}

@Test func aFileIDIsRefused() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "messages": [["role": "user", "content": [["type": "file", "file": ["file_id": "file-123"]]]]],
    ])
    #expect(throws: Attachment.Problem.fileID) { try Attachment.all(inChatRequest: body) }
    #expect(throws: Attachment.Problem.notJSON) { try Attachment.all(inChatRequest: Data("nope".utf8)) }
}

// MARK: - OCR as a chat model

@Test func ocrAnswersAsAChatCompletion() async throws {
    let response = await ocr { file, kind in
        #expect(kind == .pdf)
        let staged = try Data(contentsOf: file)
        #expect(staged == Data("%PDF".utf8))
        return .converted(markdown: "## Rechnung", pages: 1)
    }.handle(request("POST", "/v1/chat/completions", json: lemmaryOCRRequest(part: [
        "type": "file", "file": ["filename": "doc.pdf", "file_data": "data:application/pdf;base64,JVBERg=="],
    ])), model: .appleVision)

    #expect(response.status == .ok)
    let json = try object(response)
    #expect(json["object"] as? String == "chat.completion")
    #expect(json["model"] as? String == "apple-vision-ocr")
    let choice = try #require((json["choices"] as? [[String: Any]])?.first)
    #expect(choice["finish_reason"] as? String == "stop")
    let message = try #require(choice["message"] as? [String: Any])
    #expect(message["role"] as? String == "assistant")
    #expect(message["content"] as? String == "## Rechnung")
}

@Test func aDocumentFailureIs422WithItsReason() async throws {
    let response = await ocr { _, _ in .failed("the PDF is password-protected") }
        .handle(request("POST", "/v1/chat/completions", json: lemmaryOCRRequest(part: [
            "type": "file", "file": ["file_data": "data:application/pdf;base64,JVBERg=="],
        ])), model: .appleVision)
    // Not 400: Lemmary would read a 400 that mentions a file as a model that
    // refuses PDFs, and send the pages again as images.
    #expect(response.status == .unprocessable)
    #expect(try errorMessage(response) == "the PDF is password-protected")
}

@Test func ocrWithoutADocumentIsABadRequest() async throws {
    let response = await ocr { _, _ in
        Issue.record("must not convert")
        return .failed("")
    }.handle(request("POST", "/v1/chat/completions", json: ["model": "apple-vision-ocr", "messages": [["role": "user", "content": "hi"]]]), model: .appleVision)
    #expect(response.status == .badRequest)
}

@Test func aStalledPageIsAGatewayTimeout() async throws {
    let response = await ocr { _, _ in throw WorkerFailure.stalled(seconds: 60, lastProgress: nil) }
        .handle(request("POST", "/v1/chat/completions", json: lemmaryOCRRequest(part: [
            "type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="],
        ])), model: .appleVision)
    #expect(response.status == .gatewayTimeout)
}

// MARK: - routing

@Test func modelsListsEveryModelForLemmarysPickers() async throws {
    let response = await router(text: .init(model: "gemma-4-e4b", title: "Gemma 4 E4B", port: nil, contextTokens: 16384))
        .handle(request("GET", "/v1/models"))
    let json = try object(response)
    #expect(json["object"] as? String == "list")
    let data = try #require(json["data"] as? [[String: Any]])
    // Both OCR models always, whichever is in memory.
    #expect(data.compactMap { $0["id"] as? String } == ["BAAI/bge-m3", "apple-vision-ocr", "indra-ocr", "gemma-4-e4b"])
    #expect(data.allSatisfy { $0["object"] as? String == "model" && $0["owned_by"] as? String == "lemmary-local-ai" })
    // Lemmary's embeddings picker, until it reads purposes, keeps a model whose
    // id or name says "embed".
    let embeddings = data.filter { ($0["name"] as? String ?? "").contains("embed") || ($0["id"] as? String ?? "").contains("embed") }
    #expect(embeddings.compactMap { $0["id"] as? String } == ["BAAI/bge-m3"])

    let withoutText = try object(await router().handle(request("GET", "/v1/models")))
    #expect((withoutText["data"] as? [[String: Any]])?.count == 3)
}

@Test func eachModelSaysWhatItIsFor() async throws {
    let r = router(text: .init(model: "gemma-4-26b-a4b", title: "Gemma 4 26B-A4B", port: nil, contextTokens: 32768))
    let data = try #require(try object(await r.handle(request("GET", "/v1/models")))["data"] as? [[String: Any]])
    let byID = Dictionary(uniqueKeysWithValues: data.map { ($0["id"] as? String ?? "", $0) })

    // Lemmary's purpose names, one per model.
    #expect(byID["BAAI/bge-m3"]?["purposes"] as? [String] == ["embedding"])
    #expect(byID["apple-vision-ocr"]?["purposes"] as? [String] == ["ocr"])
    #expect(byID["indra-ocr"]?["purposes"] as? [String] == ["ocr"])
    #expect(byID["gemma-4-26b-a4b"]?["purposes"] as? [String] == ["llm"])

    // Mistral's capabilities shape, which Lemmary already parses.
    func capabilities(_ id: String) -> [String: Bool]? { byID[id]?["capabilities"] as? [String: Bool] }
    #expect(capabilities("BAAI/bge-m3") == ["completion_chat": false, "ocr": false, "embeddings": true])
    #expect(capabilities("apple-vision-ocr") == ["completion_chat": false, "ocr": true, "embeddings": false])
    #expect(capabilities("indra-ocr") == ["completion_chat": false, "ocr": true, "embeddings": false])
    #expect(capabilities("gemma-4-26b-a4b") == ["completion_chat": true, "ocr": false, "embeddings": false])

    // The context each server runs with; Vision has none.
    #expect(byID["gemma-4-26b-a4b"]?["context_length"] as? Int == 32768)
    #expect(byID["BAAI/bge-m3"]?["context_length"] as? Int == 8192)
    #expect(byID["apple-vision-ocr"]?["context_length"] == nil)
}

@Test func oneModelCanBeLookedUp() async throws {
    let r = router(text: .init(model: "gemma-4-e4b", title: "Gemma 4 E4B", port: nil))
    // An id with a slash, as written and percent-encoded.
    for target in ["/v1/models/BAAI/bge-m3", "/v1/models/BAAI%2Fbge-m3", "/models/BAAI/bge-m3"] {
        let response = await r.handle(request("GET", target))
        #expect(response.status == .ok, "\(target)")
        #expect(try object(response)["id"] as? String == "BAAI/bge-m3")
    }
    #expect(try object(await r.handle(request("GET", "/v1/models/apple-vision-ocr")))["purposes"] as? [String] == ["ocr"])
    #expect(await r.handle(request("GET", "/v1/models/gpt-4o")).status == .notFound)
    #expect(await router().handle(request("GET", "/v1/models/gemma-4-e4b")).status == .notFound)
}

@Test func theOCRModelIsAnsweredHere() async throws {
    // No text model and no embeddings server: OCR must not need either.
    let response = await router { _, kind in .converted(markdown: "kind=\(kind.rawValue)", pages: 1) }
        .handle(request("POST", "/v1/chat/completions", json: lemmaryOCRRequest(part: [
            "type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="],
        ])))
    let choice = try #require((try object(response)["choices"] as? [[String: Any]])?.first)
    #expect((choice["message"] as? [String: Any])?["content"] as? String == "kind=image")
}

@Test func eachOCRModelIsAnsweredByName() async throws {
    let models = ModelLog()
    let r = APIRouter(
        docling: DoclingEndpoint(converter: FakeConverter(outcome: { _, _ in .converted(markdown: "", pages: 1) }), isReady: { true },
                                 uploadDirectory: uploads, version: "test"),
        ocr: OCRChatEndpoint(converter: FakeConverter(outcome: { _, _ in .converted(markdown: "text", pages: 1) }, models: models),
                             uploadDirectory: uploads),
        embeddingsModel: "BAAI/bge-m3",
        upstreams: { .init(embeddingsPort: nil, text: nil) }
    )
    for id in ["indra-ocr", "apple-vision-ocr"] {
        var body = lemmaryOCRRequest(part: ["type": "file", "file": ["file_data": "data:application/pdf;base64,JVBERi0xLjc="]])
        body["model"] = id
        let response = await r.handle(request("POST", "/v1/chat/completions", json: body))
        #expect(response.status == .ok)
        #expect(try object(response)["model"] as? String == id)
    }
    #expect(models.models == [.indra, .appleVision])
}

@Test func indraRefusesWhatItCannotRead() async throws {
    var body = lemmaryOCRRequest(part: ["type": "file", "file": [
        "file_data": "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,UEsDBA==",
    ]])
    body["model"] = "indra-ocr"
    let response = await router { _, _ in .converted(markdown: "should not run", pages: 1) }
        .handle(request("POST", "/v1/chat/completions", json: body))
    #expect(response.status == .unsupportedMediaType)
    #expect(try errorMessage(response)?.contains("indra-ocr reads PDFs and images") == true)
}

@Test func otherModelsNeedTheTextModel() async throws {
    let chat = request("POST", "/v1/chat/completions", json: ["model": "gemma-4-e4b", "messages": [["role": "user", "content": "hi"]]])
    let off = await router().handle(chat)
    #expect(off.status == .notFound)
    #expect(try errorMessage(off)?.contains("off in Settings") == true)

    let starting = await router(text: .init(model: "gemma-4-e4b", title: "Gemma 4 E4B", port: nil)).handle(chat)
    #expect(starting.status == .serviceUnavailable)

    #expect(await router().handle(request("POST", "/v1/embeddings", json: ["input": "x"])).status == .serviceUnavailable)
}

@Test func doclingStillAnswersOnTheSamePort() async throws {
    let ready = await router().handle(request("GET", "/ready"))
    #expect(ready.status == .ok)
    #expect(await router().handle(request("GET", "/nope")).status == .notFound)
    #expect(await router().handle(request("GET", "/v1/embeddings")).status == .methodNotAllowed)
}

/// A real llama-server stand-in on a real socket: the request arrives as sent,
/// path, query and body, and the answer comes back with its status.
@Test func embeddingsAndChatAreForwarded() async throws {
    let upstream = try await FakeUpstream.start()
    defer { upstream.server.stop() }
    let r = router(embeddingsPort: upstream.port, text: .init(model: "gemma-4-e4b", title: "Gemma 4 E4B", port: upstream.port))

    let embed = await r.handle(request("POST", "/embeddings?x=1", json: ["model": "BAAI/bge-m3", "input": ["Strom"]]))
    #expect(embed.status == .ok)
    #expect(embed.headers["Content-Type"] == "application/json")
    let echoed = try object(embed)
    #expect(echoed["path"] as? String == "/v1/embeddings?x=1")
    #expect((echoed["body"] as? [String: Any])?["model"] as? String == "BAAI/bge-m3")

    let chat = await r.handle(request("POST", "/v1/chat/completions", json: ["model": "whatever", "messages": []]))
    #expect(try object(chat)["path"] as? String == "/v1/chat/completions")

    let refused = await r.handle(request("POST", "/v1/chat/completions", json: ["model": "teapot", "messages": []]))
    #expect(refused.status.code == 418)
}

@Test func aServerThatIsNotListeningIsUnavailable() async throws {
    let upstream = try await FakeUpstream.start()
    let port = upstream.port
    upstream.server.stop()
    let response = await router(embeddingsPort: port).handle(request("POST", "/v1/embeddings", json: ["input": "x"]))
    #expect(response.status == .serviceUnavailable)
    #expect(try errorMessage(response) == "the embeddings model is not running")
}

/// The router on a real socket in front of a streaming stand-in for
/// llama-server, with URLSession as the client, the way an OpenAI SDK reads a
/// streamed completion.
private func streamingSetup(upstream handler: @escaping HTTPServer.Handler) async throws -> (front: HTTPServer, upstream: HTTPServer, port: UInt16) {
    let upstreamPort = PortBox()
    let upstream = HTTPServer(configuration: .init(port: 0, loopbackOnly: true), handler: handler,
                              onStateChange: { if case .ready(let port) = $0 { upstreamPort.set(port) } })
    try upstream.start()
    let r = router(text: .init(model: "gemma-4-e4b", title: "Gemma 4 E4B", port: Int(try await upstreamPort.wait())))
    let frontPort = PortBox()
    let front = HTTPServer(configuration: .init(port: 0, loopbackOnly: true), handler: { await r.handle($0) },
                           onStateChange: { if case .ready(let port) = $0 { frontPort.set(port) } })
    try front.start()
    return (front, upstream, try await frontPort.wait())
}

private func streamingRequest(port: UInt16) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": "gemma-4-e4b", "stream": true, "messages": [["role": "user", "content": "hi"]],
    ])
    return request
}

private let eventStream = HTTPHeaders([("Content-Type", "text/event-stream")])

@Test func streamedCompletionsArriveAsTheyAreMade() async throws {
    let secondSent = Flag()
    let (front, upstream, port) = try await streamingSetup { _ in
        let (events, out) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            out.yield(Data("data: {\"n\":1}\n\n".utf8))
            try? await Task.sleep(for: .seconds(1))
            secondSent.set()
            out.yield(Data("data: {\"n\":2}\n\n".utf8))
            out.yield(Data("data: [DONE]\n\n".utf8))
            out.finish()
        }
        return .streaming(headers: eventStream, events)
    }
    defer { front.stop(); upstream.stop() }

    let (bytes, response) = try await URLSession.shared.bytes(for: try streamingRequest(port: port))
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
    var lines: [String] = []
    var secondSentBeforeFirstArrived: Bool?
    for try await line in bytes.lines where !line.isEmpty {
        if lines.isEmpty {
            secondSentBeforeFirstArrived = secondSent.value
        }
        lines.append(line)
    }
    #expect(lines == [#"data: {"n":1}"#, #"data: {"n":2}"#, "data: [DONE]"])
    // Buffered, the first event would only have come with the last.
    #expect(secondSentBeforeFirstArrived == false)
}

@Test func aClientThatHangsUpStopsTheUpstream() async throws {
    let stopped = Flag()
    let (front, upstream, port) = try await streamingSetup { _ in
        let (events, out) = AsyncThrowingStream<Data, Error>.makeStream()
        out.onTermination = { _ in stopped.set() }
        Task {
            while case .enqueued = out.yield(Data("data: {\"token\":\"x\"}\n\n".utf8)) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return .streaming(headers: eventStream, events)
    }
    defer { front.stop(); upstream.stop() }

    let firstEvent = Flag()
    let reader = Task {
        let (bytes, _) = try await URLSession.shared.bytes(for: try streamingRequest(port: port))
        for try await line in bytes.lines where !line.isEmpty {
            firstEvent.set()
        }
    }
    #expect(await firstEvent.wait(seconds: 3))
    reader.cancel()
    // The front notices on its next write, cancels its request upstream, and
    // the upstream's connection notices on its next write in turn.
    #expect(await stopped.wait(seconds: 5))
}

/// Echoes the request's target and JSON body; answers 418 for model "teapot".
private struct FakeUpstream {
    let server: HTTPServer
    let port: Int

    static func start() async throws -> FakeUpstream {
        let box = PortBox()
        let server = HTTPServer(
            configuration: .init(port: 0, loopbackOnly: true),
            handler: { request in
                let body = (try? JSONSerialization.jsonObject(with: request.body)) ?? [:]
                let status: HTTPStatus = ((body as? [String: Any])?["model"] as? String) == "teapot" ? HTTPStatus(418, "I'm a teapot") : .ok
                let echo = try! JSONSerialization.data(withJSONObject: ["path": request.head.target, "body": body])
                return HTTPResponse(status: status, headers: HTTPHeaders([("Content-Type", "application/json")]), body: echo)
            },
            onStateChange: { if case .ready(let port) = $0 { box.set(port) } }
        )
        try server.start()
        return FakeUpstream(server: server, port: Int(try await box.wait()))
    }
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }

    func wait(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if value { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return value
    }
}
