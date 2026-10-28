import Foundation

public protocol DocumentConverting: Sendable {
    func convert(file: URL, kind: MediaKind) async throws -> ConversionOutcome
}

public enum ConversionOutcome: Sendable, Equatable {
    case converted(markdown: String, pages: Int)
    /// The document itself could not be read. docling answers this with 200 and
    /// an `errors` array, and Lemmary turns that array into the error it shows.
    case failed(String)
}

/// docling-serve's `ConvertDocumentResponse`, the fields of it a client reads.
/// Encoded with snake_case keys.
public struct ConvertDocumentResponse: Codable, Sendable, Equatable {
    public struct Document: Codable, Sendable, Equatable {
        public var filename: String
        public var mdContent: String
    }

    public struct ErrorItem: Codable, Sendable, Equatable {
        public var componentType: String
        public var moduleName: String
        public var errorMessage: String
    }

    public var document: Document
    public var status: String
    public var errors: [ErrorItem]
    public var processingTime: Double
}

public struct ConversionEvent: Sendable {
    public var filename: String
    public var mimeType: String
    public var bytes: Int
    public var pages: Int?
    public var duration: TimeInterval
    /// nil on success; otherwise what went wrong, as the client was told.
    public var failure: String?
}

/// The subset of docling-serve's HTTP API that Lemmary's `docling` OCR SDK
/// uses: `POST /v1/convert/file`, plus `/health`, `/ready` and `/version`.
public struct DoclingEndpoint: Sendable {
    public var converter: any DocumentConverting
    public var isReady: @Sendable () async -> Bool
    public var uploadDirectory: URL
    public var version: String
    public var onConversion: @Sendable (ConversionEvent) -> Void

    public init(converter: any DocumentConverting, isReady: @escaping @Sendable () async -> Bool, uploadDirectory: URL,
                version: String, onConversion: @escaping @Sendable (ConversionEvent) -> Void = { _ in }) {
        self.converter = converter
        self.isReady = isReady
        self.uploadDirectory = uploadDirectory
        self.version = version
        self.onConversion = onConversion
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(["status": "ok"])
        case ("GET", "/ready"):
            return await isReady() ? .json(["status": "ok"]) : .json(["status": "starting"], status: .serviceUnavailable)
        case ("GET", "/version"):
            return .json(["lemmary-local-ai": version, "ocr-engine": "apple-vision"])
        case ("POST", "/v1/convert/file"):
            return await convert(request)
        case ("POST", "/v1/convert/source"), ("POST", "/v1/convert/file/async"), ("POST", "/v1/convert/source/async"):
            return .detail(.notImplemented, "only POST /v1/convert/file is implemented")
        case (_, "/health"), (_, "/ready"), (_, "/version"), (_, "/v1/convert/file"):
            return .detail(.methodNotAllowed, "Method Not Allowed")
        default:
            return .detail(.notFound, "Not Found")
        }
    }

    private func convert(_ request: HTTPRequest) async -> HTTPResponse {
        let parts: [MultipartPart]
        do {
            let boundary = try Multipart.boundary(contentType: request.headers["Content-Type"])
            parts = try Multipart.parse(request.body, boundary: boundary)
        } catch {
            return .detail(.badRequest, "\(error)")
        }

        let form = ConvertForm(parts)
        guard form.files.count == 1, let file = form.files.first else {
            return .detail(.unprocessable, "send exactly one file in the `files` field (got \(form.files.count))")
        }
        if !form.toFormats.isEmpty && !form.toFormats.contains("md") {
            return .detail(.unprocessable, "only to_formats=md is supported")
        }

        let filename = file.filename ?? "document"
        let media = MediaType.resolve(declared: file.contentType, filename: file.filename, data: file.body)
        guard let kind = media.kind else {
            return .detail(.unsupportedMediaType, "unsupported format \(media.mimeType)")
        }

        let input = uploadDirectory.appending(path: "\(UUID().uuidString).\(MediaType.fileExtension(forMIME: media.mimeType))")
        do {
            try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
            try file.body.write(to: input)
        } catch {
            return .detail(.internalServerError, "could not stage the upload: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: input) }

        let started = ContinuousClock.now
        func event(pages: Int?, failure: String?) -> ConversionEvent {
            ConversionEvent(filename: filename, mimeType: media.mimeType, bytes: file.body.count, pages: pages,
                            duration: (ContinuousClock.now - started).seconds, failure: failure)
        }

        do {
            switch try await converter.convert(file: input, kind: kind) {
            case .converted(let markdown, let pages):
                let done = event(pages: pages, failure: nil)
                onConversion(done)
                return .json(ConvertDocumentResponse(
                    document: .init(filename: filename, mdContent: markdown),
                    status: "success", errors: [], processingTime: done.duration))
            case .failed(let reason):
                let done = event(pages: nil, failure: reason)
                onConversion(done)
                return .json(ConvertDocumentResponse(
                    document: .init(filename: filename, mdContent: ""),
                    status: "failure",
                    errors: [.init(componentType: "document_backend", moduleName: "apple-vision", errorMessage: reason)],
                    processingTime: done.duration))
            }
        } catch let failure as WorkerFailure {
            onConversion(event(pages: nil, failure: failure.description))
            switch failure {
            case .stalled, .timedOut:
                return .detail(.gatewayTimeout, failure.description)
            case .launch, .crashed:
                return .detail(.internalServerError, failure.description)
            }
        } catch {
            onConversion(event(pages: nil, failure: "\(error)"))
            return .detail(.internalServerError, "\(error)")
        }
    }
}

/// The form fields of a convert request. docling takes the file as `files`
/// (repeatable) and options as plain fields, some of them repeatable.
struct ConvertForm {
    var files: [MultipartPart] = []
    var fields: [String: [String]] = [:]

    init(_ parts: [MultipartPart]) {
        for part in parts {
            guard let name = part.name else { continue }
            if name == "files" || name == "file" {
                files.append(part)
            } else {
                fields[name, default: []].append(part.text)
            }
        }
    }

    var toFormats: [String] {
        (fields["to_formats"] ?? [])
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (s, attoseconds) = components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }
}
