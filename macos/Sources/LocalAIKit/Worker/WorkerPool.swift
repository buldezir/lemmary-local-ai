import Foundation
import Synchronization

/// A fixed number of `ocr-worker serve` processes, kept running and warm.
/// A worker that dies or is killed is replaced; one that fails to start is
/// retried with backoff, so a broken binary does not spin.
public actor WorkerPool {
    public struct Configuration: Sendable {
        public var executable: URL
        public var size: Int
        /// The first warm-up after Vision's models were unloaded took up to
        /// 40 seconds in testing; this is far beyond that.
        public var startupTimeout: TimeInterval

        public init(executable: URL, size: Int, startupTimeout: TimeInterval = 300) {
            self.executable = executable
            self.size = max(1, size)
            self.startupTimeout = startupTimeout
        }
    }

    private let configuration: Configuration
    private let onLog: @Sendable (String) -> Void
    private let onReadyChange: @Sendable (Int) -> Void

    private var workers: [ObjectIdentifier: PersistentWorker] = [:] {
        didSet { live.withLock { $0 = Array(workers.values) } }
    }
    /// The same workers, reachable without awaiting the actor: an app that is
    /// quitting cannot wait for a task to be scheduled.
    private nonisolated let live = Mutex<[PersistentWorker]>([])
    private var idle: [PersistentWorker] = []
    private var waiters: [CheckedContinuation<PersistentWorker?, Never>] = []
    private var backoff = Backoff()
    private var stopped = false

    public init(configuration: Configuration, onLog: @escaping @Sendable (String) -> Void = { _ in },
                onReadyChange: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.configuration = configuration
        self.onLog = onLog
        self.onReadyChange = onReadyChange
    }

    public func start() {
        for _ in 0..<configuration.size {
            spawn()
        }
    }

    public func stop() {
        stopped = true
        for worker in workers.values {
            worker.terminate()
        }
        workers.removeAll()
        idle.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
    }

    /// Ends every worker now, from any thread. Idle workers would exit anyway
    /// when the app's end of their stdin closes; a worker stuck inside Vision
    /// would not.
    public nonisolated func terminateNow() {
        for worker in live.withLock({ $0 }) {
            worker.terminate()
        }
    }

    /// Workers that have warmed up, whether idle or busy.
    public var readyCount: Int {
        workers.values.filter { [.ready, .busy].contains($0.phase) }.count
    }

    /// The next idle worker, waiting for one if all are busy or still warming
    /// up. nil once the pool is stopped.
    public func checkout() async -> PersistentWorker? {
        while let worker = idle.popLast() {
            if worker.phase == .ready { return worker }
            discard(worker)
        }
        if stopped { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func checkin(_ worker: PersistentWorker) {
        guard !stopped, worker.phase == .ready else {
            discard(worker)
            return
        }
        if waiters.isEmpty {
            idle.append(worker)
        } else {
            waiters.removeFirst().resume(returning: worker)
        }
    }

    /// Ends a worker that failed a request and starts its replacement.
    public func discard(_ worker: PersistentWorker) {
        worker.terminate()
        if workers.removeValue(forKey: ObjectIdentifier(worker)) != nil {
            onReadyChange(readyCount)
            spawn()
        }
    }

    private func spawn() {
        guard !stopped else { return }
        let worker = PersistentWorker(executable: configuration.executable, onLog: onLog)
        do {
            try worker.start()
        } catch {
            onLog("\(error)")
            respawnLater()
            return
        }
        workers[ObjectIdentifier(worker)] = worker
        let timeout = configuration.startupTimeout
        Task {
            let ready = await worker.waitUntilReady(timeout: timeout)
            started(worker, ready: ready)
        }
    }

    private func started(_ worker: PersistentWorker, ready: Bool) {
        guard workers[ObjectIdentifier(worker)] != nil else { return }
        guard ready else {
            workers[ObjectIdentifier(worker)] = nil
            onLog("an OCR worker did not finish warming up")
            respawnLater()
            return
        }
        backoff.reset()
        if let problem = worker.warmUpError {
            onLog("warm-up: \(problem)")
        }
        onReadyChange(readyCount)
        checkin(worker)
    }

    private func respawnLater() {
        let delay = backoff.next()
        Task {
            try? await Task.sleep(for: .seconds(delay))
            spawn()
        }
    }
}

/// Converts a document on a pooled worker.
public struct PoolConverter: DocumentConverting {
    public var pool: WorkerPool
    public var stallTimeout: TimeInterval
    public var hardTimeout: TimeInterval
    public var onLog: @Sendable (String) -> Void

    public init(pool: WorkerPool, stallTimeout: TimeInterval, hardTimeout: TimeInterval,
                onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.pool = pool
        self.stallTimeout = stallTimeout
        self.hardTimeout = hardTimeout
        self.onLog = onLog
    }

    /// A stall is retried once, on another worker. The Vision hang is not tied
    /// to the document: the image that hung went through on the next attempt.
    /// A crash is not retried, since a crash on a file usually repeats.
    public func convert(file: URL, kind: MediaKind) async throws -> ConversionOutcome {
        var attempt = 1
        while true {
            guard let worker = await pool.checkout() else {
                throw WorkerFailure.launch("the OCR service is stopping")
            }
            do {
                let request = WorkerRequest(id: UUID().uuidString, path: file.path, kind: kind)
                let result = try await worker.convert(request, stallTimeout: stallTimeout, hardTimeout: hardTimeout)
                await pool.checkin(worker)
                if let error = result.error {
                    return .failed(error)
                }
                return .converted(markdown: result.markdown ?? "", pages: result.pages)
            } catch let failure as WorkerFailure {
                await pool.discard(worker)
                guard failure.isStall, attempt == 1 else { throw failure }
                onLog("\(failure); retrying once on another worker")
                attempt += 1
            }
        }
    }
}
