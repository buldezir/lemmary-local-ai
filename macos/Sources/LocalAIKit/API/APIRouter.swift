import Foundation

/// Everything on one port, so Lemmary reaches all three services through a
/// single `openai` provider: embeddings and the text model forwarded to their
/// llama-servers on loopback, OCR answered here, both as a chat model and as
/// docling-serve's convert endpoint for Lemmary's `docling` provider type.
public struct APIRouter: Sendable {
    /// What is running now, read at every request: either llama-server may be
    /// restarting on a new port, and the text model may be off.
    public struct Upstreams: Sendable {
        public var embeddingsPort: Int?
        /// The embeddings server's context in tokens, for `/v1/models`.
        public var embeddingsContext: Int?
        public var text: TextUpstream?

        public init(embeddingsPort: Int?, embeddingsContext: Int? = nil, text: TextUpstream?) {
            self.embeddingsPort = embeddingsPort
            self.embeddingsContext = embeddingsContext
            self.text = text
        }
    }

    public struct TextUpstream: Sendable {
        public var model: String
        public var title: String
        public var port: Int?
        public var contextTokens: Int?

        public init(model: String, title: String, port: Int?, contextTokens: Int? = nil) {
            self.model = model
            self.title = title
            self.port = port
            self.contextTokens = contextTokens
        }
    }

    public var docling: DoclingEndpoint
    public var ocr: OCRChatEndpoint
    public var embeddingsModel: String
    public var upstreams: @Sendable () async -> Upstreams
    public var proxy: UpstreamProxy

    public init(docling: DoclingEndpoint, ocr: OCRChatEndpoint, embeddingsModel: String,
                upstreams: @escaping @Sendable () async -> Upstreams, proxy: UpstreamProxy = UpstreamProxy()) {
        self.docling = docling
        self.ocr = ocr
        self.embeddingsModel = embeddingsModel
        self.upstreams = upstreams
        self.proxy = proxy
    }

    /// llama-server answers both with and without `/v1`, and so does this.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            return .json(ModelList(data: await models()))
        case ("GET", let path) where path.hasPrefix("/v1/models/") || path.hasPrefix("/models/"):
            let prefix = path.hasPrefix("/v1/") ? "/v1/models/" : "/models/"
            return await model(id: String(path.dropFirst(prefix.count)))
        case ("POST", "/v1/embeddings"), ("POST", "/embeddings"):
            guard let port = await upstreams().embeddingsPort else {
                return .openAIError(.serviceUnavailable, "the embeddings model is not running", type: "server_error")
            }
            return await proxy.forward(request, path: "/v1/embeddings", port: port, service: "the embeddings model")
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            return await chat(request)
        case (_, "/v1/models"), (_, "/models"), (_, "/v1/embeddings"), (_, "/embeddings"),
             (_, "/v1/chat/completions"), (_, "/chat/completions"):
            return .openAIError(.methodNotAllowed, "\(request.method) is not allowed on \(request.path)")
        default:
            return await docling.handle(request)
        }
    }

    /// By model: the OCR model reads the attached document, any other name goes
    /// to the text model, whichever one Settings has chosen.
    private func chat(_ request: HTTPRequest) async -> HTTPResponse {
        let model = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["model"] as? String
        if model == OCRChatEndpoint.model {
            return await ocr.handle(request)
        }
        guard let text = await upstreams().text else {
            return .openAIError(.notFound, "\(model ?? "this model") is not served: the text model is off in Settings")
        }
        guard let port = text.port else {
            return .openAIError(.serviceUnavailable, "the text model is not running", type: "server_error")
        }
        return await proxy.forward(request, path: "/v1/chat/completions", port: port, service: "the text model")
    }

    /// Every model served, each with what it is for, so a client can fill a
    /// picker per job instead of guessing from names.
    private func models() async -> [ModelList.Entry] {
        let now = await upstreams()
        var data = [
            ModelList.Entry(id: embeddingsModel, name: "\(embeddingsModel) embeddings", purpose: .embedding,
                            contextLength: now.embeddingsContext),
            ModelList.Entry(id: OCRChatEndpoint.model, name: "Apple Vision OCR", purpose: .ocr, contextLength: nil),
        ]
        if let text = now.text {
            data.append(ModelList.Entry(id: text.model, name: text.title, purpose: .llm, contextLength: text.contextTokens))
        }
        return data
    }

    /// OpenAI's `GET /v1/models/{model}`. An id may contain a slash
    /// (`BAAI/bge-m3`), so everything after `models/` is the id.
    private func model(id: String) async -> HTTPResponse {
        let id = id.removingPercentEncoding ?? id
        guard let entry = await models().first(where: { $0.id == id }) else {
            return .openAIError(.notFound, "The model '\(id)' does not exist")
        }
        return .json(entry)
    }
}
