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

/// The text models on offer, all 4-bit, all tried on Lemmary's own extraction
/// prompt in German and Russian beside the embeddings and OCR: the first two on
/// a 16 GB Mac mini M4, all five on a 32 GB Mac mini M6. Times and memory below
/// are the M6's. The URLs are pinned to a repository commit, so a re-upload
/// cannot turn every download into a checksum failure.
public enum TextModel: String, CaseIterable, Sendable {
    /// 7 to 18 s a document and 5.7 GB. Every field Lemmary asks for, but now
    /// and then a Russian document's summary in German.
    case gemma4E4B = "gemma-4-e4b"
    /// 8 to 32 s a document and 6.9 GB. The most useful titles and summaries of
    /// the small two, but it sometimes leaves out `suggested_tags` and
    /// `references`, and once wrote a document type half in Cyrillic
    /// ("Дokumentation"). Under load a long document ran past Lemmary's 90 s.
    case ornith9B = "ornith-1.5-9b"
    /// 13 to 49 s a document and 9.3 GB. Every summary in the document's own
    /// language, but dense and slow: 86 s on a long document under load.
    case gemma4_12B = "gemma-4-12b"
    /// 5 to 19 s a document and 16.2 GB, a mixture of experts with about 4B
    /// active. The fastest tried and the only one with no account or customer
    /// numbers among its references.
    case gemma4_26B = "gemma-4-26b-a4b"
    /// 6 to 22 s a document and up to 18.7 GB, a mixture of experts with 3B
    /// active. The most detailed summaries and the best match to existing
    /// correspondents, but it often lists account and customer numbers as
    /// references.
    case qwen36_35B = "qwen3.6-35b-a3b"

    /// The memory, in GB, a Mac needs before Settings offers the model: what the
    /// model took, plus the embeddings and OCR (about 2.3 GB) and macOS (about
    /// 5 GB). The small two are offered on every Mac.
    public var minimumMemoryGB: Int {
        switch self {
        case .gemma4E4B, .ornith9B: 0
        case .gemma4_12B, .gemma4_26B: 24
        case .qwen36_35B: 32
        }
    }

    /// The models a Mac with `physicalMemory` bytes is offered, in Settings'
    /// order.
    public static func offered(physicalMemory: UInt64) -> [TextModel] {
        allCases.filter { physicalMemory >= UInt64($0.minimumMemoryGB) << 30 }
    }

    /// The stored choice, or the default when it is unknown or needs more
    /// memory than this Mac has, as a setting carried over from a bigger Mac would.
    public static func resolve(_ rawValue: String?, physicalMemory: UInt64) -> TextModel {
        guard let model = rawValue.flatMap(TextModel.init(rawValue:)),
              offered(physicalMemory: physicalMemory).contains(model) else { return .gemma4E4B }
        return model
    }

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
        // Google's quantization-aware checkpoints: trained for 4-bit, and smaller
        // than the plain Q4_K_M files.
        case .gemma4_12B:
            ModelDescriptor(
                name: rawValue,
                title: "Gemma 4 12B",
                fileName: "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf",
                url: URL(string: "https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF/resolve/980b060c40a8539ac159e0501a3e0f66a6365af3/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf")!,
                sha256: "90fd44e29e0d7cffeb0fd00dc73cfdab9ed0b0e95306ecf7821ea634c940c370",
                size: 6_716_356_800
            )
        case .gemma4_26B:
            ModelDescriptor(
                name: rawValue,
                title: "Gemma 4 26B-A4B",
                fileName: "gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf",
                url: URL(string: "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF/resolve/7b92b5b28818151e8669af2e45e88d6086f490dd/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf")!,
                sha256: "a7c5bc715f5ff8e99a3e8901ce7d2b42b402c669bf24f7c5250747633d0f5891",
                size: 14_249_047_104
            )
        // IQ4_XS rather than Q4_K_M, which at 22 GB would not leave a 32 GB Mac
        // enough room.
        case .qwen36_35B:
            ModelDescriptor(
                name: rawValue,
                title: "Qwen3.6 35B-A3B",
                fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
                url: URL(string: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf")!,
                sha256: "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3",
                size: 17_730_509_792
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
