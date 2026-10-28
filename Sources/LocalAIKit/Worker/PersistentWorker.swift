import Foundation
import Synchronization

public enum WorkerFailure: Error, Equatable, CustomStringConvertible {
    case launch(String)
    /// No progress for `seconds`: the Vision hang, or anything like it. The
    /// process was killed.
    case stalled(seconds: Int, lastProgress: String?)
    case timedOut(seconds: Int)
    case crashed(status: Int32, detail: String)

    public var description: String {
        switch self {
        case .launch(let why):
            "could not start an OCR worker: \(why)"
        case .stalled(let seconds, let progress):
            "OCR worker made no progress for \(seconds)s" + (progress.map { " (last: \($0))" } ?? "") + " and was stopped"
        case .timedOut(let seconds):
            "OCR worker exceeded \(seconds)s and was stopped"
        case .crashed(let status, let detail):
            "OCR worker exited with status \(status)" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }

    public var isStall: Bool {
        if case .stalled = self { return true }
        return false
    }
}

/// One `ocr-worker serve` process, one request at a time.
///
/// This is the replacement for the old log-scraping watchdog. Apple Vision on
/// macOS 27 can accept a request and never answer it, with the process sitting
/// at 0% CPU. In a worker that is a request whose progress stops, so the
/// process is killed and its pool starts another.
public final class PersistentWorker: Sendable {
    public enum Phase: Sendable, Equatable {
        case notStarted
        case starting
        case ready
        case busy
        case dead
    }

    public let executable: URL
    private let onLog: @Sendable (String) -> Void
    private let state = Mutex(State())

    private struct Pending {
        var id: String
        var continuation: CheckedContinuation<WorkerResult, Error>
        var sentAt: ContinuousClock.Instant
        var lastProgressAt: ContinuousClock.Instant
        var lastProgress: String?
    }

    private struct State {
        var phase = Phase.notStarted
        var process: Process?
        var input: FileHandle?
        var readyWaiters: [CheckedContinuation<Bool, Never>] = []
        var warmUpError: String?
        var pending: Pending?
        var killedFor: WorkerFailure?
        var tail: [String] = []
    }

    public init(executable: URL, onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.executable = executable
        self.onLog = onLog
    }

    public var phase: Phase { state.withLock { $0.phase } }
    public var warmUpError: String? { state.withLock { $0.warmUpError } }

    public func start(arguments: [String] = ["serve"]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [self] finished in
            let status = finished.terminationReason == .uncaughtSignal ? -finished.terminationStatus : finished.terminationStatus
            exited(status: status)
        }
        do {
            try process.run()
        } catch {
            throw WorkerFailure.launch(error.localizedDescription)
        }
        // The parent's copies of the child's ends must go, or the reads below
        // never see end-of-file.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        // A write to a worker that has just died must fail, not kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        state.withLock {
            $0.phase = .starting
            $0.process = process
            $0.input = input.fileHandleForWriting
        }
        Self.readLines(output.fileHandleForReading) { [self] line in received(line) }
        Self.readLines(errors.fileHandleForReading) { [self] line in
            state.withLock {
                $0.tail.append(line)
                if $0.tail.count > 5 { $0.tail.removeFirst() }
            }
            onLog(line)
        }
    }

    /// True once the worker has warmed up; false if it died first or did not
    /// manage it within `timeout`, in which case it has been killed.
    public func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let killer = Task.detached { [self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, phase == .starting else { return }
            kill(for: .timedOut(seconds: Int(timeout)))
        }
        defer { killer.cancel() }
        return await withCheckedContinuation { continuation in
            let settled: Bool? = state.withLock {
                switch $0.phase {
                case .ready, .busy: return true
                case .dead, .notStarted: return false
                case .starting:
                    $0.readyWaiters.append(continuation)
                    return nil
                }
            }
            if let settled {
                continuation.resume(returning: settled)
            }
        }
    }

    /// Sends one request and waits for its result. A page that takes longer
    /// than `stallTimeout`, or a request longer than `hardTimeout`, kills the
    /// worker; the error says which.
    public func convert(_ request: WorkerRequest, stallTimeout: TimeInterval, hardTimeout: TimeInterval) async throws -> WorkerResult {
        let watchdog = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let failure = overdue(stall: stallTimeout, hard: hardTimeout) {
                    kill(for: failure)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let refusal: WorkerFailure? = state.withLock {
                guard $0.phase == .ready, let input = $0.input else {
                    return .crashed(status: -1, detail: "the worker was not ready for a request")
                }
                let now = ContinuousClock.now
                $0.phase = .busy
                $0.pending = Pending(id: request.id, continuation: continuation, sentAt: now, lastProgressAt: now)
                do {
                    try input.write(contentsOf: request.line())
                    return nil
                } catch {
                    $0.pending = nil
                    return .crashed(status: -1, detail: "could not send the request: \(error.localizedDescription)")
                }
            }
            if let refusal {
                continuation.resume(throwing: refusal)
            }
        }
    }

    /// Closing stdin is the worker's signal to exit; SIGTERM makes sure.
    public func terminate() {
        let pid: pid_t? = state.withLock {
            try? $0.input?.close()
            $0.input = nil
            return $0.process?.processIdentifier
        }
        if let pid, pid > 0 {
            Darwin.kill(pid, SIGTERM)
        }
    }

    // MARK: - events

    private func received(_ line: String) {
        guard let message = try? JSONDecoder().decode(WorkerMessage.self, from: Data(line.utf8)) else {
            onLog("unreadable worker output: \(line.prefix(200))")
            return
        }
        switch message.event {
        case .ready:
            let waiters = state.withLock {
                $0.warmUpError = message.error
                if $0.phase == .starting { $0.phase = .ready }
                defer { $0.readyWaiters.removeAll() }
                return $0.readyWaiters
            }
            for waiter in waiters {
                waiter.resume(returning: true)
            }
        case .progress:
            state.withLock {
                guard $0.pending?.id == message.id else { return }
                $0.pending?.lastProgressAt = .now
                $0.pending?.lastProgress = "page \(message.page ?? 0) of \(message.total ?? 0)"
            }
        case .result:
            let continuation: CheckedContinuation<WorkerResult, Error>? = state.withLock {
                guard let pending = $0.pending, pending.id == message.id else { return nil }
                $0.pending = nil
                if $0.phase == .busy { $0.phase = .ready }
                return pending.continuation
            }
            continuation?.resume(returning: message.result ?? .failure("the worker sent an empty result"))
        }
    }

    private func exited(status: Int32) {
        let (pending, waiters, failure) = state.withLock {
            $0.phase = .dead
            $0.input = nil
            let failure = $0.killedFor ?? .crashed(status: status, detail: $0.tail.joined(separator: " | "))
            defer {
                $0.pending = nil
                $0.readyWaiters.removeAll()
            }
            return ($0.pending, $0.readyWaiters, failure)
        }
        for waiter in waiters {
            waiter.resume(returning: false)
        }
        pending?.continuation.resume(throwing: failure)
    }

    private func overdue(stall: TimeInterval, hard: TimeInterval) -> WorkerFailure? {
        state.withLock {
            guard let pending = $0.pending else { return nil }
            let now = ContinuousClock.now
            if now - pending.sentAt > .seconds(hard) {
                return .timedOut(seconds: Int(hard))
            }
            if now - pending.lastProgressAt > .seconds(stall) {
                return .stalled(seconds: Int(stall), lastProgress: pending.lastProgress)
            }
            return nil
        }
    }

    private func kill(for failure: WorkerFailure) {
        let pid: pid_t? = state.withLock {
            guard $0.phase != .dead else { return nil }
            $0.killedFor = failure
            return $0.process?.processIdentifier
        }
        if let pid, pid > 0 {
            Darwin.kill(pid, SIGKILL)
        }
    }

    private static func readLines(_ handle: FileHandle, _ onLine: @escaping @Sendable (String) -> Void) {
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { onLine(line) }
                }
            }
            if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        }
    }
}
