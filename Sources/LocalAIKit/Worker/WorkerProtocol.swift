import Foundation

/// The contract between the app and `ocr-worker serve`, kept in one place so
/// the two sides cannot drift.
///
/// A worker is long-lived. It warms Vision up, announces `ready`, then reads
/// one `WorkerRequest` per line on stdin and answers with `progress` lines and
/// one `result` line per request on stdout. stderr is free-form log. It exits
/// when stdin closes.
///
/// Long-lived because Vision's models are unloaded as soon as no process holds
/// them: a fresh process per document paid 12 to 37 seconds of model loading
/// on nearly every upload, a live one pays it once.
public struct WorkerRequest: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var kind: MediaKind

    public init(id: String, path: String, kind: MediaKind) {
        self.id = id
        self.path = path
        self.kind = kind
    }
}

public struct WorkerResult: Codable, Sendable, Equatable {
    public var markdown: String?
    public var pages: Int
    /// A document-level failure (password-protected, unreadable): reported to
    /// the client as a failed conversion, not as a server error.
    public var error: String?

    public static func success(markdown: String, pages: Int) -> WorkerResult {
        WorkerResult(markdown: markdown, pages: pages, error: nil)
    }

    public static func failure(_ message: String) -> WorkerResult {
        WorkerResult(markdown: nil, pages: 0, error: message)
    }
}

public struct WorkerMessage: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable {
        /// Warm-up finished; `error` is set if it failed.
        case ready
        case progress
        case result
    }

    public var event: Event
    public var id: String?
    public var page: Int?
    public var total: Int?
    public var result: WorkerResult?
    public var error: String?

    public static func ready(error: String?) -> WorkerMessage {
        WorkerMessage(event: .ready, error: error)
    }

    public static func progress(id: String, page: Int, total: Int) -> WorkerMessage {
        WorkerMessage(event: .progress, id: id, page: page, total: total)
    }

    public static func result(id: String, _ result: WorkerResult) -> WorkerMessage {
        WorkerMessage(event: .result, id: id, result: result)
    }

    /// One line of JSON. JSON escapes newlines inside strings, so a line is
    /// always exactly one message.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

extension WorkerRequest {
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}
