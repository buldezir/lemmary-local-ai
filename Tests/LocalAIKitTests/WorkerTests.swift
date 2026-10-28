import Foundation
import Testing
@testable import LocalAIKit

/// A stand-in for `ocr-worker serve` in shell, so the worker and pool are
/// tested against real processes, pipes and signals rather than a mock. What it
/// does with a request depends on the file name it is given.
private func fakeWorker(beforeReady: String = "") throws -> URL {
    let script = """
        #!/bin/sh
        \(beforeReady)
        echo '{"event":"ready"}'
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
          path=$(printf '%s' "$line" | sed 's/.*"path":"\\([^"]*\\)".*/\\1/')
          progress() { echo "{\\"event\\":\\"progress\\",\\"id\\":\\"$id\\",\\"page\\":$1,\\"total\\":$2}"; }
          result() { echo "{\\"event\\":\\"result\\",\\"id\\":\\"$id\\",\\"result\\":$1}"; }
          case "$path" in
            *hang-once*)
              if [ -e "$path" ]; then result '{"markdown":"second try","pages":1}'; continue; fi
              touch "$path"; progress 0 1; sleep 30 ;;
            *hang*) progress 0 1; sleep 30 ;;
            *crash*) echo 'Vision exploded' >&2; exit 3 ;;
            *locked*) result '{"error":"the PDF is password-protected","pages":0}' ;;
            *slow*) for i in 1 2 3; do sleep 0.6; progress $i 3; done; result '{"markdown":"slow but fine","pages":3}' ;;
            *) echo "log line for $id" >&2; result "{\\"markdown\\":\\"pid $$\\",\\"pages\\":1}" ;;
          esac
        done
        """
    let url = FileManager.default.temporaryDirectory.appending(path: "fake-worker-\(UUID().uuidString).sh")
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func request(_ name: String) -> WorkerRequest {
    WorkerRequest(id: UUID().uuidString, path: FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)").path, kind: .pdf)
}

private func startedWorker(_ executable: URL, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PersistentWorker {
    let worker = PersistentWorker(executable: executable, onLog: log)
    try worker.start()
    #expect(await worker.waitUntilReady(timeout: 5))
    return worker
}

// MARK: - one worker

@Test func aWorkerAnswersRequestsAndStaysAlive() async throws {
    let logged = LockedLines()
    let worker = try await startedWorker(try fakeWorker()) { logged.append($0) }
    defer { worker.terminate() }
    let first = try await worker.convert(request("doc"), stallTimeout: 5, hardTimeout: 10)
    let second = try await worker.convert(request("doc"), stallTimeout: 5, hardTimeout: 10)
    #expect(first.markdown?.hasPrefix("pid ") == true)
    #expect(first.markdown == second.markdown)
    #expect(worker.phase == .ready)
    try await Task.sleep(for: .milliseconds(100))
    #expect(logged.lines.count == 2)
}

@Test func aStalledWorkerIsKilled() async throws {
    let worker = try await startedWorker(try fakeWorker())
    let started = ContinuousClock.now
    await #expect(throws: WorkerFailure.stalled(seconds: 1, lastProgress: "page 0 of 1")) {
        try await worker.convert(request("hang"), stallTimeout: 1, hardTimeout: 20)
    }
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(worker.phase == .dead)
}

@Test func progressKeepsASlowPageAlive() async throws {
    // Three pages of 0.6s each against a 1s stall limit: slow overall, never stalled.
    let worker = try await startedWorker(try fakeWorker())
    defer { worker.terminate() }
    let result = try await worker.convert(request("slow"), stallTimeout: 1, hardTimeout: 20)
    #expect(result.markdown == "slow but fine")
}

@Test func aCrashIsReportedWithItsLastWords() async throws {
    let worker = try await startedWorker(try fakeWorker())
    await #expect(throws: WorkerFailure.crashed(status: 3, detail: "Vision exploded")) {
        try await worker.convert(request("crash"), stallTimeout: 5, hardTimeout: 10)
    }
}

@Test func aWorkerThatNeverWarmsUpIsKilled() async throws {
    let worker = PersistentWorker(executable: try fakeWorker(beforeReady: "sleep 30"))
    try worker.start()
    #expect(await worker.waitUntilReady(timeout: 1) == false)
    try await Task.sleep(for: .milliseconds(200))
    #expect(worker.phase == .dead)
}

// MARK: - pool

@Test func thePoolRetriesAStallOnceOnAnotherWorker() async throws {
    let pool = WorkerPool(configuration: .init(executable: try fakeWorker(), size: 1, startupTimeout: 5))
    await pool.start()
    defer { Task { await pool.stop() } }
    let converter = PoolConverter(pool: pool, stallTimeout: 1, hardTimeout: 20)
    let file = FileManager.default.temporaryDirectory.appending(path: "hang-once-\(UUID().uuidString)")
    #expect(try await converter.convert(file: file, kind: .pdf) == .converted(markdown: "second try", pages: 1))
}

@Test func thePoolReplacesACrashedWorker() async throws {
    let pool = WorkerPool(configuration: .init(executable: try fakeWorker(), size: 1, startupTimeout: 5))
    await pool.start()
    defer { Task { await pool.stop() } }
    let converter = PoolConverter(pool: pool, stallTimeout: 5, hardTimeout: 10)
    let temp = FileManager.default.temporaryDirectory
    await #expect(throws: WorkerFailure.self) {
        try await converter.convert(file: temp.appending(path: "crash"), kind: .pdf)
    }
    guard case .converted = try await converter.convert(file: temp.appending(path: "doc"), kind: .pdf) else {
        Issue.record("the replacement worker should have answered")
        return
    }
}

@Test func documentFailuresAreOutcomesNotErrors() async throws {
    let pool = WorkerPool(configuration: .init(executable: try fakeWorker(), size: 1, startupTimeout: 5))
    await pool.start()
    defer { Task { await pool.stop() } }
    let converter = PoolConverter(pool: pool, stallTimeout: 5, hardTimeout: 10)
    let outcome = try await converter.convert(file: FileManager.default.temporaryDirectory.appending(path: "locked"), kind: .pdf)
    #expect(outcome == .failed("the PDF is password-protected"))
}

@Test func thePoolRunsOnlyAsManyAtOnceAsItHasWorkers() async throws {
    let pool = WorkerPool(configuration: .init(executable: try fakeWorker(), size: 2, startupTimeout: 5))
    await pool.start()
    defer { Task { await pool.stop() } }
    let converter = PoolConverter(pool: pool, stallTimeout: 5, hardTimeout: 20)
    // Wait for both workers, so the timing below measures conversions only.
    for _ in 0..<50 where await pool.readyCount < 2 {
        try await Task.sleep(for: .milliseconds(50))
    }
    let started = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                _ = try await converter.convert(file: FileManager.default.temporaryDirectory.appending(path: "slow"), kind: .pdf)
            }
        }
        try await group.waitForAll()
    }
    // Four 1.8s conversions on two workers is two rounds, not one and not four.
    let elapsed = ContinuousClock.now - started
    #expect(elapsed > .seconds(3.4))
    #expect(elapsed < .seconds(6))
}

@Test func messagesRoundTripAsSingleLines() throws {
    let message = WorkerMessage.result(id: "a", .success(markdown: "line one\nline two", pages: 2))
    let line = message.line()
    #expect(line.filter { $0 == 0x0A }.count == 1)
    #expect(try JSONDecoder().decode(WorkerMessage.self, from: line) == message)
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
