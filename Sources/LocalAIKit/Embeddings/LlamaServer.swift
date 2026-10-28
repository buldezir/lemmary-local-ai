import CryptoKit
import Foundation

/// The `llama-server` command line for bge-m3 embeddings. The flag choices are
/// measured ones from Lemmary's `docs/local_ai_macos.md`; see there for numbers.
public struct LlamaServerConfig: Sendable, Equatable {
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

    public init(modelPath: String, host: String, port: Int, contextTokens: Int = 8192, alias: String = "BAAI/bge-m3") {
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

public struct ModelDescriptor: Sendable, Equatable {
    public var name: String
    public var fileName: String
    public var url: URL
    public var sha256: String
    public var size: Int64

    /// F16 rather than Q8_0: the same speed on Metal and closer to the original
    /// weights. The hash is Hugging Face's own (`X-Linked-Etag`).
    public static let bgeM3 = ModelDescriptor(
        name: "BAAI/bge-m3",
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
