import Foundation

/// The parts of OpenAI's API shapes this server writes itself. Property names
/// are camelCase here and snake_case on the wire (`HTTPResponse.json`).
struct ChatCompletion: Encodable {
    struct Choice: Encodable {
        var index = 0
        var message: Message
        var finishReason = "stop"
    }

    struct Message: Encodable {
        var role = "assistant"
        var content: String
    }

    /// Vision counts no tokens; zeros keep clients that read the field happy.
    struct Usage: Encodable {
        var promptTokens = 0
        var completionTokens = 0
        var totalTokens = 0
    }

    var id = "chatcmpl-\(UUID().uuidString.lowercased())"
    var object = "chat.completion"
    var created = Int(Date().timeIntervalSince1970)
    var model: String
    var choices: [Choice]
    var usage = Usage()

    init(model: String, content: String) {
        self.model = model
        choices = [Choice(message: Message(content: content))]
    }
}

/// What a model is for, in Lemmary's own words (`aiprovider.ModelPurpose`):
/// the job its pickers offer it for.
public enum ModelPurpose: String, Encodable, Sendable {
    case llm
    case ocr
    case embedding
}

struct ModelList: Encodable {
    /// OpenAI's model object, with what each model is for beside it.
    struct Entry: Encodable {
        /// Mistral's capabilities object, which Lemmary already reads (for
        /// Mistral's models only, today), with an `embeddings` flag beside its
        /// two. `completionChat` is false for the OCR model: it answers on the
        /// chat endpoint but holds no conversation.
        struct Capabilities: Encodable {
            var completionChat: Bool
            var ocr: Bool
            var embeddings: Bool
        }

        var id: String
        var object = "model"
        var created = 0
        var ownedBy = "lemmary-local-ai"
        /// Lemmary shows `id (name)` in its pickers, and without reading
        /// `purposes` offers a model for embeddings only when one of the two
        /// contains "embed".
        var name: String
        var purposes: [ModelPurpose]
        var capabilities: Capabilities
        /// The context the server runs the model with, in tokens. Lemmary reads
        /// it from any provider.
        var contextLength: Int?

        init(id: String, name: String, purpose: ModelPurpose, contextLength: Int?) {
            self.id = id
            self.name = name
            purposes = [purpose]
            capabilities = Capabilities(completionChat: purpose == .llm, ocr: purpose == .ocr, embeddings: purpose == .embedding)
            self.contextLength = contextLength
        }
    }

    var object = "list"
    var data: [Entry]
}

struct OpenAIErrorBody: Encodable {
    struct Detail: Encodable {
        var message: String
        var type: String
    }

    var error: Detail
}

extension HTTPResponse {
    /// OpenAI's error shape: the openai-go client Lemmary uses reports
    /// `error.message` as the reason.
    public static func openAIError(_ status: HTTPStatus, _ message: String, type: String = "invalid_request_error") -> HTTPResponse {
        json(OpenAIErrorBody(error: .init(message: message, type: type)), status: status)
    }
}
