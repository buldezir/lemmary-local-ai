import Darwin
import Foundation
import Synchronization
import Testing
@testable import LocalAIKit

/// A stand-in worker for one model: it answers every request with its name and
/// pid, and takes 1.5 s over a file whose name says slow.
private func fakeEngine(_ name: String) throws -> URL {
    let script = """
        #!/bin/sh
        echo '{"event":"ready"}'
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
          case "$line" in *slow*) sleep 1.5 ;; esac
          echo "{\\"event\\":\\"result\\",\\"id\\":\\"$id\\",\\"result\\":{\\"markdown\\":\\"\(name) $$\\",\\"pages\\":1}}"
        done
        """
    let url = FileManager.default.temporaryDirectory.appending(path: "fake-\(name)-\(UUID().uuidString).sh")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private final class Loads: Sendable {
    private let seen = Mutex<[OCRModel]>([])
    func append(_ model: OCRModel) { seen.withLock { $0.append(model) } }
    var models: [OCRModel] { seen.withLock { $0 } }
}

private func makeSwitch(preferred: OCRModel = .appleVision, indraInstalled: Bool = true, loads: Loads = Loads()) throws -> OCRSwitch {
    let vision = try fakeEngine("vision")
    let indra = try fakeEngine("indra")
    return OCRSwitch(
        engines: [
            .appleVision: { .init(executable: vision, size: 1, startupTimeout: 5) },
            .indra: {
                guard indraInstalled else { throw ConverterUnavailable("indra-ocr is still downloading") }
                return .init(executable: indra, size: 1, startupTimeout: 5)
            },
        ],
        preferred: preferred, stallTimeout: 5, hardTimeout: 10,
        onLoad: { loads.append($0) }
    )
}

private func file(_ name: String = "doc") -> URL {
    FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString).pdf")
}

/// The engine's name and the pid of the worker that answered.
private func answer(_ outcome: ConversionOutcome) throws -> (engine: String, pid: pid_t) {
    guard case .converted(let markdown, _) = outcome else { throw ConverterUnavailable("no markdown") }
    let parts = markdown.split(separator: " ")
    return (String(parts[0]), pid_t(parts[1])!)
}

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

@Test func theModelAskedForReplacesTheOneInMemory() async throws {
    let loads = Loads()
    let ocr = try makeSwitch(loads: loads)
    defer { Task { await ocr.stop() } }

    let vision = try answer(try await ocr.convert(file: file(), kind: .pdf, model: .appleVision))
    #expect(vision.engine == "vision")
    let indra = try answer(try await ocr.convert(file: file(), kind: .pdf, model: .indra))
    #expect(indra.engine == "indra")
    #expect(await ocr.loadedModel == .indra)
    // Vision's worker is gone: one model in memory at a time.
    try await Task.sleep(for: .milliseconds(300))
    #expect(!alive(vision.pid))
    #expect(alive(indra.pid))

    // The same model again uses the same worker.
    #expect(try answer(try await ocr.convert(file: file(), kind: .pdf, model: .indra)).pid == indra.pid)
    #expect(loads.models == [.appleVision, .indra])
}

@Test func noModelNamedMeansTheOneUsedLast() async throws {
    let ocr = try makeSwitch(preferred: .indra)
    defer { Task { await ocr.stop() } }
    #expect(try answer(try await ocr.convert(file: file(), kind: .pdf, model: nil)).engine == "indra")
    _ = try await ocr.convert(file: file(), kind: .pdf, model: .appleVision)
    #expect(try answer(try await ocr.convert(file: file(), kind: .image, model: nil)).engine == "vision")
}

@Test func whatIndraCannotReadGoesToVisionUnlessIndraIsNamed() async throws {
    let ocr = try makeSwitch(preferred: .indra)
    defer { Task { await ocr.stop() } }
    #expect(try answer(try await ocr.convert(file: file(), kind: .docx, model: nil)).engine == "vision")
    await #expect(throws: UnreadableByModel.self) {
        try await ocr.convert(file: file(), kind: .html, model: .indra)
    }
}

@Test func aSwitchWaitsForTheRequestsInFlight() async throws {
    let ocr = try makeSwitch()
    defer { Task { await ocr.stop() } }
    _ = try await ocr.convert(file: file(), kind: .pdf, model: .appleVision)

    let started = ContinuousClock.now
    async let slow = ocr.convert(file: file("slow"), kind: .pdf, model: .appleVision)
    try await Task.sleep(for: .milliseconds(200))
    let indra = try answer(try await ocr.convert(file: file(), kind: .pdf, model: .indra))
    // Vision's slow document finished on Vision; Indra waited for it.
    #expect(try answer(try await slow).engine == "vision")
    #expect(indra.engine == "indra")
    #expect(ContinuousClock.now - started > .seconds(1.4))
}

@Test func aModelThatCannotStartLeavesTheLoadedOne() async throws {
    let ocr = try makeSwitch(indraInstalled: false)
    defer { Task { await ocr.stop() } }
    let vision = try answer(try await ocr.convert(file: file(), kind: .pdf, model: .appleVision))
    await #expect(throws: ConverterUnavailable.self) {
        try await ocr.convert(file: file(), kind: .pdf, model: .indra)
    }
    #expect(await ocr.loadedModel == .appleVision)
    #expect(try answer(try await ocr.convert(file: file(), kind: .pdf, model: .appleVision)).pid == vision.pid)
    // Nor is it the one used last: a request naming no model stays on Vision.
    #expect(try answer(try await ocr.convert(file: file(), kind: .pdf, model: nil)).pid == vision.pid)
}

@Test func preloadStartsTheModelBeforeAnyRequest() async throws {
    let loads = Loads()
    let ocr = try makeSwitch(preferred: .indra, loads: loads)
    defer { Task { await ocr.stop() } }
    await ocr.preload(.indra)
    #expect(await ocr.loadedModel == .indra)
    // A second preload while a model is in memory changes nothing.
    await ocr.preload(.appleVision)
    #expect(await ocr.loadedModel == .indra)
    #expect(loads.models == [.indra])
}

@Test func stoppingRefusesLaterRequests() async throws {
    let ocr = try makeSwitch()
    _ = try await ocr.convert(file: file(), kind: .pdf, model: .appleVision)
    await ocr.stop()
    await #expect(throws: ConverterUnavailable.self) {
        try await ocr.convert(file: file(), kind: .pdf, model: .appleVision)
    }
}

@Test func indraRuntimePinsAreConsistent() {
    let names = IndraRuntime.all.map(\.fileName)
    #expect(Set(names).count == names.count)
    #expect(IndraRuntime.all.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    // Every file Indra's model folder must have, and its licence.
    for required in ["det.onnx", "rec.onnx", "order.onnx", "meta.json", "LICENSE"] {
        #expect(IndraRuntime.models.contains { $0.fileName == required })
    }
    #expect(IndraRuntime.python.fileName.contains("+"))
}

@Test func anEmptyLayoutIsMissingEverything() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "indra-layout-\(UUID().uuidString)")
    let layout = IndraRuntime.Layout(root: root, modelsRoot: root.appending(path: "models"))
    #expect(!layout.isInstalled)
    #expect(layout.missing.count == IndraRuntime.all.count)
    let command = layout.worker(script: URL(fileURLWithPath: "/w.py"), threads: 0)
    #expect(command.executable == layout.python)
    #expect(command.arguments == ["-I", "/w.py", "serve", "--models", layout.models.path, "--threads", "1"])
}

/// The real download, unpacking and worker, about 180 MB from GitHub, PyPI and
/// Hugging Face: `INDRA_LIVE=1 swift test --filter indraInstallsAndReads`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["INDRA_LIVE"] == "1"))
func indraInstallsAndReads() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "indra-live")
    let layout = IndraRuntime.Layout(root: root, modelsRoot: root.appending(path: "models"))
    let progress = Mutex<[IndraRuntime.Progress]>([])
    try await IndraRuntime.install(layout) { step in progress.withLock { $0.append(step) } }
    #expect(layout.isInstalled)
    #expect(progress.withLock { $0.contains(.unpacking) } || progress.withLock { $0.isEmpty })

    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/indra_worker.py").standardized
    let command = layout.worker(script: script, threads: 2)
    let pool = WorkerPool(configuration: .init(executable: command.executable, arguments: command.arguments, size: 1, startupTimeout: 120))
    await pool.start()
    defer { Task { await pool.stop() } }
    let converter = PoolConverter(pool: pool, stallTimeout: 60, hardTimeout: 120)
    let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../VisionOCRTests/Fixtures/twocol.png").standardized
    guard case .converted(let markdown, let pages) = try await converter.convert(file: image, kind: .image) else {
        Issue.record("Indra did not read the page")
        return
    }
    #expect(pages == 1)
    #expect(markdown.contains("Quarterly Report"))
}
