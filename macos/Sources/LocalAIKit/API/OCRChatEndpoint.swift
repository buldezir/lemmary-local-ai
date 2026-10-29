import Foundation

/// The OCR models as OpenAI chat models, the way Lemmary's `openai` provider
/// type reads a document: a chat completion whose user message carries the
/// document as a data URL, an `image_url` part for an image or a `file` part
/// for a PDF, answered with its text as the assistant's message. The prompt is
/// not read; either model reads the page whatever it is asked.
public struct OCRChatEndpoint: Sendable {
    let conversion: UploadConversion

    public init(converter: any DocumentConverting, uploadDirectory: URL,
                onConversion: @escaping @Sendable (ConversionEvent) -> Void = { _ in }) {
        conversion = UploadConversion(converter: converter, uploadDirectory: uploadDirectory, onConversion: onConversion)
    }

    public func handle(_ request: HTTPRequest, model: OCRModel) async -> HTTPResponse {
        let attachments: [Attachment]
        do {
            attachments = try Attachment.all(inChatRequest: request.body)
        } catch {
            return .openAIError(.badRequest, "\(error)")
        }
        guard !attachments.isEmpty else {
            return .openAIError(.badRequest, "\(model.id) reads documents: send a PDF or an image as a content part of the user message")
        }

        var texts: [String] = []
        for attachment in attachments {
            switch await conversion.run(data: attachment.data, declaredType: attachment.mimeType, filename: attachment.filename,
                                        model: model) {
            case .converted(let markdown, _, _):
                texts.append(markdown)
            // 422, not 400: Lemmary takes a 400 that mentions a file as a model
            // refusing PDFs, and would render the pages and send them again.
            case .documentFailed(let reason, _):
                return .openAIError(.unprocessable, reason)
            case .unsupported(let mimeType):
                return .openAIError(.unsupportedMediaType, "\(model.id) reads \(model.readsDescription), not \(mimeType)")
            case .serverError(let status, let message):
                return .openAIError(status, message, type: "server_error")
            }
        }
        return .json(ChatCompletion(model: model.id, content: texts.joined(separator: "\n\n")))
    }
}

/// A document carried inside a chat request.
struct Attachment: Equatable {
    var mimeType: String
    var data: Data
    var filename: String?

    enum Problem: Error, CustomStringConvertible, Equatable {
        case notJSON
        case notADataURL
        case fileID

        var description: String {
            switch self {
            case .notJSON: "the request body is not a chat completion"
            case .notADataURL: "send the document inline as a base64 data: URL"
            case .fileID: "there is no Files API here; send the document inline as file_data"
            }
        }
    }

    /// Every image and file part of the request's messages, in order.
    static func all(inChatRequest body: Data) throws -> [Attachment] {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = request["messages"] as? [[String: Any]] else {
            throw Problem.notJSON
        }
        var found: [Attachment] = []
        for message in messages {
            guard let parts = message["content"] as? [[String: Any]] else { continue }
            for part in parts {
                switch part["type"] as? String {
                case "image_url":
                    guard let url = (part["image_url"] as? [String: Any])?["url"] as? String else { throw Problem.notADataURL }
                    let (mimeType, data) = try decodeDataURL(url)
                    found.append(Attachment(mimeType: mimeType, data: data, filename: nil))
                case "file":
                    let file = part["file"] as? [String: Any] ?? [:]
                    guard let fileData = file["file_data"] as? String else {
                        throw file["file_id"] != nil ? Problem.fileID : Problem.notADataURL
                    }
                    let (mimeType, data) = try decodeDataURL(fileData)
                    found.append(Attachment(mimeType: mimeType, data: data, filename: file["filename"] as? String))
                default:
                    continue
                }
            }
        }
        return found
    }

    /// `data:<type>[;params];base64,<data>`, the only form Lemmary sends.
    static func decodeDataURL(_ url: String) throws -> (mimeType: String, data: Data) {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { throw Problem.notADataURL }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
            .split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard header.last?.lowercased() == "base64",
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            throw Problem.notADataURL
        }
        return (header.first.flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream", data)
    }
}
