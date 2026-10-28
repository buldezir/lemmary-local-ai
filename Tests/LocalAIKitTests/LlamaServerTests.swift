import Foundation
import Testing
@testable import LocalAIKit

/// The value that follows `flag` on a command line.
private func value(of flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

// MARK: - embeddings

@Test func embeddingsKeepTheMeasuredFlags() {
    let arguments = EmbeddingsServerConfig(modelPath: "/m/bge.gguf", host: "0.0.0.0", port: 8080).arguments
    #expect(value(of: "-m", in: arguments) == "/m/bge.gguf")
    #expect(value(of: "--alias", in: arguments) == "BAAI/bge-m3")
    #expect(arguments.contains("--embeddings"))
    #expect(value(of: "--pooling", in: arguments) == "cls")
    for flag in ["-c", "-b", "-ub"] {
        #expect(value(of: flag, in: arguments) == "8192")
    }
    #expect(value(of: "--host", in: arguments) == "0.0.0.0")
    #expect(value(of: "--port", in: arguments) == "8080")
}

// MARK: - text model

@Test func textModelServesChatWithThinkingOff() throws {
    let arguments = TextServerConfig(modelPath: "/m/gemma.gguf", alias: "gemma-4-e4b", host: "127.0.0.1", port: 8081).arguments
    #expect(value(of: "-m", in: arguments) == "/m/gemma.gguf")
    #expect(value(of: "--alias", in: arguments) == "gemma-4-e4b")
    #expect(!arguments.contains("--embeddings"))
    #expect(arguments.contains("--jinja"))
    #expect(value(of: "-c", in: arguments) == "16384")
    #expect(value(of: "-np", in: arguments) == "1")
    #expect(value(of: "--host", in: arguments) == "127.0.0.1")
    #expect(value(of: "--port", in: arguments) == "8081")

    let kwargs = try #require(value(of: "--chat-template-kwargs", in: arguments))
    let object = try JSONSerialization.jsonObject(with: Data(kwargs.utf8)) as? [String: Bool]
    #expect(object == ["enable_thinking": false])
}

@Test func textModelKeepsNoPromptCacheInRAM() {
    let arguments = TextServerConfig(modelPath: "/m", alias: "a", host: "h", port: 1, contextTokens: 32768).arguments
    #expect(value(of: "--cache-ram", in: arguments) == "0")
    #expect(value(of: "-c", in: arguments) == "32768")
}

@Test func textModelsArePinnedAndDistinct() {
    let descriptors = TextModel.allCases.map(\.descriptor)
    #expect(Set(descriptors.map(\.name)).count == descriptors.count)
    #expect(Set(descriptors.map(\.fileName)).count == descriptors.count)
    for descriptor in descriptors {
        #expect(descriptor.name == TextModel(rawValue: descriptor.name)?.descriptor.name)
        #expect(descriptor.url.lastPathComponent == descriptor.fileName)
        #expect(!descriptor.url.path.contains("/resolve/main/"), "\(descriptor.title) should be pinned to a commit")
        #expect(descriptor.sha256.count == 64 && descriptor.sha256.allSatisfy(\.isHexDigit))
        #expect(descriptor.size > 1_000_000_000)
    }
}

// MARK: - backoff

@Test func backoffDoublesUpToAMinuteAndResets() {
    var backoff = Backoff()
    #expect((0..<8).map { _ in backoff.next() } == [1, 2, 4, 8, 16, 32, 60, 60])
    backoff.reset()
    #expect(backoff.next() == 1)
}
