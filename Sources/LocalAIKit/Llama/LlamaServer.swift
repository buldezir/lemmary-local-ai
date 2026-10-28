import CryptoKit
import Foundation

/// The `llama-server` command line for bge-m3 embeddings. The flag choices are
/// measured ones from Lemmary's `docs/local_ai_macos.md`; see there for numbers.
public struct EmbeddingsServerConfig: Sendable, Equatable {
    public var modelPath: String
    public var host: String
    public var port: Int
    /// Context, batch and micro-batch together. An encoder model must fit each
    /// input in one micro-batch: Lemmary's 8000-character cap is up to ~5.7k
    /// tokens of dense CJK, so anything under ~6144 fails long inputs instead of
    /// embedding them. 8192 is bge-m3's window.
    public var contextTokens: Int
    /// The model name clients send and see. Lemmary's Local Embeddings picker
    /// fills in exactly this.
    public var alias: String

    public init(modelPath: String, host: String, port: Int, contextTokens: Int = 8192, alias: String = ModelDescriptor.bgeM3.name) {
        self.modelPath = modelPath
        self.host = host
        self.port = port
        self.contextTokens = contextTokens
        self.alias = alias
    }

    public var arguments: [String] {
        let tokens = String(contextTokens)
        return [
            "-m", modelPath,
            "--alias", alias,
            "--embeddings",
            // bge-m3's dense vector is the CLS token; llama.cpp L2-normalises it,
            // as text-embeddings-inference does.
            "--pooling", "cls",
            "-ngl", "99",
            // Keeps the 8192-token attention matrix from being materialised, and
            // is faster on Metal besides.
            "-fa", "on",
            "-c", tokens,
            "-b", tokens,
            "-ub", tokens,
            // Four slots were only ~5% faster on a 64-chunk batch.
            "-np", "1",
            "--host", host,
            "--port", String(port),
            "--no-webui",
        ]
    }
}

/// The `llama-server` command line for the optional text model, which Lemmary
/// reaches through its OpenAI provider type for metadata extraction. A second
/// process rather than a second model in the embeddings one: a llama-server
/// holds one model, and `--embeddings` turns the chat endpoints off.
public struct TextServerConfig: Sendable, Equatable {
    public var modelPath: String
    public var alias: String
    public var host: String
    public var port: Int
    /// Lemmary sends at most 24,000 bytes of document text, about 7k tokens,
    /// plus a system prompt that grows with the archive's tags, correspondents
    /// and document types.
    public var contextTokens: Int

    public init(modelPath: String, alias: String, host: String, port: Int, contextTokens: Int = 16384) {
        self.modelPath = modelPath
        self.alias = alias
        self.host = host
        self.port = port
        self.contextTokens = contextTokens
    }

    public var arguments: [String] {
        [
            "-m", modelPath,
            "--alias", alias,
            "-ngl", "99",
            "-fa", "on",
            "-c", String(contextTokens),
            // One document at a time; others queue. Lemmary's worker sends one
            // at a time by default, and a second slot would only split the GPU.
            "-np", "1",
            "--jinja",
            // Both models think before answering unless the request says not to,
            // and Lemmary's does not. Thinking took Gemma 4 E4B from about 10 s
            // to 30-60 s a document, for the same JSON.
            "--chat-template-kwargs", #"{"enable_thinking":false}"#,
            // llama-server keeps earlier prompts in RAM for reuse, up to 8 GB by
            // default; it grew about 180 MB with every document. The slot still
            // reuses the system prompt the previous document left behind.
            "--cache-ram", "0",
            "--host", host,
            "--port", String(port),
            "--no-webui",
        ]
    }
}

public struct ModelDescriptor: Sendable, Equatable {
    /// The model name clients send and `/v1/models` lists.
    public var name: String
    /// What the app's own windows call it.
    public var title: String
    public var fileName: String
    public var url: URL
    public var sha256: String
    public var size: Int64

    /// F16 rather than Q8_0: the same speed on Metal and closer to the original
    /// weights. The hash is Hugging Face's own (`X-Linked-Etag`).
    public static let bgeM3 = ModelDescriptor(
        name: "BAAI/bge-m3",
        title: "bge-m3",
        fileName: "bge-m3-f16.gguf",
        url: URL(string: "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-FP16.gguf")!,
        sha256: "daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c",
        size: 1_157_671_200
    )

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The text models on offer, both 4-bit (Q4_K_M), both tried on Lemmary's own
/// extraction prompt in German and Russian on a 16 GB Mac mini M4 beside the
/// embeddings and OCR. The URLs are pinned to a repository commit, so a
/// re-upload cannot turn every download into a checksum failure.
public enum TextModel: String, CaseIterable, Sendable {
    /// 9 to 25 s a document and 5.4 GB. Every summary in the document's own
    /// language and only listed tags, but bare titles on invoices.
    case gemma4E4B = "gemma-4-e4b"
    /// 10 to 45 s a document and 6.3 GB. The most useful titles and summaries,
    /// but it sometimes leaves out `suggested_tags` and `references`, and once
    /// wrote a document type half in Cyrillic ("Дokumentation").
    case ornith9B = "ornith-1.5-9b"

    public var descriptor: ModelDescriptor {
        switch self {
        case .gemma4E4B:
            ModelDescriptor(
                name: rawValue,
                title: "Gemma 4 E4B",
                fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf")!,
                sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
                size: 4_977_171_584
            )
        case .ornith9B:
            ModelDescriptor(
                name: rawValue,
                title: "Ornith 1.5 9B",
                fileName: "Ornith-1.5-9B-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/abdd624b12ebf020b767fff532ff44fe552b28c3/Ornith-1.5-9B-Q4_K_M.gguf")!,
                sha256: "70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6",
                size: 5_780_090_816
            )
        }
    }
}

/// Restart pacing for a supervised process: 1s, 2s, 4s… up to a minute, and
/// back to the start once a run has lasted long enough to count as healthy.
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    public private(set) var attempt = 0

    public init(base: TimeInterval = 1, maximum: TimeInterval = 60) {
        self.base = base
        self.maximum = maximum
    }

    public mutating func next() -> TimeInterval {
        defer { attempt += 1 }
        return min(maximum, base * pow(2, Double(min(attempt, 16))))
    }

    public mutating func reset() {
        attempt = 0
    }
}
